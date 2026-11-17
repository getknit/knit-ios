import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire

@testable import KnitMesh

/// Frames and scopes for the heal loop's suites: two members sharing one DM scope, and frames signed by either.
enum ScopeFixture {
    static let alice = TestPeer(seed: 1)
    static let bob = TestPeer(seed: 2)
    static let carol = TestPeer(seed: 3)
    /// A wall clock far from both ends of `Int64`.
    static let wall: Int64 = 1_800_000_000_000

    /// The keys the pair shares, derived from a fixed root as both members would.
    static func keys(_ seed: Int = 40) -> ScopeKeys {
        ScopeCrypto.dmScope(pairwiseRoot: fixtureBytes(32, seed: seed), alice.nodeId, bob.nodeId)
    }

    /// `member`'s view of the pair's scope.
    static func scope(for member: TestPeer, retiring: Bool = false, seed: Int = 40) -> SpoolScope {
        let peer = member == alice ? bob : alice
        guard let scope = SpoolScope.of(keys(seed), peer: peer.nodeId, retiring: retiring) else {
            preconditionFailure("a derived scope id is 32 bytes")
        }
        return scope
    }

    private static func idBytes(_ number: Int, _ sender: TestPeer) -> [UInt8] {
        let tag = sender.nodeId.string.utf8.reduce(UInt8(0)) { $0 &* 31 &+ $1 }
        return [tag, 0x5C] + fixtureBytes(10, seed: 900) + withUnsafeBytes(of: UInt32(truncatingIfNeeded: number).bigEndian, Array.init)
    }

    /// A DM `from` → `to`, sealed v2 (or `version`) with the ratchet header; `reset` flags it as a session reset with an
    /// init, `bareFlag` sets the flag with no init, `pendingInit` carries an init unflagged; `padding` grows its ciphertext.
    static func dm(
        _ number: Int, from: TestPeer = alice, to: TestPeer = bob, sentAt: Int64 = wall, version: Int = 2, reset: Bool = false,
        bareFlag: Bool = false, pendingInit: Bool = false, ratchet: Bool = true, padding: Int = 24, id: String? = nil
    ) -> TestFrame {
        let initial = (reset || pendingInit) ? RatchetInit(eph: fixtureBytes(32, seed: 500 + number), pkid: 1, at: 0) : nil
        let header = RatchetHeader(
            se: 1, ek: fixtureBytes(32, seed: number), pe: 0, n: number, initial: initial, flags: reset || bareFlag ? 1 : 0)
        let enc = EncEnvelope(
            version: version,
            nonce: version == 3 ? [] : fixtureBytes(12, seed: number),
            ct: fixtureBytes(padding, seed: number + 1),
            keys: [],
            ratchet: ratchet ? header : nil
        )
        let envelope = RelayEnvelope(
            type: .chat,
            id: id ?? FrameId.text(for: idBytes(number, from)),
            senderId: from.nodeId.string,
            sentAt: sentAt,
            recipientId: to.nodeId.string,
            payload: ChatContent(enc: enc).encoded
        )
        do {
            return try from.signed(envelope)
        } catch {
            preconditionFailure("a fixture key signs")
        }
    }

    static func carried(_ frame: TestFrame) -> CarriedFrame {
        CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
    }

    /// `frame` sealed into the pair's scope.
    static func sealed(_ frame: TestFrame, seed: Int = 40) -> SealedBlob {
        guard let sealed = ScopeFrames.seal(carried(frame), into: scope(for: alice, seed: seed)) else {
            preconditionFailure("a signed frame seals")
        }
        return sealed
    }
}

/// One member of a scope: its custody, its heal loop and a session on a ``FakeSpool``, with the engine's part played
/// by ``deliver(_:)``: verify against the claimed sender's key, store into custody, settle with whether custody kept it
/// live. Each ``step(at:)`` runs the session's and the heal's timers, then a round when one is due.
final class HealMember {
    let identity: TestPeer
    let spool: FakeSpool
    let custody: MemoryCustodyStore
    var heal: ScopeHeal
    var session: SpoolSession
    var connection: FakeSpool.Connection
    /// The keys this member has pinned, by node id: its own and its peer's.
    var pinned: [NodeId: PublicKeyBundle]
    /// What the engine was handed, in order.
    private(set) var delivered: [ScopeFrame] = []
    /// Every record this member sent, in order.
    private(set) var sent: [SpoolRecord] = []
    /// Candidates refused at the signature.
    private(set) var unopenable = 0
    /// Whether `.mine` requests are mined at once; otherwise they wait in ``pendingMining``.
    var minesStamps: Bool
    /// Mining requests not yet answered.
    var pendingMining: [SpoolMiningRequest] = []
    /// Every mining request the heal made.
    private(set) var mineRequests: [SpoolMiningRequest] = []
    /// Mining requests the heal cancelled.
    private(set) var cancelledMining: [SpoolMiningRequest] = []
    /// Whether a round reads custody as unreadable.
    var custodyUnreadable = false
    /// Candidates the engine refuses as though their signature failed.
    var refuseEverySignature = false
    var now: SpoolNow

    init(
        _ identity: TestPeer, spool: FakeSpool, scopes: [SpoolScope], custody: MemoryCustodyStore = MemoryCustodyStore(), at now: SpoolNow,
        minesStamps: Bool = true
    ) {
        self.identity = identity
        self.minesStamps = minesStamps
        self.spool = spool
        self.custody = custody
        self.now = now
        heal = ScopeHeal(relay: SpoolRelayHandle(number: 1), me: identity.nodeId)
        heal.adopt(scopes)
        let others = [ScopeFixture.alice, ScopeFixture.bob, ScopeFixture.carol]
        pinned = Dictionary(uniqueKeysWithValues: others.map { ($0.nodeId, $0.keys.bundle) })
        connection = spool.connect()
        session = SpoolSession(openedAt: now.monotonic)
        pump()
    }

    /// Opens a fresh connection, as a reconnect does.
    func reconnect() {
        spool.drop(connection)
        session.socketClosed()
        pump()
        connection = spool.connect()
        session = SpoolSession(openedAt: now.monotonic)
        pump()
    }

    /// Stores `frames` into custody as our own or relayed, and tells the heal custody changed.
    func hold(_ frames: [TestFrame]) {
        for frame in frames {
            custody.store(ScopeFixture.carried(frame), origin: .own, now: now.wall)
        }
        heal.custodyChanged()
    }

    /// Runs the timers at `now`, then one round if one is due.
    func step(at now: SpoolNow) {
        self.now = now
        session.tick(now: now.monotonic)
        pump()
        heal.tick(session: &session, now: now)
        pump()
        guard heal.wantsRound(sessionReady: session.isReady, now: now) else {
            return
        }
        let custodyRead: ScopeHeal.Custody = custodyUnreadable ? .unreadable : .frames(custody.liveFrames(now: now.wall))
        heal.roundStarted(custodyRead, session: &session, now: now)
        pump()
    }

    /// Runs the timers at `now` and starts a round when one is due, leaving what it sent unsent until ``pump()``, so a
    /// test can slip a record in ahead of the spool's answer.
    func beginRound(at now: SpoolNow) {
        self.now = now
        session.tick(now: now.monotonic)
        heal.tick(session: &session, now: now)
        guard heal.wantsRound(sessionReady: session.isReady, now: now) else {
            return
        }
        heal.roundStarted(.frames(custody.liveFrames(now: now.wall)), session: &session, now: now)
    }

    /// The anchor the session holds for `scope`.
    func anchor(_ scope: SpoolID) -> UInt64? {
        session.anchor(scope)?.digest
    }

    /// Carries records both ways, events to the heal and the heal's outputs to the engine's stand-in, until quiet.
    func pump() {
        var quiet = false
        while !quiet {
            quiet = true
            for output in session.drain() {
                quiet = false
                switch output {
                case .send(let bytes):
                    if let record = SpoolRecord(decoding: bytes) {
                        sent.append(record)
                    }
                    spool.receive(bytes, from: connection)
                case .close:
                    spool.drop(connection)
                case .event(let event):
                    heal.handle(event, session: &session, now: now)
                    serveHeal()
                }
            }
            serveHeal()
            for outgoing in spool.take(connection) {
                quiet = false
                switch outgoing {
                case .record(let bytes):
                    session.receive(bytes)
                case .close:
                    session.socketClosed()
                }
            }
        }
    }

    private func serveHeal() {
        for output in heal.drain() {
            switch output {
            case .candidate(let candidate):
                deliver(candidate)
            case .mine(let request):
                mineRequests.append(request)
                guard minesStamps else {
                    pendingMining.append(request)
                    continue
                }
                mine(request)
            case .cancelMining(let request):
                cancelledMining.append(request)
            }
        }
    }

    /// Answers `request` as a search that found nothing, or one cancelled.
    func failMining(_ request: SpoolMiningRequest) {
        pendingMining.removeAll { $0 == request }
        heal.stampMined(request, counter: nil, session: &session, now: now)
        pump()
    }

    /// Mines `request` and answers the heal.
    func mine(_ request: SpoolMiningRequest) {
        let counter = SpoolPow.mine(scopeId: request.scope.bytes, day: request.day, bits: request.bits)
        heal.stampMined(request, counter: counter, session: &session, now: now)
        pump()
    }

    /// The engine's part (P4): the signature against the claimed sender's pinned key, then custody, then the settlement
    /// with whether custody holds the frame live in the same turn.
    private func deliver(_ candidate: ScopeCandidate) {
        guard !refuseEverySignature, let bundle = pinned[candidate.claimedSender], let frame = candidate.verified(by: bundle) else {
            unopenable += 1
            heal.settle(candidate, .unopenable, session: &session, now: now)
            return
        }
        delivered.append(frame)
        custody.store(frame.carried, origin: .relayed, now: now.wall)
        let kept = custody.frame(frame.envelope.id, now: now.wall) != nil
        heal.settle(candidate, .delivered(keptLive: kept), session: &session, now: now)
    }

    /// Clears the sent log.
    func forgetSent() {
        sent.removeAll()
    }

    /// How many `list` records were sent.
    var lists: Int {
        sent.count { if case .list = $0 { true } else { false } }
    }

    /// The `sub` records sent, in order.
    var subs: [SpoolSub] {
        sent.compactMap { record in
            guard case .sub(let sub) = record else {
                return nil
            }
            return sub
        }
    }

    /// The blob ids pushed, in order.
    var pushes: [SpoolID] {
        sent.compactMap { record in
            guard case .push(let push) = record else {
                return nil
            }
            return SpoolID(push.blobId)
        }
    }

    /// The blob ids pulled, in order.
    var pulls: [SpoolID] {
        sent.flatMap { record -> [SpoolID] in
            guard case .pull(let pull) = record else {
                return []
            }
            return pull.blobIds.compactMap(SpoolID.init)
        }
    }
}

/// Members sharing one fake spool and one clock, stepped together.
struct HealLab {
    let spool: FakeSpool
    var members: [HealMember]
    private(set) var clock: Int64 = 0

    init(
        _ members: [TestPeer], scopes: (TestPeer) -> [SpoolScope] = { [ScopeFixture.scope(for: $0)] },
        spool: FakeSpool = FakeSpool(now: ScopeFixture.wall), manualMiner: TestPeer? = nil
    ) {
        self.spool = spool
        let start = SpoolNow(monotonic: 0, wall: ScopeFixture.wall)
        self.members = members.map { HealMember($0, spool: spool, scopes: scopes($0), at: start, minesStamps: $0 != manualMiner) }
    }

    var now: SpoolNow { SpoolNow(monotonic: clock, wall: ScopeFixture.wall + clock) }

    /// Moves the clock by `milliseconds` and steps every member, the spool's clock too.
    mutating func advance(by milliseconds: Int64) {
        clock += milliseconds
        spool.advance(to: now.wall)
        for member in members {
            member.step(at: now)
        }
        // A second pass carries what one member's step sent to the other in the same instant.
        for member in members {
            member.pump()
        }
    }

    /// Steps `count` times, `milliseconds` apart.
    mutating func run(_ count: Int, every milliseconds: Int64 = ScopeHeal.healFloorMilliseconds) {
        for _ in 0..<count {
            advance(by: milliseconds)
        }
    }

    /// The spool's digest of `scope`.
    func spoolDigest(_ scope: SpoolID) -> UInt64 {
        ScopeCrypto.digest(of: spool.liveIds(scope).map(\.bytes))
    }
}

/// A raw client of the fake spool, standing for another member's phone: it subscribes the pair's scope and pushes sealed
/// blobs as they are, with no heal loop and no custody.
struct RawMember {
    var line: SpoolLine
    let scope: SpoolID

    init(_ spool: FakeSpool, scope: SpoolID = ScopeFixture.scope(for: ScopeFixture.alice).id) {
        line = SpoolLine(spool)
        self.scope = scope
        _ = line.session.subscribe([ScopeSub(scope: scope.bytes, bounds: ScopeFrames.bounds)], now: 0)
        line.pump()
        _ = line.takeEvents()
    }

    /// Pushes `blob` and waits for the spool's answer.
    mutating func push(_ blob: SealedBlob) {
        _ = line.session.push(scope, blobId: blob.id, data: blob.blob, pow: nil, now: 0)
        line.pump()
        _ = line.takeEvents()
    }

    /// Pushes `frame` sealed into the pair's scope.
    mutating func push(_ frame: TestFrame) {
        push(ScopeFixture.sealed(frame))
    }
}
