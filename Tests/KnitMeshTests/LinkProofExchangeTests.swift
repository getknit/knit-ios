import KnitCrypto
import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// The link's proof of the id its HELLO claims, on each side of the exchange (the `link-hello-proof` contract, §5; knit-ios
/// #25): who writes what, when the link registers, and what fails the proof.
@Suite struct LinkProofExchangeTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high
    private let proving = Neighbor(nodeId: LinkRig.low, protocolVersion: 1, capabilities: LinkRig.provingCapabilities)

    private func counts(_ rig: LinkRig) -> [Int] {
        [rig.links.linksProven, rig.links.linkProofFailed, rig.links.linkClaimRefused]
    }

    // MARK: Both sides prove

    @Test func aResponderAnswersWithItsHelloAndProofInOneWriteAndRegistersOnlyOnTheDialersProof() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let (hello, events) = rig.acceptProving(low, on: id)
        #expect(events.isEmpty, "nothing registers before the dialer's proof")
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.radio.writes(on: id).count == 1, "the reply and the PROOF in one write")
        let records = rig.radio.records(on: id)
        #expect(records.map(\.tag) == [.hello, .proof])
        let reply = try #require(records.first?.payload)
        #expect(LinkRig.isOurHello([records[0]], high))
        let ours = LinkProof.verify(
            records[1].payload, claimedId: high, form: .plain, signer: .responder, dialerHello: hello, responderHello: reply)
        #expect(ours == .proven(LinkRig.keys(of: high).bundle), "our proof signs both HELLOs as they crossed")
        #expect(rig.radio.hellos.map(\.node) == [low], "the HELLO was heard")
        #expect(rig.radio.linkUps.isEmpty)
        #expect(try rig.proveDialer(low, on: id, hello: hello) == [.up(proving)])
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(rig.radio.linkUps == [FakeRadio.HeardHello(node: low, channel: id)])
        #expect(rig.radio.records(on: id).count == 2, "nothing more written")
        #expect(counts(rig) == [1, 0, 0])
        #expect(rig.said("link \(low) proved itself on \(id)"))
    }

    /// A bad record's warning names the end of the record before it, never a PROOF's signature or a HELLO's nonce.
    @Test func aBadRecordAfterAProofShowsNoneOfIt() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let (hello, _) = rig.acceptProving(low, on: id)
        _ = try rig.proveDialer(low, on: id, hello: hello)
        _ = rig.handle(.received(id, [0x57, 0x36, 0x00, 0x01, 0x02]))
        let line = try #require(rig.log.all.first { $0.hasPrefix("warning link \(id) sent a bad record") })
        #expect(line.contains("after hello \(hello.count), proof \(LinkProof.payloadByteCount);"))
        #expect(!line.contains(" ending "))
    }

    /// A legacy HELLO carries no nonce, so its tail stays in the warning: the clue for a reader that lost its place after it.
    @Test func aBadRecordAfterALegacyHelloShowsItsTail() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let hello = LinkRig.helloRecord(low)
        _ = rig.handle(.accepted(id))
        _ = rig.handle(.received(id, hello + [0x57, 0x36, 0x00, 0x01, 0x02]))
        let line = try #require(rig.log.all.first { $0.hasPrefix("warning link \(id) sent a bad record") })
        #expect(line.contains("after hello \(hello.count - 5) ending \(Hex.encode(Array(hello.suffix(16))))"))
    }

    @Test func aDialerWritesItsProofOnceTheRespondersVerifiesThenRegisters() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        #expect(LinkRig.isOurHello(rig.radio.records(on: id), high))
        let (reply, events) = try rig.answerProving(low, on: id)
        #expect(events == [.up(proving)])
        let records = rig.radio.records(on: id)
        #expect(records.map(\.tag) == [.hello, .proof])
        let ours = try #require(rig.ourHelloPayload(on: id))
        let proof = LinkProof.verify(
            records[1].payload, claimedId: high, form: .plain, signer: .dialer, dialerHello: ours, responderHello: reply)
        #expect(proof == .proven(LinkRig.keys(of: high).bundle))
        #expect(counts(rig) == [1, 0, 0])
    }

    @Test func recordsBehindTheProofAreHandledAfterTheLinkIsUp() throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let (hello, _) = rig.acceptProving(low, on: id)
        let reply = try #require(rig.ourHelloPayload(on: id))
        let proof = try LinkRig.proofRecord(LinkRig.keys(of: low), as: .dialer, dialerHello: hello, responderHello: reply)
        let wire = LinkRig.signedFrame("behind")
        let events = rig.handle(.received(id, proof + LinkRig.frameRecord(wire)))
        #expect(events.count == 2)
        #expect(events.first == .up(proving))
        guard case .frame(let frame) = events.last else {
            Issue.record("the frame behind the proof was not handled: \(events)")
            return
        }
        #expect(frame.wire == wire && frame.from == low)
    }

    // MARK: Builds from before the proof

    @Test func aLegacyDialerLinksUnprovenAndIsNeverWrittenAProof() {
        let rig = LinkRig(local: high)
        let events = rig.accept(low, on: ChannelID(100))
        #expect(events == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))])
        #expect(rig.radio.records(on: ChannelID(100)).map(\.tag) == [.hello], "our reply still carries the bit and a nonce")
        #expect(LinkRig.isOurHello(rig.radio.records(on: ChannelID(100)), high))
        #expect(counts(rig) == [0, 0, 0])
    }

    @Test func aLegacyResponderLinksUnprovenAndIsNeverWrittenAProof() throws {
        let rig = LinkRig(local: high)
        let id = try rig.link(low)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(rig.radio.records(on: id).map(\.tag) == [.hello])
        #expect(counts(rig) == [0, 0, 0])
    }

    // MARK: Failed proofs

    /// Each failure closes the link with nothing registered and counts once, and its line names the reason, never `timed
    /// out`, which the harness reads as a missed HELLO.
    private func expectFailed(_ rig: LinkRig, on id: ChannelID, claiming peer: NodeId, why: String, events: [LinkManager.Event]) {
        #expect(events.isEmpty, "\(why): nothing registered")
        #expect(rig.links.neighbors.isEmpty, "\(why)")
        #expect(rig.radio.closed == [id], "\(why)")
        #expect(rig.radio.linkUps.isEmpty, "\(why)")
        #expect(counts(rig) == [0, 1, 0], "\(why)")
        #expect(rig.said("link \(id) proof failed for \(peer): \(why)"), "\(why): \(rig.log.all)")
        #expect(!rig.log.all.contains { $0.contains("link \(id) timed out") })
    }

    @Test func aResponderWhoseDialerSendsNoProofInTimeFailsIt() {
        let rig = LinkRig(local: high)
        _ = rig.acceptProving(low, on: ChannelID(100))
        let events = rig.advance(5000)
        expectFailed(rig, on: ChannelID(100), claiming: low, why: "timeout", events: events)
    }

    @Test func aDialerThatHangsUpWhereItsProofBelongsFailsIt() {
        let rig = LinkRig(local: high)
        _ = rig.acceptProving(low, on: ChannelID(100))
        let events = rig.handle(.closed(ChannelID(100)))
        #expect(events.isEmpty)
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.said("link ch100 proof failed for \(low): eof"))
    }

    @Test func anotherRecordWhereTheProofBelongsFailsIt() {
        let rig = LinkRig(local: high)
        _ = rig.acceptProving(low, on: ChannelID(100))
        let events = rig.handle(.received(ChannelID(100), LinkRig.frameRecord(LinkRig.signedFrame("early"))))
        expectFailed(rig, on: ChannelID(100), claiming: low, why: "record", events: events)
    }

    @Test func aHelloCarryingTheBitWithoutANonceFailsTheProofUnanswered() {
        let rig = LinkRig(local: high)
        let events = rig.accept(low, on: ChannelID(100), capabilities: LinkRig.provingCapabilities)
        expectFailed(rig, on: ChannelID(100), claiming: low, why: "nonce", events: events)
        #expect(rig.radio.records(on: ChannelID(100)).isEmpty, "no reply")
    }

    /// The contract's `proofRejects` shapes, made with ``LinkProof`` until Android's `keyed-v1.json` carries them.
    @Test(arguments: ["wrong role", "other nonce", "other keys", "127 bytes"])
    func aProofOfTheWrongShapeFailsIt(shape: String) throws {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        let (hello, _) = rig.acceptProving(low, on: id)
        let reply = try #require(rig.ourHelloPayload(on: id))
        let alice = LinkRig.keys(of: low)
        let payload: [UInt8]
        let why: String
        switch shape {
        case "wrong role":
            payload = try LinkProof.payload(keys: alice, form: .plain, signer: .responder, dialerHello: hello, responderHello: reply)
            why = "bad signature"
        case "other nonce":
            var other = Hello(payload: reply)
            other.nonce = [UInt8](repeating: 0xFF, count: Hello.nonceByteCount)
            payload = try LinkProof.payload(keys: alice, form: .plain, signer: .dialer, dialerHello: hello, responderHello: other.payload)
            why = "bad signature"
        case "other keys":
            payload = try LinkProof.payload(
                keys: LinkRig.keys(of: middle), form: .plain, signer: .dialer, dialerHello: hello, responderHello: reply)
            why = "id mismatch"
        default:
            payload = Array(
                try LinkProof.payload(keys: alice, form: .plain, signer: .dialer, dialerHello: hello, responderHello: reply).dropLast())
            why = "length"
        }
        let events = rig.handle(.received(id, LinkRecord(.proof, payload: payload).encoded ?? []))
        expectFailed(rig, on: id, claiming: low, why: why, events: events)
    }

    @Test func aDialerWhoseProofFailsBacksOffAndDialsAgainAfter() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        let reply = LinkRig.provingHello(low).payload
        let bad = [UInt8](repeating: 1, count: LinkProof.payloadByteCount)
        let events = rig.handle(
            .received(id, (LinkRecord(.hello, payload: reply).encoded ?? []) + (LinkRecord(.proof, payload: bad).encoded ?? [])))
        #expect(events.isEmpty)
        #expect(rig.radio.closed == [id])
        #expect(rig.radio.records(on: id).map(\.tag) == [.hello], "we write no proof to a peer whose own failed")
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.radio.dials.count == 1, "backing off")
        rig.advance(15_000, hearing: low)
        #expect(rig.radio.dials.count == 2, "dialable again once its backoff ran out")
    }

    @Test func aDialerThatTimesOutAwaitingTheProofBacksOff() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        _ = rig.handle(.received(id, LinkRecord(.hello, payload: LinkRig.provingHello(low).payload).encoded ?? []))
        #expect(rig.advance(5000, hearing: low).isEmpty)
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.said("link \(id) proof failed for \(low): timeout"))
        #expect(rig.radio.dials.count == 1, "backing off")
        rig.advance(15_000, hearing: low)
        #expect(rig.radio.dials.count == 2)
    }

    // MARK: Stages

    @Test func eachStageOfTheHandshakeIsPutOffOnce() {
        // In the background, a deadline found late passed while iOS had the app suspended: the HELLO's and the PROOF's
        // each get their own put-off.
        let rig = LinkRig(local: high, background: true)
        _ = rig.handle(.accepted(ChannelID(100)))
        #expect(rig.advance(7000).isEmpty)
        let hello = LinkRig.provingHello(low).payload
        _ = rig.handle(.received(ChannelID(100), LinkRecord(.hello, payload: hello).encoded ?? []))
        #expect(rig.advance(7000).isEmpty)
        #expect(rig.log.all.filter { $0.contains("found its deadline") }.count == 2)
        #expect(rig.radio.closed.isEmpty)
        #expect(rig.advance(3000).isEmpty)
        #expect(rig.radio.closed == [ChannelID(100)], "the PROOF's grace ran out")
        #expect(counts(rig) == [0, 1, 0])
    }

    @Test func aRefusalClosesAChannelAwaitingThePeersProof() {
        let rig = LinkRig(local: high)
        _ = rig.acceptProving(low, on: ChannelID(100))
        #expect(rig.links.refuse(low).isEmpty)
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(rig.links.channelCount == 0)
    }

    @Test func aPeerProvingItselfOnALinkItDialedIsNotDialed() {
        let rig = LinkRig(local: high)
        _ = rig.acceptProving(low, on: ChannelID(100))
        rig.sightToPromotion(low)
        #expect(rig.radio.dials.isEmpty, "its proof is on its way")
    }
}
