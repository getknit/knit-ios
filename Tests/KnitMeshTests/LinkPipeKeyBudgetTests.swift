import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The keyreq answer budget played on both sides (ADR 2026-10.f5zs, rule 5): a holder whose bucket for a requester is in
/// debt skips the key it asks for, and the requester's own re-ask, at its 60 s re-offer, brings the key and its parked
/// frames home. Two engines and link managers joined by a ``LinkPipe``.
@Suite struct LinkPipeKeyBudgetTests {
    /// Hands `frame` to `node` as from `neighbor`, a phone that is not on any pipe.
    private static func receive(_ frame: TestFrame, at node: PipeNode, from neighbor: TestPeer) {
        node.apply([.frame(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: neighbor.nodeId))])
    }

    @Test func aSkippedKeyRequestIsAnsweredAtTheRequestersNextReAskAndItsParkedFramesDeliver() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        // Both with the profile cap lifted (ADR 2026-10.r88m): the budget counts bytes, so a profile past a whole burst
        // stands for the many in-cap answers that would drain it.
        let holder = lab.node(1, custodyLimits: MeshEngineKeyBudgetTests.liftedProfileCap)
        let requester = lab.node(2, custodyLimits: MeshEngineKeyBudgetTests.liftedProfileCap)
        let sender = TestPeer(seed: 30)
        let large = [TestPeer(seed: 31), TestPeer(seed: 33)]
        let elsewhere = TestPeer(seed: 32)
        // Two profiles each past a whole burst, which the holder carries. A capped link-up round hands the requester one at
        // most, so a keyreq naming both is served at least one that has not crossed.
        let largeProfiles = try large.map { try $0.profile(status: String(repeating: "s", count: 300 * 1024), publishedAt: wall - 1000) }
        for profile in largeProfiles {
            Self.receive(profile, at: holder, from: elsewhere)
        }
        #expect(lab.run(limit: 1000) { holder.engine.footprint.pendingRelays == 0 }, "their flood, to nobody, goes before the link")
        let pipe = lab.link(requester, holder)
        let largeIds = Set(largeProfiles.map(\.envelope.id))
        // The holder pins the sender from a key served to it point to point, which it carries but never floods: only a
        // digest round would hand it on, and the requester's next round is a minute away.
        let senderProfile = try sender.profile(publishedAt: wall - 1000, relay: false)
        Self.receive(senderProfile, at: holder, from: elsewhere)
        #expect(holder.stores.custody.contains(senderProfile.envelope.id))
        // The requester drains its bucket at the holder.
        let drain = try requester.peer.keyRequest(for: large.map(\.nodeId), id: frameIdOf("req-drain"))
        let crossed = pipe.frames.count
        pipe.inject(LinkRecord(.frame, payload: drain.wire.encoded), from: requester)
        lab.pump()
        #expect(pipe.frames.dropFirst(crossed).contains { $0.from == holder.nodeId && largeIds.contains($0.id) }, "served on debt")
        let drained = holder.engine.keyExchange.skippedAnswers
        // The sender's post reaches the holder from elsewhere, and its flood reaches the requester, which has no key.
        let post = try sender.roomPost("Who?", id: frameIdOf("post-flooded"), sentAt: wall)
        Self.receive(post, at: holder, from: elsewhere)
        #expect(lab.run { pipe.frames.contains { $0.from == holder.nodeId && $0.id == post.envelope.id } })
        #expect(requester.engine.footprint.parked == 1, "parked for the key")
        #expect(lab.run(limit: 5000) { holder.engine.keyExchange.skippedAnswers == drained + 1 }, "its keyreq for the sender is skipped")
        let skippedAt = pipe.frames.count
        #expect(!pipe.frames.contains { $0.id == senderProfile.envelope.id }, "no key crossed")
        // The requester's next re-ask, at its 60 s re-offer, is served from a refilled bucket.
        #expect(lab.run(limit: 70_000) { requester.stores.messages.message(post.envelope.id) != nil }, "the parked post delivers")
        let after = pipe.frames.dropFirst(skippedAt)
        let reAsk = try #require(after.firstIndex { $0.from == requester.nodeId && $0.type == .keyRequest })
        let key = try #require(after.firstIndex { $0.from == holder.nodeId && $0.id == senderProfile.envelope.id })
        #expect(reAsk < key, "the key answers the re-ask")
        #expect(after.filter { $0.id == senderProfile.envelope.id }.count == 1, "one copy of the key")
        #expect(holder.engine.keyExchange.skippedAnswers == drained + 1, "the re-ask was served")
        #expect(requester.engine.footprint.parked == 0)
        let converged = lab.run(limit: 300_000) {
            Set(holder.stores.custody.liveIds(now: lab.clock.wallMilliseconds()))
                == Set(requester.stores.custody.liveIds(now: lab.clock.wallMilliseconds()))
        }
        #expect(converged, "both custodies hold the same live ids")
    }
}
