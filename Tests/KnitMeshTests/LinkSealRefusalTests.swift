import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What the seal refuses and forgets, and knit-peer's switches (the `link-seal` contract, §3 and §7): a plain link between
/// two sealing builds, the GATT payload forgotten once after a plain dial got no reply, and stray seal records.
@Suite struct LinkSealRefusalTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// `linksSealed`, `linkSealFailed`, `linkSealRefused`, then `linksProven` and `linkProofFailed`.
    private func counts(_ rig: LinkRig) -> [Int] {
        [rig.links.linksSealed, rig.links.linkSealFailed, rig.links.linkSealRefused, rig.links.linksProven, rig.links.linkProofFailed]
    }

    // MARK: Plain links between sealing builds (§7)

    @Test func aResponderRefusesAPlainDialFromASealingBuildBeforeReplying() {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        _ = rig.acceptProving(low, on: id, capabilities: Capabilities.local.union(.blobHave))
        #expect(rig.radio.writes(on: id).isEmpty, "no reply")
        #expect(rig.radio.closed.contains(id))
        #expect(counts(rig) == [0, 0, 1, 0, 0])
        #expect(rig.said("link refused \(low): a plain link between two sealing builds"))
        #expect(rig.links.backoffs.isEmpty)
    }

    @Test func aDialerRefusesAReplyFromASealingBuildOnAPlainLinkWithNoProof() throws {
        // An advert with no seal's flag, stale or stripped, makes a plain dial.
        let plain = LinkRig(local: high)
        plain.sightToPromotion(low)
        let channel = try #require(plain.radio.dials.last?.channel)
        _ = plain.handle(.connected(channel))
        let reply = Hello(nodeId: low.string, capabilities: Capabilities.local.union(.blobHave), nonce: LinkProof.freshNonce()).payload
        _ = plain.handle(.received(channel, LinkRecord.bytes(.hello, reply)))
        #expect(plain.radio.records(on: channel).map(\.tag) == [.hello], "no PROOF of ours")
        #expect(counts(plain) == [0, 0, 1, 0, 0])
        #expect(plain.links.backoffs[.peer(.node(low))] != nil)
    }

    @Test func knitPeersDowngradeLeavesTheRefusalToTheFarEnd() {
        let rig = LinkRig(local: high)
        rig.links.sealSwitch = .downgrade
        let id = ChannelID(100)
        _ = rig.acceptProving(low, on: id, capabilities: Capabilities.local.union(.blobHave))
        let records = rig.radio.records(on: id)
        #expect(records.map(\.tag) == [.hello, .proof], "a plain reply")
        #expect(Hello(payload: records[0].payload).capabilities.contains(.linkSeal), "claiming the bit")
        #expect(counts(rig) == [0, 0, 0, 0, 0])
    }

    // MARK: §7's forget-once rule (revision 1)

    @Test func aPlainDialWithNoReplyAsksTheRadioToForgetThePayload() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.last?.channel)
        _ = rig.handle(.connected(id))
        _ = rig.handle(.closed(id))
        #expect(rig.radio.noReplies == [RadioAddress("addr-\(low)")])
        let silent = LinkRig(local: high)
        silent.sightToPromotion(low)
        let other = try #require(silent.radio.dials.last?.channel)
        _ = silent.handle(.connected(other))
        _ = silent.advance(5001)
        #expect(silent.radio.noReplies == [RadioAddress("addr-\(low)")], "a HELLO timeout too")
    }

    @Test func aPlainDialThatGotAReplyOrDidNotClaimTheBitForgetsNothing() throws {
        let replied = LinkRig(local: high)
        let id = try replied.link(low)
        _ = replied.handle(.closed(id))
        #expect(replied.radio.noReplies.isEmpty, "a reply came")
        let off = LinkRig(local: high)
        off.links.sealSwitch = .off
        off.sightToPromotion(low)
        let dialed = try #require(off.radio.dials.last?.channel)
        _ = off.handle(.connected(dialed))
        _ = off.handle(.closed(dialed))
        #expect(off.radio.noReplies.isEmpty, "our HELLO did not carry the bit")
    }

    // MARK: Switches and strays

    @Test func knitPeersSealOffAirsNoFlagAndClosesOnAKeyShare() throws {
        let rig = LinkRig(local: high)
        rig.links.sealSwitch = .off
        _ = rig.handle(.listening(psm: 0x81))
        #expect(try #require(rig.radio.advertised.last).flags & AdvertPayload.linkSealFlag == 0)
        let id = ChannelID(100)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, SealedFarEnd(role: .dialer).keyShare))
        #expect(rig.radio.closed.contains(id))
        #expect(rig.radio.writes(on: id).isEmpty)
        #expect(counts(rig) == [0, 0, 0, 0, 0])
    }

    @Test func knitPeersPlainReplyAnswersAKeyShareWithAPlainHello() {
        let rig = LinkRig(local: high)
        rig.links.sealSwitch = .plainReply
        let id = ChannelID(100)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, SealedFarEnd(role: .dialer).keyShare))
        let records = rig.radio.records(on: id)
        #expect(records.map(\.tag) == [.hello])
        #expect(Hello(payload: records[0].payload).capabilities.contains(.linkSeal))
    }

    @Test func aKeyShareOnALivePlainLinkDropsItAsABadRecord() throws {
        let rig = LinkRig(local: high)
        let id = try rig.link(low)
        let events = rig.handle(.received(id, SealedFarEnd(role: .dialer).keyShare))
        #expect(events.contains(.down(low)))
        #expect(rig.log.all.contains { $0.hasPrefix("warning link \(id) sent a bad record: keyShare") })
        #expect(counts(rig) == [0, 0, 0, 0, 0])
    }
}
