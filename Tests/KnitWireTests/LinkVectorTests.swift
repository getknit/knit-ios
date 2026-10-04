import KnitTestSupport
import KnitWire
import Testing

/// knit-next's link vectors (`keyed-v1.json`): the HELLO, DIGEST and FILE_HEADER records, the custody fingerprint
/// and the advert, which a peer reads before any frame.
@Suite struct LinkVectorTests {
    private let link = KeyedVectors.file.link

    @Test func theHelloRecordMatchesKnitNext() throws {
        let hello = Hello(payload: Array(link.hello.payload.utf8))
        #expect(hello.version == WireProtocol.version)
        // The vector keeps the capabilities this port had when it was made (`KeyedVectorTest.CAPABILITIES`), which
        // groups moved on from (ADR 2026-09.n393), so its bytes never move.
        #expect(hello.capabilities == Capabilities(rawValue: 0x9))
        let ours = Hello(nodeId: hello.nodeId, capabilities: hello.capabilities)
        #expect(ours.payload == Array(link.hello.payload.utf8))
        let record = try #require(LinkRecord(.hello, payload: ours.payload).encoded)
        #expect(Hex.encode(record) == link.hello.record)
    }

    /// The digest is JSON from kotlinx's encoder; ours must write the same bytes, not just equivalent JSON.
    @Test func theDigestRecordMatchesKotlinxByteForByte() throws {
        let payload = LinkJSON.digestPayload(ids: link.digest.ids)
        let record = try #require(LinkRecord(.digest, payload: payload).encoded)
        #expect(Hex.encode(record) == link.digest.record)
        #expect(LinkJSON.digestIds(from: payload) == link.digest.ids)
    }

    /// The header is JSON too, and carries the stream's size so the receiver can draw how far it has got (knit-next
    /// ADR 2026-10.y9qh).
    @Test func theFileHeaderRecordMatchesKotlinxByteForByte() throws {
        let vector = link.fileHeader
        let header = FileHeader(kind: FileHeader.Kind(wire: vector.kind), key: vector.key, mime: vector.mime, size: vector.size)
        #expect(header.kind == .attachment)
        let payload = LinkJSON.fileHeaderPayload(header)
        let record = try #require(LinkRecord(.fileHeader, payload: payload).encoded)
        #expect(Hex.encode(record) == vector.record)
        #expect(LinkJSON.fileHeader(from: payload) == header)
    }

    @Test func theFingerprintMatchesKnitNext() {
        let fold = StoreDigest.fingerprint(of: link.digestFold.ids)
        let digits = String(fold, radix: 16)
        #expect(String(repeating: "0", count: 16 - digits.count) + digits == link.digestFold.fold)
        #expect(UInt32(truncatingIfNeeded: fold) == link.advert.digestCue)
    }

    @Test func theAdvertMatchesKnitNextAndParsesBack() throws {
        let advert = AdvertPayload(
            capabilities: Capabilities(rawValue: link.advert.capabilities),
            nodeId: try #require(NodeId(link.advert.nodeId)),
            digestCue: link.advert.digestCue,
            psm: link.advert.psm,
            flags: link.advert.flags
        )
        #expect(Hex.encode(advert.bytes) == link.advert.serviceData)
        #expect(AdvertPayload(serviceData: advert.bytes) == advert)
    }
}
