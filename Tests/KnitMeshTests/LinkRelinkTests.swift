import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The relink window in the responder (``RelinkWindow``): a peer below us whose proven link the radio closed, and which
/// redials while we sight it, is admitted out of order within 30 s instead of refused as one we dial. iOS ends a link when
/// the same device connects to it again, and the iPhone redials over the reader's connection at once
/// (`.agents/context/linux-peer.md`, "The iPhone ends a link when the same device connects to it again").
@Suite struct LinkRelinkTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    /// `low` dials `rig` unsighted on `id`, proves itself, and the radio then closes the link: the window opens.
    private func closedByTheRadio(_ rig: LinkRig, on id: ChannelID = ChannelID(100)) throws {
        let (hello, _) = rig.acceptProving(low, on: id)
        let up = try rig.proveDialer(low, on: id, hello: hello)
        #expect(up.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(rig.handle(.closed(id)) == [.down(low)])
    }

    /// `peer` is sighted, then dials `rig` on `id` proving itself: answers the HELLO's payload, and whether we answered.
    private func sightedRedial(_ rig: LinkRig, _ peer: NodeId, on id: ChannelID) -> (hello: [UInt8], answered: Bool) {
        _ = rig.handle(.sighted(LinkRig.sighting(peer)))
        let (hello, _) = rig.acceptProving(peer, on: id)
        return (hello, !rig.radio.closed.contains(id))
    }

    private func isUp(_ events: [LinkManager.Event], _ peer: NodeId) -> Bool {
        events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == peer } else { false } }
    }

    @Test func aSightedProvenDialerBelowUsRedialingWithinThirtySecondsIsAdmittedAndLinks() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        _ = rig.advance(5000)
        let (hello, answered) = sightedRedial(rig, low, on: ChannelID(101))
        #expect(answered, "admitted, not refused as one we dial")
        #expect(!rig.said("link refused \(low): we dial it"))
        #expect(rig.said("link \(low) relinks out of order on ch101"))
        let events = try rig.proveDialer(low, on: ChannelID(101), hello: hello)
        #expect(isUp(events, low))
        #expect(rig.said("link up \(low) on ch101"))
        #expect(!rig.relinkOpen(for: low), "the proven registration closed the window")
    }

    @Test func atThirtySecondsTheDialerIsOneWeDialAgain() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        _ = rig.advance(30_000)
        #expect(!sightedRedial(rig, low, on: ChannelID(101)).answered)
        #expect(rig.said("link refused \(low): we dial it"))
        #expect(!rig.said("link \(low) relinks out of order on ch101"))
    }

    @Test func aLegacyHelloIsRefused() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.accept(low, on: ChannelID(101)).isEmpty)
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link refused \(low): an unproven claim to a node that proves itself"))
        #expect(!rig.said("link \(low) relinks out of order on ch101"))
    }

    @Test func aBogusProofIsClosedAndLeavesTheWindowForTheRealPeer() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        let (bogus, _) = sightedRedial(rig, low, on: ChannelID(101))
        #expect(try rig.proveDialer(low, on: ChannelID(101), hello: bogus, keys: LinkRig.keys(of: middle)).isEmpty)
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.relinkOpen(for: low), "a failed proof consumes nothing")
        let (hello, answered) = sightedRedial(rig, low, on: ChannelID(102))
        #expect(answered)
        #expect(isUp(try rig.proveDialer(low, on: ChannelID(102), hello: hello), low))
    }

    @Test func anotherIdIsRefusedAsBefore() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        #expect(!sightedRedial(rig, middle, on: ChannelID(101)).answered)
        #expect(rig.said("link refused \(middle): we dial it"))
    }

    @Test func aPeerEvictedAtTheBudgetIsRefusedWhenItRedials() throws {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: high, configuration: configuration)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        _ = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        rig.clock.advance(20_000)
        rig.sightToPromotion(middle, rssi: -60)
        #expect(rig.said("link evicting \(low)"))
        // The radio reports the close our eviction asked for, after the channel is gone.
        #expect(rig.handle(.closed(ChannelID(100))).isEmpty)
        #expect(!rig.relinkOpen(for: low))
        #expect(!sightedRedial(rig, low, on: ChannelID(101)).answered, "no eviction loop at the budget")
        #expect(rig.said("link refused \(low): we dial it"))
    }

    @Test func noTeardownOfOursOpensIt() throws {
        let rig = LinkRig(local: high)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        _ = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        _ = rig.links.refuse(low)
        _ = rig.handle(.closed(ChannelID(100)))
        _ = rig.links.permit(low)
        #expect(!rig.relinkOpen(for: low), "a refusal retired the link before the radio's close")
        #expect(!sightedRedial(rig, low, on: ChannelID(101)).answered)
    }

    @Test func theRadioGoingOffForgetsEveryWindow() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        _ = rig.handle(.state(.off))
        _ = rig.handle(.state(.on))
        #expect(!rig.relinkOpen(for: low))
    }
}

extension LinkRig {
    /// Whether the manager's relink window is open for `peer` now (``RelinkWindow``).
    func relinkOpen(for peer: NodeId) -> Bool {
        links.relinkWindow.admits(peer, now: clock.monotonicMilliseconds())
    }
}
