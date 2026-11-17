public import KnitCrypto
public import KnitWire

/// The seam `FuzzSpoolSession` drives (ADR 2026-11.adrq, P4b1): one ``SpoolSession`` and one ``ScopeHeal`` played by a
/// script of arbitrary bytes, at arbitrary `Int64` clocks, with the harness's own `sub`, `list`, `pull`, `push`, closes and
/// stamp answers, every output carried back into the heal as the plane carries it. It checks after every step:
/// - nothing traps, and a `Retry-After` read from the script's head is no floor or one inside 0…60 s;
/// - a scope's claims stay at most ``SpoolSession/maxClaimsPerScope`` plus the blobs in flight;
/// - one step's outputs stay bounded;
/// - every search in `mining` was asked for and not yet answered or cancelled, and every answer, with a session or with
///   none, clears it (the invariant ``ScopeHeal/mining`` documents).
@_spi(Fuzz)
public enum SpoolSessionFuzz {
    /// The most outputs one step may drain: a record is at most 128 KiB, so a step's events are bounded by what it read.
    static let maxOutputsPerStep = SpoolRecordLayer.maxPinnedFrames + SpoolRecordLayer.maxPinnedFrames + Int(UInt8.max)

    /// Plays `script` over the harness's fixed members and four scopes of fixed keys, after reading its head as a
    /// `Retry-After` header, which is held to 0…60 s or is no floor. Answers how many steps it played.
    @discardableResult
    public static func run(_ script: [UInt8]) -> Int {
        let retry = SpoolRetryAfter(header: script.prefix(SpoolRetryAfter.keptBytes + SpoolRetryAfter.keptBytes)).milliseconds
        // A floor past its range.
        precondition(retry.map { (0...SpoolBackoff.maxRetryAfterMilliseconds).contains($0) } != false)
        let nodes = [Fixture.me, Fixture.peer].compactMap { NodeId(bytes: [UInt8](repeating: $0, count: NodeId.byteCount)) }
        let keys = (UInt8(0)..<Fixture.scopes).compactMap { index in
            ScopeKeys(id: Player.filled(index), sealKey: Player.filled(Fixture.seal), nonceKey: Player.filled(Fixture.nonce))
        }
        return zip(nodes.prefix(1), nodes.dropFirst()).reduce(0) { _, pair in run(script, me: pair.0, peer: pair.1, keys: keys) }
    }

    /// Plays `script` as `me`, sharing a scope of each of `keys` with `peer`; the last retires. A test passes keys a frame
    /// of its own seals under, so the heal's candidates and their settlements run too.
    @discardableResult
    public static func run(_ script: [UInt8], me: NodeId, peer: NodeId, keys: [ScopeKeys]) -> Int {
        let scopes = keys.enumerated().compactMap { index, key in SpoolScope.of(key, peer: peer, retiring: index == keys.count - 1) }
        guard !scopes.isEmpty else {
            return 0
        }
        var player = Player(script, me: me, scopes: scopes)
        return player.play()
    }

    /// What a script's op byte asks, in byte order.
    private enum Step: CaseIterable {
        case receive
        case tick
        case subscribe
        case listAndPull
        case push
        case close
        case reopen
        case answer
        case round
        case outbound
        case readopt
    }

    /// The fixed keys the harness's scopes and nodes are made of.
    private enum Fixture {
        static let idBytes = SpoolRecordLayer.idByteCount
        static let peer: UInt8 = 0x42
        static let me: UInt8 = 0x24
        static let seal: UInt8 = 0x51
        static let nonce: UInt8 = 0x52
        static let scopes: UInt8 = 4
        static let byteBits = 8
        static let maxPulled = 4
    }

    private struct Player {
        var bytes: ArraySlice<UInt8>
        var session: SpoolSession?
        var heal: ScopeHeal
        /// The searches asked for and not yet answered or cancelled, oldest first.
        var asked: [SpoolMiningRequest] = []
        var clock: Int64 = 0
        let scopes: [SpoolScope]

        init(_ script: [UInt8], me: NodeId, scopes: [SpoolScope]) {
            bytes = ArraySlice(script)
            self.scopes = scopes
            heal = ScopeHeal(relay: SpoolRelayHandle(number: 1), me: me)
            heal.adopt(scopes)
        }

        var now: SpoolNow { SpoolNow(monotonic: clock, wall: clock) }

        mutating func play() -> Int {
            session = SpoolSession(openedAt: clock)
            var steps = 0
            while let op = bytes.popFirst() {
                step(op)
                carry()
                check()
                steps += 1
            }
            return steps
        }

        static func filled(_ byte: UInt8) -> [UInt8] {
            [UInt8](repeating: byte, count: Fixture.idBytes)
        }

        mutating func step(_ byte: UInt8) {
            switch Step.allCases[Int(byte) % Step.allCases.count] {
            case .receive:
                let count = Int(take()) << Fixture.byteBits | Int(take())
                let record = Array(bytes.prefix(count))
                bytes = bytes.dropFirst(record.count)
                session?.receive(record)
            case .tick:
                clock = takeInt64()
                session?.tick(now: clock)
                withSession { heal, session, now in heal.tick(session: &session, now: now) }
            case .subscribe:
                let subs = scopes.prefix(Int(take()) % (scopes.count + 1)).map { scope in
                    ScopeSub(scope: scope.id.bytes, bounds: ScopeFrames.bounds)
                }
                _ = session?.subscribe(Array(subs), now: clock)
            case .listAndPull:
                let scope = pick()
                _ = session?.list(scope, now: clock)
                let ids = (0..<Int(take()) % Fixture.maxPulled).compactMap { _ in SpoolID(Self.filled(take())) }
                _ = session?.pull(scope, ids, now: clock)
            case .push:
                let data = Array(bytes.prefix(Int(take())))
                bytes = bytes.dropFirst(data.count)
                let scope = pick()
                if let blobId = SpoolID(ScopeCrypto.blobId(of: data)) {
                    _ = session?.push(scope, blobId: blobId, data: data, pow: nil, now: clock)
                }
            case .close:
                session?.socketClosed()
                carry()
                session = nil
            case .reopen:
                session = session ?? SpoolSession(openedAt: clock)
            case .answer:
                answer(found: take() & 1 == 0)
            case .round:
                let custody: ScopeHeal.Custody = take() & 1 == 0 ? .unreadable : .frames([])
                withSession { heal, session, now in heal.roundStarted(custody, session: &session, now: now) }
            case .readopt:
                // The table loses its last scopes and gets them back: a search for one that left is cancelled.
                heal.adopt(Array(scopes.prefix(Int(take()) % (scopes.count + 1))))
                heal.adopt(scopes)
            case .outbound:
                heal.outboundFull = take() & 1 == 0
                withSession { heal, session, now in heal.outboundDrained(&session, now: now) }
            }
        }

        /// Answers the oldest search asked for, with or without a session.
        mutating func answer(found: Bool) {
            guard !asked.isEmpty else {
                return
            }
            let request = asked.removeFirst()
            heal.stampMined(request, counter: found ? 0 : nil, session: &session, now: now)
            // An answered search is still mining would fail here.
            precondition(heal.mining[request.scope] != request)
        }

        mutating func withSession(_ body: (inout ScopeHeal, inout SpoolSession, SpoolNow) -> Void) {
            guard var open = session else {
                return
            }
            body(&heal, &open, now)
            session = open
        }

        /// Carries the session's outputs into the heal, and the heal's back, until quiet.
        mutating func carry() {
            var steps = 0
            var quiet = false
            while !quiet {
                quiet = true
                let outputs = session?.drain() ?? []
                // One step drained too much would fail here.
                precondition(outputs.count <= Self.maxOutputsPerStep)
                for case .event(let event) in outputs {
                    quiet = false
                    withSession { heal, session, now in heal.handle(event, session: &session, now: now) }
                }
                for output in heal.drain() {
                    quiet = false
                    switch output {
                    case .mine(let request):
                        asked.append(request)
                    case .cancelMining(let request):
                        asked.removeAll { $0 == request }
                    case .candidate(let candidate):
                        let settlement = settlements[Int(take()) % settlements.count]
                        withSession { heal, session, now in heal.settle(candidate, settlement, session: &session, now: now) }
                    }
                }
                steps += 1
                // The heal and the session never went quiet would fail here.
                precondition(steps < Self.maxOutputsPerStep)
            }
        }

        func check() {
            // A search mining that nobody asked for, or one asked and lost would fail here.
            precondition(Set(heal.mining.values) == Set(asked) && Set(asked).count == asked.count)
            guard let session else {
                return
            }
            for scope in scopes {
                let inFlight = session.pending.values.filter { $0.scope == scope.id }.reduce(0) { $0 + $1.unserved.count }
                // Claims past the bound would fail here.
                precondition(session.claimCount(scope.id) <= SpoolSession.maxClaimsPerScope + inFlight + 1)
            }
        }

        mutating func pick() -> SpoolID {
            scopes[Int(take()) % scopes.count].id
        }

        /// The next byte, or 0 once the script ran out.
        mutating func take() -> UInt8 {
            bytes.popFirst() ?? 0
        }

        mutating func takeInt64() -> Int64 {
            (0..<MemoryLayout<Int64>.size).reduce(Int64(0)) { value, _ in value << Fixture.byteBits | Int64(take()) }
        }

        static let maxOutputsPerStep = SpoolSessionFuzz.maxOutputsPerStep
        let settlements: [ScopeHeal.Settlement] = [
            .notTaken, .unopenable, .refusedByCarry, .delivered(keptLive: true), .delivered(keptLive: false),
        ]
    }
}
