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
        try sealer.dm(
            MessageContent(body: "unreadable"), to: recipient, prekey: prekey, id: frameIdOf(tag), sentAt: sentAt
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
    private static let alice = SpoolEngineLabTests.alice
    private static let bob = SpoolEngineLabTests.bob
    private static let minute = SpoolEngineLabTests.minute

    private static func drops(_ fixture: EngineFixture) -> Int {
        fixture.engine.dropped.values.reduce(0, +)
    }

    /// The frames whose open failed its tag: the verdict a frame under a session we do not hold earns.
    private static func aeadFails(_ fixture: EngineFixture) -> Int {
        fixture.engine.dropped[.ratchetAeadFail] ?? 0
    }

    private static func counted(_ fixture: EngineFixture) -> Int {
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
}
