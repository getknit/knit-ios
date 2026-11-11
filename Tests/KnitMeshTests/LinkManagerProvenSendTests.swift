import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``LinkManager/sendOverProvenLink(_:to:)`` (ADR 2026-11.prsp): a ctl 11 is written only over a link that proved the id it
/// is for, never over an unproven claimant's link, which ``LinkManager/send(_:to:)`` would write to. A proof retires every
/// unproven link for its id before the proven one registers, so the two never stand together; the method guards the gap
/// where only the claimant's stands.
@Suite struct LinkManagerProvenSendTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    private func frames(_ rig: LinkRig, on id: ChannelID) -> [WireEnvelope] {
        rig.radio.frames(on: id)
    }

    @Test func anUnprovenLinkTakesNothingAndAProvenOneTakesTheFrame() throws {
        let rig = LinkRig(local: high)
        let unproven = ChannelID(100)
        // A HELLO without the bit runs no proof: the link stands, unproven.
        _ = rig.accept(low, on: unproven, capabilities: 0xFFF)
        #expect(rig.links.isLinked(low) && !rig.links.hasProvenLink(to: low))
        let wire = LinkRig.signedFrame("pk-1")
        #expect(!rig.links.sendOverProvenLink(wire, to: low))
        #expect(frames(rig, on: unproven).isEmpty, "nothing on the unproven link")

        let proven = ChannelID(101)
        let (hello, _) = rig.acceptProving(low, on: proven)
        _ = try rig.proveDialer(low, on: proven, hello: hello)
        #expect(rig.links.hasProvenLink(to: low))
        #expect(rig.links.sendOverProvenLink(wire, to: low))
        #expect(frames(rig, on: proven).map(\.signed) == [wire.signed])
        #expect(rig.radio.closed.contains(unproven), "the proof retired the unproven link: the two never stand together")
        // Once across, the same frame is not written to that link again, and the send still counts as taken.
        #expect(rig.links.sendOverProvenLink(wire, to: low))
        #expect(frames(rig, on: proven).count == 1)
    }

    /// A frame too large for one record is never written, and nothing takes it.
    @Test func aFrameTooLargeForARecordTakesNothing() throws {
        let rig = LinkRig(local: high)
        let proven = ChannelID(101)
        let (hello, _) = rig.acceptProving(low, on: proven)
        _ = try rig.proveDialer(low, on: proven, hello: hello)
        let huge = WireEnvelope(sig: [1], signed: [UInt8](repeating: 7, count: LinkRecord.maxPayloadBytes + 1))
        #expect(!rig.links.sendOverProvenLink(huge, to: low))
        #expect(frames(rig, on: proven).isEmpty)
        #expect(rig.log.all.contains("warning link dropped a frame too large for a record"))
    }

    @Test func nobodyLinkedTakesNothing() {
        let rig = LinkRig(local: high)
        #expect(!rig.links.hasProvenLink(to: low))
        #expect(!rig.links.sendOverProvenLink(LinkRig.signedFrame("pk-2"), to: low))
    }
}
