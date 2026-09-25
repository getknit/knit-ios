import KnitTestSupport
import KnitWire
import Testing

/// knit-next's link vectors (`keyed-v1.json`): the HELLO and DIGEST records, the custody fingerprint and the
/// advert, which a peer reads before any frame.
@Suite struct LinkVectorTests {
    private let link = KeyedVectors.file.link

    @Test func theHelloRecordMatchesKnitNext() throws {
        let hello = Hello(payload: Array(link.hello.payload.utf8))
        #expect(hello.version == WireProtocol.version)
        #expect(hello.capabilities == .local)
        let ours = Hello(nodeId: hello.nodeId)
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
