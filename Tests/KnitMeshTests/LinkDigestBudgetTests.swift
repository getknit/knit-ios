import KnitMesh
import KnitWire
import Testing

/// Inbound digests metered per peer: a burst of 2, then one per 30 s, keyed by node id so a relink gets no fresh burst
/// (ADR 2026-10.f5zs).
@Suite struct LinkDigestBudgetTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    /// `peer`'s digest of `ids`, as it arrives on `id`.
    private func digest(_ ids: [String], from rig: LinkRig, on id: ChannelID) -> [LinkManager.Event] {
        rig.handle(.received(id, LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ids)).encoded ?? []))
    }

    @Test func aThirdDigestInsideThirtySecondsIsRefusedAndCountedThenOneMoreIsAdmitted() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        #expect(digest(["a"], from: rig, on: ChannelID(100)) == [.digest(["a"], from: low)])
        rig.clock.advance(1000)
        #expect(digest([], from: rig, on: ChannelID(100)) == [.digest([], from: low)])
        rig.clock.advance(1000)
        #expect(digest([], from: rig, on: ChannelID(100)).isEmpty, "a burst of 2, then one per 30 s")
        #expect(rig.links.refusedDigests == 1)
        #expect(rig.log.all.contains { $0.hasSuffix("link ch100 digest from \(low) refused: over its budget") })
        #expect(rig.links.neighbors.count == 1, "the link stays up")
        rig.clock.advance(27_000)
        #expect(digest([], from: rig, on: ChannelID(100)).isEmpty, "29 s on, the bucket holds less than a token")
        rig.clock.advance(1000)
        #expect(digest([], from: rig, on: ChannelID(100)) == [.digest([], from: low)])
        #expect(digest([], from: rig, on: ChannelID(100)).isEmpty)
        #expect(rig.links.refusedDigests == 3)
    }

    @Test func anHonestCadenceIsNeverRefused() {
        // One at link-up, then the 60 s re-offer (`MeshManager.kt:3025-3048` at `e63f15f4`; `MeshEngine.reoffer`).
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        var admitted = digest(["a"], from: rig, on: ChannelID(100)).count
        for _ in 0..<10 {
            rig.clock.advance(60_000)
            admitted += digest(["a"], from: rig, on: ChannelID(100)).count
        }
        #expect(admitted == 11)
        #expect(rig.links.refusedDigests == 0)
    }

    @Test func aRelinkUnderTheSameIdGetsNoFreshBurstAndAnotherPeersBucketIsItsOwn() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        #expect(digest(["a"], from: rig, on: ChannelID(100)).count == 1)
        rig.clock.advance(5000)
        _ = rig.handle(.closed(ChannelID(100)))
        _ = rig.accept(low, on: ChannelID(101))
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(digest(["a"], from: rig, on: ChannelID(101)).count == 1, "an honest relink inside 30 s still finds a token")
        rig.clock.advance(5000)
        _ = rig.handle(.closed(ChannelID(101)))
        _ = rig.accept(low, on: ChannelID(102))
        #expect(digest(["a"], from: rig, on: ChannelID(102)).isEmpty, "the bucket outlives the link")
        _ = rig.accept(middle, on: ChannelID(103))
        #expect(digest(["b"], from: rig, on: ChannelID(103)) == [.digest(["b"], from: middle)])
        #expect(digest(["b"], from: rig, on: ChannelID(103)) == [.digest(["b"], from: middle)])
        #expect(rig.links.refusedDigests == 1)
    }
}
