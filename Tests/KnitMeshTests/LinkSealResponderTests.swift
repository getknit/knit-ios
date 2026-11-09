import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A responder's side of the sealed form (the `link-seal` contract, §4): what its first record counts, and the deadline
/// each stage has of its own.
@Suite struct LinkSealResponderTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// The vectors' `shortKeyShare`: a KEY_SHARE header saying 31 bytes, read from the header before the payload.
    private static let shortKeyShare: [UInt8] = [0x0A, 0, 0, 0, 31] + [UInt8](repeating: 0x5E, count: 31)

    @Test func aShortKeyShareOpeningALinkIsAFailedSealOnASealingResponder() {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, Self.shortKeyShare))
        #expect(rig.links.linkSealFailed == 1, "a KEY_SHARE of the wrong length (§4)")
        #expect(rig.links.channels[id] == nil)
        #expect(rig.radio.writes(on: id).isEmpty, "nothing answered")
        #expect(rig.links.backoffs.isEmpty, "a responder does not back off")
        #expect(rig.log.all.contains { $0.hasPrefix("info link \(id) seal failed for (dialer): record badLength(tag: 10, length: 31)") })
    }

    @Test func aBuildThatDoesNotSealReadsAShortKeyShareAsABadRecordOnly() {
        let rig = LinkRig(local: high)
        rig.links.sealSwitch = .off
        let id = ChannelID(100)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, Self.shortKeyShare))
        #expect(rig.links.linkSealFailed == 0)
        #expect(rig.links.channels[id] == nil)
        #expect(rig.log.all.contains { $0.hasPrefix("warning link \(id) sent a bad record") })
    }

    /// The KEY_SHARE re-arms the HELLO's deadline: a dialer that takes most of 5 s for each record still links, and would
    /// time out at the accept's deadline otherwise.
    @Test func theKeyShareGivesTheSealedHelloAFreshDeadline() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.advance(4900)
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        #expect(far.outer == [.keyShare])
        _ = rig.advance(4900)
        #expect(rig.links.channels[id] != nil, "past the accept's 5 s, inside the KEY_SHARE's")
        let hello = SealedFarEnd.hello(low)
        _ = rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, hello))))
        let reply = try #require(try far.take(from: rig, on: id).first { $0.tag == .hello })
        let events = rig.handle(.received(id, try far.seal(try far.proof(low, dialerHello: hello, responderHello: reply.payload))))
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(rig.links.linksSealed == 1)
        #expect(!rig.log.all.contains { $0.contains("link \(id) timed out") })
    }

    /// A KEY_SHARE header that says 32 bytes, its stream ending before they all came: truncation, never a failed seal
    /// (revision 1). The responder closes as for any end before a HELLO.
    @Test func aKeyShareCutShortByTheEndIsNoFailedSealOnAResponder() {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, [0x0A, 0, 0, 0, 32] + [UInt8](repeating: 0x5E, count: 20)))
        #expect(rig.links.channels[id] != nil, "waiting for the rest")
        _ = rig.handle(.closed(id))
        #expect(rig.links.channels[id] == nil)
        #expect(rig.links.linkSealFailed == 0)
        #expect(rig.radio.writes(on: id).isEmpty)
        #expect(rig.links.backoffs.isEmpty)
    }

    /// The responder's KEY_SHARE cut short by the end of the stream is the no-reply refusal, backed off and not counted.
    @Test func aKeyShareCutShortByTheEndIsANoReplyOnADialer() throws {
        let rig = LinkRig(local: high)
        let id = try rig.dialSealed(low)
        _ = rig.handle(.received(id, [0x0A, 0, 0, 0, 32] + [UInt8](repeating: 0x5E, count: 20)))
        #expect(rig.links.channels[id]?.stage == .awaitingKeyShare, "waiting for the rest")
        _ = rig.handle(.closed(id))
        #expect(rig.links.channels[id] == nil)
        #expect(rig.links.linkSealFailed == 0)
        #expect(rig.links.backoffs[.peer(.node(low))] != nil, "backed off as a refusal")
    }
}
