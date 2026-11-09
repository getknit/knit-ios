import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The sealed link on each side of the exchange (the `link-seal` contract, §2, §4, §6 and §7; knit-next #286): who writes
/// what, in which form, what counts a failed seal, and what is refused.
@Suite struct LinkSealExchangeTests {
    private let low = LinkRig.low
    private let high = LinkRig.high
    private let sealing = Neighbor(nodeId: LinkRig.low, protocolVersion: 1, capabilities: Capabilities.local.union(.blobHave))

    /// `linksSealed`, `linkSealFailed`, `linkSealRefused`, then `linksProven` and `linkProofFailed`.
    private func counts(_ rig: LinkRig) -> [Int] {
        [rig.links.linksSealed, rig.links.linkSealFailed, rig.links.linkSealRefused, rig.links.linksProven, rig.links.linkProofFailed]
    }

    // MARK: Both roles seal and prove

    @Test func aDialerSealsAfterTheKeySharesAndProvesUnderTheV2Transcript() throws {
        let rig = LinkRig(local: high)
        let id = try rig.dialSealed(low)
        let far = SealedFarEnd(role: .responder)
        #expect(try far.take(from: rig, on: id).isEmpty)
        #expect(far.outer == [.keyShare], "our KEY_SHARE alone: nothing else until the responder's")
        #expect(rig.links.channels[id]?.stage == .awaitingKeyShare)
        _ = rig.handle(.received(id, far.keyShare))
        let hello = try #require(try far.take(from: rig, on: id).first)
        #expect(hello.tag == .hello)
        #expect(Hello(payload: hello.payload).capabilities.contains(.linkSeal))
        #expect(far.outer == [.keyShare, .sealed], "the HELLO is the first frame")
        let reply = SealedFarEnd.hello(low)
        let proof = try far.proof(low, dialerHello: hello.payload, responderHello: reply)
        let events = rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, reply), proof)))
        #expect(events == [.up(sealing)])
        let ours = try #require(try far.take(from: rig, on: id).first { $0.tag == .proof })
        let shares = try #require(far.shares)
        let verified = LinkProof.verify(
            ours.payload, claimedId: high, form: .sealed(shares), signer: .dialer, dialerHello: hello.payload, responderHello: reply)
        #expect(verified == .proven(LinkRig.keys(of: high).bundle))
        #expect(far.outer.dropFirst().allSatisfy { $0 == .sealed }, "nothing but frames after the KEY_SHARE")
        #expect(counts(rig) == [1, 0, 0, 1, 0])
    }

    @Test func aResponderAnswersAKeyShareAtOnceAndSealsItsReply() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        #expect(far.outer == [.keyShare], "ours, before any admission decision")
        let hello = SealedFarEnd.hello(low)
        #expect(rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, hello)))).isEmpty)
        let answer = try far.take(from: rig, on: id)
        #expect(answer.map(\.tag) == [.hello, .proof])
        let shares = try #require(far.shares)
        let verified = LinkProof.verify(
            answer[1].payload,
            claimedId: high,
            form: .sealed(shares),
            signer: .responder,
            dialerHello: hello,
            responderHello: answer[0].payload
        )
        #expect(verified == .proven(LinkRig.keys(of: high).bundle))
        // Records behind the PROOF, in the same frame, are the live link's.
        let proof = try far.proof(low, dialerHello: hello, responderHello: answer[0].payload)
        let wire = LinkRig.signedFrame("behind")
        let events = rig.handle(.received(id, try far.seal(proof, LinkRig.frameRecord(wire))))
        #expect(events.first == .up(sealing))
        guard events.count == 2, case .frame(let frame) = events[1] else {
            Issue.record("the frame behind the proof was not handled: \(events)")
            return
        }
        #expect(frame.wire == wire)
        #expect(counts(rig) == [1, 0, 0, 1, 0])
    }

    @Test func aRecordSplitAcrossFramesIsReadWhole() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        let hello = LinkRecord.bytes(.hello, SealedFarEnd.hello(low))
        let first = try far.seal(Array(hello.prefix(7)))
        let rest = try far.seal(Array(hello.dropFirst(7)))
        _ = rig.handle(.received(id, first))
        #expect(try far.take(from: rig, on: id).isEmpty)
        _ = rig.handle(.received(id, rest))
        #expect(try far.take(from: rig, on: id).map(\.tag) == [.hello, .proof])
    }

    // MARK: Where the responder's KEY_SHARE belongs

    @Test func aResponderThatClosesWhereItsKeyShareBelongsIsANoReplyNotAFailedSeal() throws {
        let rig = LinkRig(local: high)
        let id = try rig.dialSealed(low)
        _ = rig.handle(.closed(id))
        #expect(rig.links.channels[id] == nil)
        #expect(counts(rig) == [0, 0, 0, 0, 0])
        #expect(rig.links.backoffs[.peer(.node(low))] != nil, "backed off as a refusal")
        #expect(rig.radio.noReplies.isEmpty, "a sealed dial never forgets a payload")
    }

    @Test func aResponderSilentWhereItsKeyShareBelongsTimesOutWithItsOwnLine() throws {
        let rig = LinkRig(local: high)
        let id = try rig.dialSealed(low)
        _ = rig.advance(5001)
        #expect(rig.links.channels[id] == nil)
        #expect(counts(rig) == [0, 0, 0, 0, 0])
        #expect(rig.said("link \(id) got no key share from \(low)"))
        #expect(!rig.log.all.contains { $0.contains("link \(id) timed out") }, "the harness reads that as a missed HELLO")
        #expect(rig.links.backoffs[.peer(.node(low))] != nil)
    }

    @Test func aResponderThatAnswersAKeyShareWithAHelloFailsTheSeal() throws {
        let rig = LinkRig(local: high)
        let id = try rig.dialSealed(low)
        _ = rig.handle(.received(id, LinkRecord.bytes(.hello, SealedFarEnd.hello(low))))
        #expect(rig.links.channels[id] == nil)
        #expect(counts(rig) == [0, 1, 0, 0, 0])
        #expect(rig.radio.closed.contains(id))
        #expect(rig.links.backoffs[.peer(.node(low))] != nil, "a dialer backs off")
        #expect(rig.log.all.contains { $0.hasPrefix("info link \(id) seal failed for \(low): ") })
    }

    @Test func aKeyShareOfTheWrongLengthOrALowOrderPointFailsTheSeal() throws {
        let short = LinkRig(local: high)
        let id = try short.dialSealed(low)
        _ = short.handle(.received(id, [0x0A, 0, 0, 0, 31] + [UInt8](repeating: 1, count: 31)))
        #expect(counts(short) == [0, 1, 0, 0, 0])
        let zero = LinkRig(local: high)
        let other = try zero.dialSealed(low)
        _ = zero.handle(.received(other, LinkRecord.bytes(.keyShare, [UInt8](repeating: 0, count: 32))))
        #expect(counts(zero) == [0, 1, 0, 0, 0])
        #expect(zero.radio.writes(on: other).count == 1, "nothing but our KEY_SHARE went out")
    }

    // MARK: Inside the seal

    @Test(arguments: [
        (Capabilities.local.union(.blobHave).subtracting(.linkSeal), true),
        (Capabilities.local.union(.blobHave).subtracting(.linkProof), true),
        (Capabilities.local.union(.blobHave), false),
    ])
    func aSealedHelloWithoutBothBitsAndANonceFailsTheSealNotTheProof(capabilities: Capabilities, nonce: Bool) throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        let hello = SealedFarEnd.hello(low, capabilities: capabilities, nonce: nonce ? LinkProof.freshNonce() : nil)
        _ = rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, hello))))
        #expect(counts(rig) == [0, 1, 0, 0, 0])
        #expect(rig.links.channels[id] == nil)
        #expect(rig.links.backoffs.isEmpty, "a responder does not back off")
    }

    @Test func aFirstInnerRecordThatIsNotAHelloFailsTheSeal() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        _ = rig.handle(.received(id, try far.seal(LinkRig.frameRecord(LinkRig.signedFrame("early")))))
        #expect(counts(rig) == [0, 1, 0, 0, 0])
    }

    @Test func aPlainRecordAfterTheExchangeFailsTheSeal() {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        _ = rig.handle(.received(id, LinkRecord.bytes(.hello, SealedFarEnd.hello(low))))
        #expect(counts(rig) == [0, 1, 0, 0, 0])
    }

    @Test func aV1ProofOnASealedLinkFailsTheProofOnly() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        let hello = SealedFarEnd.hello(low)
        _ = rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, hello))))
        let reply = try #require(try far.take(from: rig, on: id).first?.payload)
        let v1 = try far.proof(low, form: .plain, dialerHello: hello, responderHello: reply)
        #expect(rig.handle(.received(id, try far.seal(v1))).isEmpty)
        #expect(counts(rig) == [0, 0, 0, 0, 1])
        #expect(rig.links.neighbors.isEmpty)
    }

    @Test func aLiveSealedLinkClosesOnATamperedFrameAndCountsIt() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        let hello = SealedFarEnd.hello(low)
        _ = rig.handle(.received(id, try far.seal(LinkRecord.bytes(.hello, hello))))
        let reply = try #require(try far.take(from: rig, on: id).first?.payload)
        _ = rig.handle(.received(id, try far.seal(try far.proof(low, dialerHello: hello, responderHello: reply))))
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        var frame = try far.seal(LinkRig.frameRecord(LinkRig.signedFrame("tampered")))
        frame[LinkRecord.headerBytes + 3] ^= 0x01
        #expect(rig.handle(.received(id, frame)).contains(.down(low)))
        #expect(counts(rig) == [1, 1, 0, 1, 0])
        #expect(rig.said("link \(id) seal failed for \(low): a frame of \(frame.count - LinkRecord.headerBytes) bytes did not open"))
    }

    @Test func anInnerKeyShareFailsTheSeal() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let far = SealedFarEnd(role: .dialer)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, far.keyShare))
        try far.take(from: rig, on: id)
        _ = rig.handle(.received(id, try far.seal(far.keyShare)))
        #expect(counts(rig) == [0, 1, 0, 0, 0])
    }
}
