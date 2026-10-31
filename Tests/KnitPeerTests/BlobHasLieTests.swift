import KnitCrypto
import KnitPeer
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's `blobhas` lie: our own answer claims the hashes lied about at the sizes set, and nothing else is touched.
@Suite struct BlobHasLieTests {
    private let lied = BlobHash(of: fixtureBytes(20, seed: 1))
    private let honest = BlobHash(of: fixtureBytes(20, seed: 2))
    private let sender = "6b6e69742d6c79696e672d70656572"

    private func answer(_ items: [BlobHasItem], type: FrameType = .blobHas, relay: Bool = false, sig: [UInt8] = []) -> WireEnvelope {
        let content = BlobHasContent(items: items, load: 3, re: "query-id")
        let envelope = RelayEnvelope(type: type, id: "answer-id", senderId: sender, payload: content.encoded)
        return WireEnvelope(ttl: 1, hops: 0, relay: relay, sig: sig, signed: envelope.encoded)
    }

    private func content(of wire: WireEnvelope) throws -> (RelayEnvelope, BlobHasContent) {
        let envelope = try RelayEnvelope(decoding: wire.signed)
        return (envelope, try BlobHasContent(decoding: envelope.payload))
    }

    @Test func everyStateButSendingBecomesHaveAtTheLiedSize() throws {
        let unknown = BlobHolding(rawValue: 9)
        for state in [BlobHolding.notHeld, .fetching, .have, .partial, unknown] {
            let wire = answer([BlobHasItem(hash: lied.string, state: state, size: state == .have ? 10 : nil, held: 4)])
            let (rewritten, hashes) = try #require(BlobHasLie.rewrite(wire, sizes: [lied: 1_200_000]))
            #expect(hashes == [lied])
            let (_, content) = try content(of: rewritten)
            #expect(content.items == [BlobHasItem(hash: lied.string, state: .have, size: 1_200_000)], "state \(state.rawValue)")
        }
    }

    @Test func sendingKeepsItsStateAndEta() throws {
        let wire = answer([BlobHasItem(hash: lied.string, state: .sending, size: 10, eta: 4500)])
        let (rewritten, _) = try #require(BlobHasLie.rewrite(wire, sizes: [lied: 2_000_000]))
        let (_, content) = try content(of: rewritten)
        #expect(content.items == [BlobHasItem(hash: lied.string, state: .sending, size: 2_000_000, eta: 4500)])
    }

    @Test func onlyTheHashesLiedAboutChangeAndNoneIsAdded() throws {
        let other = BlobHash(of: fixtureBytes(20, seed: 3))
        let items = [
            BlobHasItem(hash: honest.string, state: .have, size: 77),
            BlobHasItem(hash: lied.string, state: .notHeld),
            BlobHasItem(hash: "not a hash", state: .notHeld),
        ]
        let wire = answer(items)
        let (rewritten, hashes) = try #require(BlobHasLie.rewrite(wire, sizes: [lied: 5, other: 6]))
        #expect(hashes == [lied])
        let (envelope, content) = try content(of: rewritten)
        #expect(content.items == [items[0], BlobHasItem(hash: lied.string, state: .have, size: 5), items[2]])
        #expect(content.load == 3 && content.re == "query-id")
        let original = try RelayEnvelope(decoding: wire.signed)
        #expect(envelope.id == original.id && envelope.senderId == original.senderId && envelope.type == .blobHas)
        #expect(envelope.sentAt == original.sentAt && envelope.recipientId == nil && envelope.group == nil)
        #expect(rewritten.ttl == wire.ttl && rewritten.hops == wire.hops && !rewritten.relay && rewritten.sig.isEmpty)
    }

    @Test func anAnswerWithNoHashLiedAboutPassesThrough() {
        let wire = answer([BlobHasItem(hash: honest.string, state: .notHeld)])
        #expect(BlobHasLie.rewrite(wire, sizes: [lied: 5]) == nil)
        #expect(BlobHasLie.rewrite(answer([BlobHasItem(hash: lied.string, state: .notHeld)]), sizes: [:]) == nil)
    }

    @Test func anythingButOurOwnUnsignedAnswerPassesThrough() {
        let items = [BlobHasItem(hash: lied.string, state: .notHeld)]
        let sizes = [lied: Int64(5)]
        #expect(BlobHasLie.rewrite(answer(items, sig: [UInt8](repeating: 1, count: 64)), sizes: sizes) == nil, "signed")
        #expect(BlobHasLie.rewrite(answer(items, relay: true), sizes: sizes) == nil, "relayed")
        #expect(BlobHasLie.rewrite(answer(items, type: .blobHave), sizes: sizes) == nil, "another type")
        let garbage = RelayEnvelope(type: .blobHas, id: "answer-id", senderId: sender, payload: [0xFF, 0x00])
        #expect(BlobHasLie.rewrite(WireEnvelope(relay: false, sig: [], signed: garbage.encoded), sizes: sizes) == nil, "undecodable")
        #expect(BlobHasLie.rewrite(WireEnvelope(relay: false, sig: [], signed: [0xFF]), sizes: sizes) == nil, "no envelope")
    }
}
