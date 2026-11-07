import Foundation
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's blinded-advert vectors (`keyed-v1.json`'s `blind` section, knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t):
/// the tag's prefix, the advert that carries a tag, the TAG_NEXT record and the HELLO's `t` and `a` fields, all read and
/// none written, since this port never blinds.
@Suite struct BlindVectorTests {
    private let blind = KeyedVectors.file.blind

    private func bytes(_ hex: String) throws -> [UInt8] {
        try #require(Hex.decode(hex), "\(hex) is hex")
    }

    // MARK: The tag's shape

    @Test(arguments: ["tag", "aliceClearId", "prefixOnly", "lastPrefixBitFlipped", "short", "long"])
    func hasPrefixMatchesKnitNext(entry: String) throws {
        let vector = try #require(blind.hasPrefix[entry])
        #expect(AdvertForm.hasTagPrefix(try bytes(vector.bytes)) == vector.hasPrefix)
    }

    @Test func everyPrefixCaseIsCovered() {
        #expect(blind.hasPrefix.count == 6)
    }

    // MARK: The advert

    @Test func theBlindedAdvertParsesToItsFields() throws {
        let vector = blind.advert.blinded
        let serviceData = try bytes(vector.serviceData)
        let advert = try #require(AdvertPayload(serviceData: serviceData))
        #expect(advert.advertised.string == vector.parsed.form)
        #expect(advert.advertised.bytes == (try bytes(vector.tag)))
        #expect(advert.blinded == vector.parsed.blinded)
        #expect(advert.capabilities == vector.parsed.capabilities)
        #expect(advert.digestCue == vector.parsed.digestCue)
        #expect(advert.psm == vector.parsed.psm)
        #expect((advert.flags & AdvertPayload.awareFlag != 0) == vector.parsed.aware)
        #expect(advert.flags == vector.flags)
        #expect(advert.bytes == serviceData, "it round-trips")
        #expect(AdvertPayload(gattValue: serviceData) == nil, "no port serves it over GATT")
    }

    @Test func aBlindedAdvertWithoutTheTagPrefixIsNoAdvert() throws {
        #expect(AdvertPayload(serviceData: try bytes(blind.advert.malformed.serviceData)) == nil)
    }

    @Test func aTagsBytesWithoutTheFlagAreAClearId() throws {
        let serviceData = try bytes(blind.advert.clearWithTagBytes.serviceData)
        let advert = try #require(AdvertPayload(serviceData: serviceData))
        #expect(!advert.blinded)
        #expect(AdvertForm.hasTagPrefix(advert.advertised.bytes), "the bytes are a tag's, and read as an id all the same")
        #expect(AdvertPayload(gattValue: serviceData) == advert)
    }

    // MARK: TAG_NEXT

    @Test func theTagNextRecordReadsAsTagNine() throws {
        var reader = LinkRecordReader()
        reader.append(try bytes(blind.tagNext.record))
        let record = try #require(try reader.next())
        #expect(record.tag == .tagNext && record.tag.rawValue == 9)
        #expect(record.payload == (try bytes(blind.tagNext.tag)))
        #expect(!reader.hasPartialRecord)
    }

    /// A short TAG_NEXT throws, which the link session turns into a dropped link (`LinkAdmissionTests`).
    @Test func aTagNextOfTheWrongLengthEndsTheLink() throws {
        var reader = LinkRecordReader()
        reader.append(try bytes(blind.tagNext.wrongLength.record))
        #expect(throws: LinkRecordError.badLength(tag: 9, length: 15)) {
            try reader.next()
        }
    }

    // MARK: The HELLO's forms

    @Test(arguments: [
        "both", "reversed", "unknownFieldSkipped", "duplicateTold", "duplicateAddressed", "sameToldTwice", "malformedSecondTold",
        "upperHex", "shortTold", "longTold", "noNonce", "shortNonce", "nonceNotThird",
    ])
    func helloFieldsMatchKnitNext(entry: String) throws {
        let vector = try #require(blind.helloFields[entry])
        let hello = Hello(payload: Array(vector.payload.utf8))
        #expect((hello.nonce != nil) == vector.nonce)
        #expect(hello.told.map(Hex.encode) == vector.told)
        #expect(hello.addressed.map(Hex.encode) == vector.addressed)
    }

    @Test func everyHelloFieldsCaseIsCovered() {
        #expect(blind.helloFields.count == 13)
    }

    /// The tagged link's HELLOs parse to their forms, and the record's bytes are the payload as it crossed.
    @Test(arguments: ["helloTaggedDialer", "helloTaggedReply"])
    func theTaggedLinksHellosParse(entry: String) throws {
        let vector = entry == "helloTaggedDialer" ? blind.link.helloTaggedDialer : blind.link.helloTaggedReply
        let payload = Array(vector.payload.utf8)
        let hello = Hello(payload: payload)
        #expect(hello.capabilities == Capabilities(rawValue: 0xC0009))
        let told = try #require(hello.told)
        #expect(AdvertForm.hasTagPrefix(told))
        #expect((hello.addressed != nil) == (entry == "helloTaggedDialer"), "only a dialer says what it dialed")
        #expect(Hex.encode(try #require(LinkRecord(.hello, payload: payload).encoded)) == vector.record)
    }

    /// This port, rebuilding the dialer's HELLO from its fields, writes the same bytes less the `t` it never writes.
    @Test func aDialersHelloRebuiltWritesItsAddressedFormAndNoTold() throws {
        let vector = blind.link.helloTaggedDialer
        let parsed = Hello(payload: Array(vector.payload.utf8))
        let told = try #require(parsed.told)
        let nonce = try #require(parsed.nonce)
        let ours = Hello(nodeId: parsed.nodeId, capabilities: parsed.capabilities, nonce: nonce, addressed: parsed.addressed)
        let withoutTold = vector.payload.replacingOccurrences(of: "|t" + Hex.encode(told), with: "")
        #expect(withoutTold != vector.payload, "the vector carried a told form")
        #expect(ours.payload == Array(withoutTold.utf8))
        #expect(Hello(payload: ours.payload).told == nil)
        #expect(Hello(payload: ours.payload).addressed == parsed.addressed)
    }

    // MARK: KnitCrypto's half (`tags`, `slotOf`, `window`, the tagged link's transcripts and proofs) needs KnitCrypto, so it
    // reads ``VectorBlind`` from KnitCryptoTests.
}
