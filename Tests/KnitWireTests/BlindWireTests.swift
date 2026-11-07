import KnitWire
import Testing

/// What a blinding Android puts on the air, read here and never written (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t):
/// tag 9, the advert's bit 3 and the HELLO's forms, ported from knit-next's `LinkFramingTest`, `ProtocolTest` and
/// `BleAdvertPayloadTest` at `cad69c77b`. `BlindVectorTests` replays the shared vectors.
@Suite struct BlindWireTests {
    private let nodeA = "ffbbh6thbepahqxsv2gqog45m4"

    @Test func theBlindAdvertBitIsPinnedAndOurs() {
        // `Protocol.CAP_BLIND_ADVERT` (knit-next ADR 2026-11.xp6d, ADR 2026-11.sv5t): "I read tags", in the HELLO and in
        // every profile we sign, the switch on or off, so Android sends `TAG_NEXT` and ctl 11; above the advert's 8 bits.
        #expect(Capabilities.blindAdvert.rawValue == 0x80000)
        #expect(Capabilities.local.contains(.blindAdvert))
        #expect(Capabilities.local.subtracting(.ratchetSuite).contains(.blindAdvert))
        #expect(Capabilities.blindAdvert.rawValue & 0xFF == 0)
        #expect(Hello(nodeId: nodeA).capabilities.contains(.blindAdvert))
    }

    /// Tag 9 carries exactly 16 bytes (`LinkFramingTest.aTagNextRecordRoundTripsUnderTagNine`).
    @Test func aTagNextRecordReadsUnderTagNine() throws {
        let tag = (0..<UInt8(LinkRecord.tagNextBytes)).map { 0xC0 + $0 }
        let encoded = try #require(LinkRecord(.tagNext, payload: tag).encoded)
        #expect(encoded.first == 0x09)
        var reader = LinkRecordReader()
        reader.append(encoded)
        #expect(try reader.next() == LinkRecord(.tagNext, payload: tag))
    }

    /// Any other length is a framing error, thrown from the header before its payload has come
    /// (`LinkFramingTest.aTagNextOfAnyOtherLengthIsAFramingErrorNeverARecord`).
    @Test func aTagNextOfAnyOtherLengthEndsTheLink() {
        for length: UInt32 in [0, 15, 17, 1024] {
            var reader = LinkRecordReader()
            reader.append([0x09] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            #expect(throws: LinkRecordError.badLength(tag: 9, length: length), "length \(length)") {
                try reader.next()
            }
        }
    }

    /// Bit 3 says bytes 1–16 are a tag (knit-next ADR 2026-11.xp6d): over a tag's prefix the advert parses blinded and
    /// round-trips, over anything else it is no advert at all, and without the bit a prefix is an id like any other
    /// (`BleAdvertPayload.kt:175-197` at `cad69c77b`).
    @Test func theBlindedBitNeedsATagUnderIt() throws {
        let tag = try #require(NodeId(bytes: [0xCE, 0x73, 0x96] + [UInt8](repeating: 0x5A, count: 13)))
        let id = try #require(NodeId(nodeA))
        let blinded = AdvertPayload(capabilities: 0x9, nodeId: tag, digestCue: 0, psm: 0x83, flags: AdvertPayload.blindedFlag)
        let parsed = try #require(AdvertPayload(serviceData: blinded.bytes))
        #expect(parsed.blinded && parsed.advertised == tag)
        #expect(parsed.bytes == blinded.bytes)
        let malformed = AdvertPayload(capabilities: 0x9, nodeId: id, digestCue: 0, psm: 0x83, flags: AdvertPayload.blindedFlag)
        #expect(AdvertPayload(serviceData: malformed.bytes) == nil, "a blinded id is dropped")
        #expect(AdvertPayload(serviceData: malformed.bytes + [0xAA]) == nil, "whatever follows the flags")
        let clear = AdvertPayload(capabilities: 0x9, nodeId: tag, digestCue: 0, psm: 0x83, flags: AdvertPayload.dialsGattPeersFlag)
        #expect(AdvertPayload(serviceData: clear.bytes)?.blinded == false, "a tag's prefix without the bit is an id")
        #expect(AdvertPayload(serviceData: Array(malformed.bytes.prefix(AdvertPayload.minimumSize)))?.blinded == false)
    }

    /// A GATT value is what the service data parse reads, less a blinded one: no port serves a tag
    /// (`BleGattPayloadReader.kt:87-89` at `cad69c77b`), so a radio treats it as a stranger.
    @Test func aGATTValueIsNeverBlinded() throws {
        let tag = try #require(NodeId(bytes: [0xCE, 0x73, 0x96] + [UInt8](repeating: 0x5A, count: 13)))
        let id = try #require(NodeId(nodeA))
        let honest = AdvertPayload(capabilities: 0x9, nodeId: id, digestCue: 0, psm: 0x83, flags: AdvertPayload.dialsGattPeersFlag)
        #expect(AdvertPayload(gattValue: honest.gattValue) == honest)
        #expect(AdvertPayload(gattValue: Array(honest.gattValue.prefix(AdvertPayload.minimumSize)))?.advertised == id)
        let blinded = AdvertPayload(capabilities: 0x9, nodeId: tag, digestCue: 0, psm: 0x83, flags: AdvertPayload.blindedFlag)
        #expect(AdvertPayload(serviceData: blinded.gattValue) != nil, "as service data it reads")
        #expect(AdvertPayload(gattValue: blinded.gattValue) == nil, "over GATT it does not")
        #expect(AdvertPayload(gattValue: Array(honest.gattValue.prefix(AdvertPayload.minimumSize - 1))) == nil, "short")
        #expect(AdvertPayload(gattValue: []) == nil)
    }

    /// The addressed form rides after the nonce, and only with one (`Protocol.hello`, `Protocol.kt:266-279`); no HELLO this
    /// port writes tells a form of its own.
    @Test func aHelloWritesTheFormItDialedAfterItsNonce() {
        let nonce = Array(UInt8(0)..<16)
        let form = Array(UInt8(0xC0)..<0xD0)
        let hello = Hello(nodeId: nodeA, capabilities: 0x40009, nonce: nonce, addressed: form)
        let text = "\(nodeA)|1|40009|n000102030405060708090a0b0c0d0e0f|ac0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
        #expect(hello.payload == Array(text.utf8))
        #expect(Hello(payload: hello.payload) == hello, "it parses back")
        #expect(Hello(payload: hello.payload).told == nil)
        #expect(Hello(nodeId: nodeA, capabilities: 0x9, addressed: form).payload == Array("\(nodeA)|1|9".utf8), "no nonce, no form")
    }

    /// A `|` followed by a combining mark still separates fields, as Kotlin's `split('|')` does on the UTF-16 unit.
    @Test func aCombiningMarkAfterTheSeparatorStillSplits() {
        let digits = "000102030405060708090a0b0c0d0e0f"
        let parsed = Hello(payload: Array("\(nodeA)|1|4215f|n\(digits)|\u{301}t\(digits)".utf8))
        #expect(parsed.nonce == Array(UInt8(0)..<16))
        #expect(parsed.told == nil, "the mark is the field's, so it is no form")
    }
}
