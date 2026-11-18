import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Frames sealed under a ratchet session the receiving engine does not hold, signed by the pair's real peer, and served in
/// the scope that engine derives from the session it does hold: a frame its spool heal pulls and cannot open. The sealer is
/// an ``AndroidPeer`` on the sender's identity over a fresh store, so its first seal initiates; ``RatchetHeader/steady``
/// drops the init and bases the frame on the receiver's first epoch, as a peer in another era sends, and its index moves past
/// the few the confirmed session spent, so the receiver's verdict is a failed tag, never a duplicate index.
struct ForeignSession {
    static let pastHeldIndices = 8

    let sealer: AndroidPeer
    let recipient: TestPeer
    let prekey: PeerPrekey

    /// A second session of `sender`'s toward `recipient`, whose engine is `fixture`.
    init(_ sender: TestPeer, to recipient: TestPeer, at fixture: EngineFixture) throws {
        sealer = try AndroidPeer(sender)
        self.recipient = recipient
        prekey = try fixture.ourPrekey()
    }

    /// A signed DM `tag` stamped `sentAt` that the recipient's session cannot open.
    func dm(_ tag: String, sentAt: Int64) throws -> TestFrame {
        try dm(id: frameIdOf(tag), sentAt: sentAt)
    }

    /// A signed DM under `id`, stamped `sentAt`, that the recipient's session cannot open: a copy of a real DM of the
    /// sender's, under its id, as a peer in another era sealed it.
    func dm(id: String, sentAt: Int64) throws -> TestFrame {
        try sealer.dm(
            MessageContent(body: "unreadable"), to: recipient, prekey: prekey, id: id, sentAt: sentAt
        ) { $0.ratchet = $0.ratchet?.steady.skipping(Self.pastHeldIndices) }
    }

    /// `frame` pushed into `scope` on `lab`'s spool, as any member of the scope may push.
    static func serve(_ frame: TestFrame, in scope: SpoolScope, on lab: SpoolLab) throws {
        var member = RawMember(lab.spool, scope: scope.id)
        let carried = CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
        member.push(try #require(ScopeFrames.seal(carried, into: scope)))
        lab.pump()
    }
}

/// The router's two seen sets against the reset heuristic (ADR 2026-11.adrq, P4a and P4b1): a frame a spool served is
/// never evidence for a reset, and a radio copy of the same id inside the seen window is a duplicate of the spool's mark,
/// so it is neither opened again nor counted. Alice (0) and Bob (1) confirmed over radio; Bob is online with the relay.
@Suite struct SpoolSeenSetsTests {
    static let alice = SpoolEngineLabTests.alice
    static let bob = SpoolEngineLabTests.bob
    static let minute = SpoolEngineLabTests.minute

    private static func drops(_ fixture: EngineFixture) -> Int {
        fixture.engine.dropped.values.reduce(0, +)
    }

    /// The frames whose open failed its tag: the verdict a frame under a session we do not hold earns.
    static func aeadFails(_ fixture: EngineFixture) -> Int {
        fixture.engine.dropped[.ratchetAeadFail] ?? 0
    }

    static func counted(_ fixture: EngineFixture) -> Int {
        fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds
    }

    @Test func aFrameFirstSeenFromASpoolAndThenByRadioCountsTowardNoReset() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let node = lab[1]
        let scope = try #require(lab.scopes(1).first { !$0.retiring }, "bob's confirmed scope")
        let foreign = try ForeignSession(Self.alice, to: Self.bob, at: node)
        let now = node.clock.wallMilliseconds()

        // Two failures off a radio link: one more counted id seals a reset.
        let aeadBefore = Self.aeadFails(node)
        for index in 0..<2 {
            node.deliver(try foreign.dm("radio-\(index)", sentAt: now), from: Self.alice)
        }
        #expect(Self.aeadFails(node) == aeadBefore + 2, "both failed their tag")
        #expect(Self.counted(node) == 2, "a radio link's failures count")
        #expect(node.resetsSent(to: Self.alice).isEmpty)

        // X reaches Bob first by the spool, in the scope he derives, and fails to open.
        let frameX = try foreign.dm("x", sentAt: now)
        let pulled = node.engine.routerCounters.spoolAdmitted
        let dropsBefore = Self.drops(node)
        let aeadPrimed = Self.aeadFails(node)
        try ForeignSession.serve(frameX, in: scope, on: lab)
        #expect(node.engine.routerCounters.spoolAdmitted == pulled + 1, "the heal pulled X once")
        #expect(Self.aeadFails(node) == aeadPrimed + 1, "X reached the open and failed its tag")
        #expect(Self.drops(node) == dropsBefore + 1, "and was dropped for nothing else")
        #expect(node.stores.messages.message(frameX.envelope.id) == nil)
        #expect(Self.counted(node) == 2, "a spool's failure counts nothing")
        #expect(node.resetsSent(to: Self.alice).isEmpty)

        // The same X by radio, inside the seen window.
        lab.advance(5 * Self.minute)
        let duplicates = node.engine.routerCounters.deduplicated
        node.deliver(frameX, from: Self.alice)
        #expect(node.engine.routerCounters.deduplicated == duplicates + 1, "the radio copy is a duplicate of the spool's mark")
        #expect(Self.aeadFails(node) == aeadPrimed + 1, "X is not opened a second time")
        #expect(Self.drops(node) == dropsBefore + 1, "nor dropped for any other reason")
        #expect(Self.counted(node) == 2, "the radio copy counts nothing either")
        #expect(node.resetsSent(to: Self.alice).isEmpty, "no reset")

        // The control: a fresh id from the same session off the link is the third counted failure.
        node.deliver(try foreign.dm("radio-2", sentAt: now), from: Self.alice)
        #expect(node.resetsSent(to: Self.alice).count == 1, "a fresh radio failure is the third and seals the reset X would have")
    }

    /// What ``staleCopyAfterAReset(_:_:)`` leaves: Alice's three DMs, the copy of each Bob heard by radio, Alice's first-pass
    /// re-seal of the last, kept off the radio, when X's radio failure reopened it on Bob's monotonic clock, and when
    /// Alice adopted the reset and her second pass falls due on hers.
    struct ResetLeaves {
        let ids: [String]
        let stale: [TestFrame]
        let firstReseal: Written
        let xFailedAt: Int64
        let adoptedAt: Int64
        let secondPassDue: Int64
    }

    /// How ``staleCopyAfterAReset(_:_:)`` times the reset, and what runs at its two turns.
    struct ResetTiming {
        /// How long before the two failures that seal the reset X's own failed, and was reopened.
        var xFailsEarlier: Int64 = 0
        /// Whether X reaches Bob by radio at all; when it does not, a third id's failure takes its place, so custody never
        /// holds X and nothing reopens it.
        var xByRadio = true
        /// How long Bob's reset is held on the radio before it reaches Alice.
        var reachesAliceAfter: Int64 = 0
        /// Runs just before the reset reaches Alice, with Alice's three ids.
        var beforeAdoption: (([String]) -> Void)?
        /// Runs just before the radio hands Alice's re-seals over.
        var beforeConfirm: (() -> Void)?
    }

    /// Alice sends three DMs with the radio down; Bob hears each id by radio under a session he does not hold, each copy
    /// signed once, X (the third id) first, and the third counted failure seals his reset, a fresh root that exports no
    /// scope until it is answered (knit-next ADR 2026-10.j67x is deferred, `RatchetSessions.exports`). Alice adopts it and
    /// re-seals all three; the radio hands Bob the re-seals of the first two, which confirm the fresh root, and keeps the
    /// third's back, as a relay that saw the id inside its window drops it. Alice's original seals are dropped too, so only
    /// the re-seals reach Bob.
    static func staleCopyAfterAReset(_ lab: SpoolLab, _ timing: ResetTiming = ResetTiming()) throws -> ResetLeaves {
        let (aliceNode, bobNode) = (lab[0], lab[1])
        let ids = try (0..<3).map { try #require(aliceNode.engine.sendDirectMessage("lost \($0)", to: Self.bob.nodeId)).id }
        let keys = Set(ids.map(ExactKey.init))
        let originals = Set(aliceNode.transport.written(.chat).filter { keys.contains(ExactKey($0.envelope.id)) }.map(\.wire.signed))
        lab.radio.link(0, 1, holding: [(from: 0, to: 1)])
        if timing.reachesAliceAfter > 0 {
            lab.radio.hold(from: 1, to: 0)
        }
        let foreign = try ForeignSession(Self.alice, to: Self.bob, at: bobNode)
        let now = bobNode.clock.wallMilliseconds()
        let stale = try ids.map { try foreign.dm(id: $0, sentAt: now) }
        bobNode.deliver(timing.xByRadio ? stale[2] : try foreign.dm("in X's place", sentAt: now), from: Self.alice)
        let xFailedAt = bobNode.clock.monotonicMilliseconds()
        if timing.xFailsEarlier > 0 {
            lab.advance(timing.xFailsEarlier)
        }
        for frame in stale.prefix(2) {
            bobNode.deliver(frame, from: Self.alice)
        }
        #expect(Self.aeadFails(bobNode) == 3 && bobNode.resetsSent(to: Self.alice).count == 1, "three radio failures seal one reset")
        if timing.reachesAliceAfter > 0 {
            lab.advance(timing.reachesAliceAfter)
        }
        timing.beforeAdoption?(ids)
        if timing.reachesAliceAfter > 0 {
            lab.radio.release(from: 1, to: 0)
        }
        lab.pump()
        #expect(lab.scopes(1).isEmpty, "an unanswered reset exports no scope")
        let due = try #require(aliceNode.engine.resetReseal.pending[Self.bob.nodeId]?.dueAt, "Alice adopted it and owes a second pass")
        timing.beforeConfirm?()
        let kept = Self.releaseHoldingBack(ids[2], dropping: originals, on: lab)
        let firstReseal = try #require(kept.first, "the first pass re-sealed the third id")
        #expect(kept.count == 1)
        return ResetLeaves(
            ids: ids,
            stale: stale,
            firstReseal: firstReseal,
            xFailedAt: xFailedAt,
            adoptedAt: due - ResetReseal.secondPassMilliseconds,
            secondPassDue: due
        )
    }

    /// Hands Bob what the radio held from Alice but her `originals` and her re-seal of `id`, which it answers.
    private static func releaseHoldingBack(_ id: String, dropping originals: Set<[UInt8]>, on lab: SpoolLab) -> [Written] {
        var kept: [Written] = []
        lab.radio.release(from: 0, to: 1) { items in
            items.filter { item in
                guard case .frame(let written) = item, !originals.contains(written.wire.signed) else {
                    return item.id == nil
                }
                guard ExactKey(written.envelope.id) == ExactKey(id) else {
                    return true
                }
                kept.append(written)
                return false
            }
        }
        lab.pump()
        return kept
    }

    /// Whether `node`'s router holds a mark for `frame`'s id that the spool's door would read as seen, asked of a copy of
    /// the router so nothing is marked.
    static func spoolMarks(_ node: EngineFixture, _ frame: TestFrame) -> Bool {
        var probe = node.engine.router
        return probe.admitPulled(envelope: frame.envelope, now: node.clock.monotonicMilliseconds()) == .duplicate
    }

    /// Both sides' view of the pair: confirmed, and the root's hash as each shows it.
    static func rootHashes(_ lab: SpoolLab) -> [String?] {
        [(0, bob), (1, alice)].map { index, peer in
            lab[index].engine.ratchetPeers().first { $0.peer == peer.nodeId }.flatMap { $0.confirmed ? $0.rootHash : nil }
        }
    }

    /// The relay-replay case (spool.md, "Before P7"): three radio failures seal Bob's reset, and once Alice's answer confirms
    /// it the replaced root's scope, kept retiring, serves the copy of X Bob already failed by radio, `servedAfter` past X's
    /// failure, before Alice's re-seal of X arrives by radio. Inside the radios' window the reopen is the cheap path: custody
    /// holds those very bytes, so the copy settles unopened. Past it the copy is opened once and fails, and the door takes
    /// its mark back. Either way it counts nothing, buys no reset and leaves no mark, so the re-seal lands: the first pass
    /// when it comes inside the window, the second pass otherwise. The honest path, where Alice's own heal pushes her
    /// custodied X, is ``aHealPushOfTheOriginalAfterAResetMarksNothingAndTheSecondPassLands(pushedAfter:)``.
    @Test(arguments: [2 * ScopeHeal.healFloorMilliseconds, 2 * SpoolEngineLabTests.minute, 630_000])
    func aStaleCopyFromTheRetiringScopeCountsNothingAndTheSecondPassLands(servedAfter: Int64) throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let bobNode = lab[1]
        let left = try Self.staleCopyAfterAReset(lab)
        let frameX = left.ids[2]
        #expect(left.ids.prefix(2).allSatisfy { bobNode.stores.messages.message($0) != nil }, "the first two landed")
        #expect(lab.radio.sessionsAgree(0, 1), "and confirmed Bob's reset")
        let inWindow = servedAfter < SeenSet.defaultWindowMilliseconds
        lab.advance(max(0, left.xFailedAt + servedAfter - bobNode.clock.monotonicMilliseconds()))
        let kept = lab.scopes(1).first(where: \.retiring)
        let retiring = try #require(kept, "the replaced root's scope, kept retiring")

        let counted = Self.counted(bobNode)
        let aeadBefore = Self.aeadFails(bobNode)
        let before = bobNode.engine.routerCounters
        try ForeignSession.serve(left.stale[2], in: retiring, on: lab)
        let after = bobNode.engine.routerCounters
        let served = after.spoolReopened + after.spoolAdmitted - before.spoolReopened - before.spoolAdmitted
        #expect(served == 1, "the retiring scope served X's old seal")
        #expect(!Self.spoolMarks(bobNode, left.stale[2]), "and no mark of X remains")
        #expect(bobNode.stores.messages.message(frameX) == nil, "which opens nothing")
        #expect(Self.aeadFails(bobNode) == aeadBefore + (inWindow ? 0 : 1), "unopened while the reopen holds, else opened once")
        #expect(Self.counted(bobNode) == counted, "a spool's copy counts nothing")
        #expect(bobNode.resetsSent(to: Self.alice).count == 1, "and seals no second reset")
        #expect(after.spoolBridged == before.spoolBridged, "nor goes onto the radios")

        if inWindow {
            let duplicates = bobNode.engine.routerCounters.deduplicated
            let first = left.firstReseal
            bobNode.engine.receiveAdmitted(InboundFrame(wire: first.wire, envelope: first.envelope, from: Self.alice.nodeId))
            lab.pump()
            #expect(bobNode.engine.routerCounters.deduplicated == duplicates, "the first pass is not taken for the spool's copy")
        }
        Self.secondPassLands(lab, left, after: bobNode.engine.routerCounters.deduplicated, counted: counted)
    }

    /// The retiring scope serves X's failed bytes twice: five minutes after the reset, inside the reopen's window, and again
    /// 601 s after X's failure, past it. The first settles unopened, the second is opened once, neither leaves a mark, and
    /// the second pass lands X.
    @Test func theRetiringScopeServingXsFailedBytesInsideAndPastTheWindowLeavesNoMark() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let bobNode = lab[1]
        let left = try Self.staleCopyAfterAReset(lab)
        let stale = left.stale[2]
        let counted = Self.counted(bobNode)
        let aeadBefore = Self.aeadFails(bobNode)

        lab.advance(max(0, left.adoptedAt + 5 * Self.minute - lab[0].clock.monotonicMilliseconds()))
        let kept = lab.scopes(1).first(where: \.retiring)
        let retiring = try #require(kept, "the replaced root's scope, kept retiring")
        try ForeignSession.serve(stale, in: retiring, on: lab)
        #expect(bobNode.engine.routerCounters.spoolReopened == 1, "the cheap path")
        #expect(Self.aeadFails(bobNode) == aeadBefore && !Self.spoolMarks(bobNode, stale), "settled unopened, unmarked")

        lab.advance(max(0, left.xFailedAt + 601_000 - bobNode.clock.monotonicMilliseconds()))
        // The spool sheds the scope and Bob joins again, so the same blob is new to both and reaches the door once more.
        let stillKept = lab.scopes(1).first(where: \.retiring)
        let later = try #require(stillKept, "still retiring")
        lab.spool.shed(later.id)
        lab.disconnect(1)
        lab.connect(1)
        try ForeignSession.serve(stale, in: later, on: lab)
        #expect(Self.aeadFails(bobNode) == aeadBefore + 1, "past the window it is opened once")
        #expect(!Self.spoolMarks(bobNode, stale), "and its mark taken back")
        Self.secondPassLands(lab, left, after: bobNode.engine.routerCounters.deduplicated, counted: counted)
    }
}
