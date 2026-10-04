import Foundation
import KnitWire
import Testing

/// Link records, the HELLO, the digest and the advert, ported from knit-next's `LinkFramingTest`,
/// `ProtocolTest` and `BleAdvertPayloadTest`, with the byte layouts pinned as hex.
@Suite struct LinkTests {
    private let nodeA = "ffbbh6thbepahqxsv2gqog45m4"

    @Test func everyTagRoundTripsThroughTheReader() throws {
        let records: [LinkRecord] = [
            LinkRecord(.frame, payload: [1, 2, 3]),
            LinkRecord(.fileHeader, payload: Array("hdr".utf8)),
            LinkRecord(.fileChunk, payload: [UInt8](repeating: 7, count: 16 * 1024)),
            LinkRecord(.fileEnd),
            LinkRecord(.keepalive),
            LinkRecord(.hello, payload: Hello(nodeId: nodeA).payload),
            LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ["x", "y"])),
        ]
        var reader = LinkRecordReader()
        reader.append(records.flatMap { $0.encoded ?? [] })
        var read: [LinkRecord] = []
        while let record = try reader.next() {
            read.append(record)
        }
        #expect(read == records)
        #expect(!reader.hasPartialRecord)
    }

    @Test func recordsSurviveAnyChunking() throws {
        let stream = (LinkRecord(.frame, payload: Array(0..<200)).encoded ?? []) + (LinkRecord(.fileEnd).encoded ?? [])
        for chunkSize in [1, 2, 3, 5, 7, 64, 205] {
            var reader = LinkRecordReader()
            var read: [LinkRecord] = []
            var offset = 0
            while offset < stream.count {
                reader.append(stream[offset..<min(offset + chunkSize, stream.count)])
                offset += chunkSize
                while let record = try reader.next() {
                    read.append(record)
                }
            }
            #expect(read == [LinkRecord(.frame, payload: Array(0..<200)), LinkRecord(.fileEnd)], "chunk size \(chunkSize)")
        }
    }

    @Test func aPartialRecordWaitsAndIsVisibleAtEndOfStream() throws {
        var reader = LinkRecordReader()
        let full = LinkRecord(.frame, payload: [1, 2, 3, 4]).encoded ?? []
        reader.append(full.dropLast())
        #expect(try reader.next() == nil)
        #expect(reader.hasPartialRecord)
    }

    @Test func anUnknownTagEndsTheLinkAsAndroidDoes() {
        var reader = LinkRecordReader()
        reader.append([0x08, 0, 0, 0, 0])
        #expect(throws: LinkRecordError.unknownTag(8)) {
            try reader.next()
        }
        var zero = LinkRecordReader()
        zero.append([0x00, 0, 0, 0, 0])
        #expect(throws: LinkRecordError.unknownTag(0)) {
            try zero.next()
        }
    }

    @Test func theReaderSaysWhereTheNextRecordStarts() throws {
        var reader = LinkRecordReader()
        let first = try #require(LinkRecord(.keepalive).encoded)
        let second = try #require(LinkRecord(.digest, payload: [1, 2, 3]).encoded)
        reader.append(first + second + [0x57, 0x36])
        #expect(reader.consumed == 0)
        #expect(reader.upcoming(2) == [0x05, 0x00])
        _ = try reader.next()
        _ = try reader.next()
        #expect(reader.consumed == first.count + second.count)
        #expect(reader.upcoming(32) == [0x57, 0x36], "no more than is buffered")
        reader.append([0, 0, 0])
        #expect(throws: LinkRecordError.unknownTag(0x57)) {
            try reader.next()
        }
        #expect(reader.consumed == first.count + second.count, "a bad record is not consumed")
    }

    @Test func aLengthPastTheCapEndsTheLink() {
        var reader = LinkRecordReader()
        reader.append([0x01, 0x00, 0x08, 0x00, 0x01])
        #expect(throws: LinkRecordError.lengthOutOfRange(524_289)) {
            try reader.next()
        }
        var negative = LinkRecordReader()
        negative.append([0x01, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: LinkRecordError.lengthOutOfRange(.max)) {
            try negative.next()
        }
    }

    @Test func anOversizePayloadCannotBeEncoded() {
        #expect(LinkRecord(.fileChunk, payload: [UInt8](repeating: 0, count: LinkRecord.maxPayloadBytes + 1)).encoded == nil)
        #expect(LinkRecord(.fileChunk, payload: [UInt8](repeating: 0, count: LinkRecord.maxPayloadBytes)).encoded != nil)
    }

    @Test func recordBytesArePinned() {
        #expect(LinkRecord(.fileEnd).encoded.map(Hex.encode) == "0400000000")
        #expect(LinkRecord(.keepalive).encoded.map(Hex.encode) == "0500000000")
        let hello = LinkRecord(.hello, payload: Hello(nodeId: nodeA, capabilities: Capabilities(rawValue: 0xFFF)).payload)
        #expect(
            hello.encoded.map(Hex.encode) == "060000002066666262683674686265706168717873763267716f6734356d347c317c666666"
        )
        let digest = LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ["a", "b"]))
        #expect(digest.encoded.map(Hex.encode) == "07000000117b22696473223a5b2261222c2262225d7d")
    }

    @Test func helloCarriesOurCapabilitiesAsLowercaseHex() {
        #expect(Hello(nodeId: nodeA).payload == Array("\(nodeA)|1|b".utf8))
        #expect(Capabilities.local.hex == "b", "end-to-end, groups and store-and-forward (ADR 2026-09.n393)")
        #expect(Capabilities(rawValue: 0xFFF).hex == "fff")
    }

    @Test func theDoorbellBitIsPinnedAndNeverOurs() {
        // `Protocol.CAP_DOORBELL`: the radio adds it to the HELLO, and this build never advertises it anywhere else.
        #expect(Capabilities.doorbell.rawValue == 0x1000)
        #expect(!Capabilities.local.contains(.doorbell))
        #expect(Capabilities.local.union(.doorbell).hex == "100b")
        #expect(Hello(payload: Array("\(nodeA)|1|100b".utf8)).capabilities == [.endToEnd, .groups, .storeForward, .doorbell])
        #expect(
            Hello(payload: Array("\(nodeA)|1|1009".utf8)).capabilities == [.endToEnd, .storeForward, .doorbell],
            "a build from before groups")
    }

    @Test func helloParsesTheWayAndroidDoes() {
        let parsed = Hello(payload: Array("\(nodeA)|1|fff".utf8))
        #expect(parsed == Hello(nodeId: nodeA, version: 1, capabilities: Capabilities(rawValue: 0xFFF)))
        // A missing or unreadable field reads as 0, and extra fields are ignored.
        #expect(Hello(payload: Array("abcd1234".utf8)) == Hello(nodeId: "abcd1234", version: 0, capabilities: []))
        #expect(Hello(payload: Array("abcd1234|notanint|zzz".utf8)) == Hello(nodeId: "abcd1234", version: 0, capabilities: []))
        #expect(Hello(payload: Array("abcd1234|1|f|future|stuff".utf8)).nodeId == "abcd1234")
        #expect(Hello(payload: []).nodeId.isEmpty)
    }

    @Test func digestJSONRoundTripsAndRejectsGarbage() {
        #expect(LinkJSON.digestIds(from: LinkJSON.digestPayload(ids: ["x", "y"])) == ["x", "y"])
        #expect(LinkJSON.digestIds(from: LinkJSON.digestPayload(ids: []))?.isEmpty == true)
        #expect(LinkJSON.digestIds(from: Array("not json".utf8)) == nil)
        #expect(LinkJSON.digestIds(from: Array(#"{"ids":[1]}"#.utf8)) == nil)
        #expect(LinkJSON.digestIds(from: Array(#"{"ids":["a"],"extra":true}"#.utf8)) == ["a"])
        let awkward = "q\"uo\\te\n\u{1}"
        #expect(LinkJSON.digestIds(from: LinkJSON.digestPayload(ids: [awkward])) == [awkward])
    }

    @Test func fileHeadersParseAndGarbageIsRejected() {
        let header = Array(#"{"later":1,"mime":"image/jpeg","key":"00ff","kind":"AVATAR"}"#.utf8)
        #expect(LinkJSON.fileHeader(from: header) == FileHeader(kind: .avatar, key: "00ff", mime: "image/jpeg"))
        #expect(LinkJSON.fileHeader(from: Array(#"{"kind":"AVATAR"}"#.utf8)) == nil)
        #expect(LinkJSON.fileHeader(from: Array(#"{"kind":"AVATAR","key":1,"mime":"x"}"#.utf8)) == nil)
        #expect(LinkJSON.fileHeader(from: Array("not json".utf8)) == nil)
    }

    /// `FileKind`'s tokens are frozen (`FramedLinkTest.fileKindWireTokensAreFrozen`), and any other token, a
    /// lowercase one included, is an attachment (`entries.firstOrNull { it.wire == token } ?: ATTACHMENT`).
    @Test func fileKindsReadAsAndroidReadsThem() {
        #expect(FileHeader.Kind.avatar.rawValue == "AVATAR")
        #expect(FileHeader.Kind.attachment.rawValue == "ATTACHMENT")
        #expect(FileHeader.Kind(wire: "AVATAR") == .avatar)
        #expect(FileHeader.Kind(wire: "ATTACHMENT") == .attachment)
        #expect(FileHeader.Kind(wire: "avatar") == .attachment)
        #expect(FileHeader.Kind(wire: "VOICE") == .attachment)
        #expect(FileHeader.Kind(wire: "") == .attachment)
    }

    /// kotlinx writes `FileHeaderWire` compact, in declaration order (`LinkFraming.encodeFileHeader`). knit-next's
    /// vector pins an ATTACHMENT with its size (`LinkVectorTests`); these pin the three-key shape a build before the
    /// size wrote, and an AVATAR, by its `Json` settings and escape table until companion change A7 shares the rest.
    @Test func fileHeaderBytesArePinned() throws {
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let attachment = LinkRecord(
            .fileHeader, payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: empty, mime: "image/jpeg")))
        #expect(String(bytes: attachment.payload, encoding: .utf8) == #"{"kind":"ATTACHMENT","key":"\#(empty)","mime":"image/jpeg"}"#)
        #expect(attachment.payload.count == 114)
        #expect(attachment.encoded.map { Hex.encode(Array($0.prefix(5))) } == "0200000072")
        let avatar = LinkJSON.fileHeaderPayload(FileHeader(kind: .avatar, key: empty, mime: "image/jpeg"))
        #expect(String(bytes: avatar, encoding: .utf8) == #"{"kind":"AVATAR","key":"\#(empty)","mime":"image/jpeg"}"#)
        let roundTrip = try #require(LinkJSON.fileHeader(from: avatar))
        #expect(roundTrip == FileHeader(kind: .avatar, key: empty, mime: "image/jpeg"))
    }

    /// The size follows the mime, as a bare integer (`FileHeaderWire.size`, knit-next ADR 2026-10.y9qh).
    @Test func aFileHeaderCarriesTheStreamsSize() {
        let header = FileHeader(kind: .avatar, key: "k", mime: "image/jpeg", size: 203_807)
        let payload = LinkJSON.fileHeaderPayload(header)
        #expect(String(bytes: payload, encoding: .utf8) == #"{"kind":"AVATAR","key":"k","mime":"image/jpeg","size":203807}"#)
        #expect(LinkJSON.fileHeader(from: payload) == header)
        let zero = LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: "k", mime: "x", size: 0))
        #expect(String(bytes: zero, encoding: .utf8) == #"{"kind":"ATTACHMENT","key":"k","mime":"x","size":0}"#)
    }

    /// A failed header drops the file behind it, so a size that will not decode costs the label and never the file
    /// (`LinkFramingTest.aSizeThatWillNotDecodeCostsTheLabelNotTheFile`). The fields the receiver routes on still do.
    @Test func aSizeThatWillNotDecodeCostsTheLabelNotTheFile() {
        for bad in [#""big""#, "1.5", "99999999999999999999", "{}", "[1]", "null"] {
            let json = #"{"kind":"ATTACHMENT","key":"k","mime":"image/jpeg","size":\#(bad)}"#
            #expect(LinkJSON.fileHeader(from: Array(json.utf8)) == FileHeader(kind: .attachment, key: "k", mime: "image/jpeg"), "\(bad)")
        }
        #expect(LinkJSON.fileHeader(from: Array(#"{"kind":"ATTACHMENT","key":"k","size":10}"#.utf8)) == nil)
    }

    /// kotlinx's `ESCAPE_STRINGS`: the quote, the backslash, five short forms, and `\u00xx` in lowercase for the rest of
    /// the control characters. Everything else, `/` and non-ASCII included, is written as it is.
    @Test func jsonStringsAreEscapedAsKotlinxEscapesThem() {
        let awkward = "q\"b\\s\n\r\t\u{8}\u{C}\u{1}\u{1F}/é"
        let payload = LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: "k", mime: awkward))
        #expect(String(bytes: payload, encoding: .utf8) == #"{"kind":"ATTACHMENT","key":"k","mime":"q\"b\\s\n\r\t\b\f\u0001\u001f/é"}"#)
        #expect(LinkJSON.fileHeader(from: payload)?.mime == awkward)
        #expect(LinkJSON.digestIds(from: LinkJSON.digestPayload(ids: [awkward])) == [awkward])
    }

    @Test func advertBytesArePinned() throws {
        let node = try #require(NodeId(nodeA))
        let payload = AdvertPayload(capabilities: Capabilities(rawValue: 0xFFF), nodeId: node, digestCue: 0, psm: 0x0081)
        #expect(Hex.encode(payload.bytes) == "ff294213fa67091e03c2f2ae8d071b9d6700000000008100")
        #expect(payload.bytes.count == AdvertPayload.size)
        #expect(AdvertPayload(serviceData: payload.bytes) == payload)
    }

    @Test func advertParsesLikeAndroid() throws {
        let node = try #require(NodeId(nodeA))
        let full = AdvertPayload(capabilities: Capabilities(rawValue: 0x1), nodeId: node, digestCue: 7, psm: 200).bytes
        // A 23-byte advert predates the flags byte: same fields, flags 0.
        let older = try #require(AdvertPayload(serviceData: Array(full.prefix(AdvertPayload.minimumSize))))
        #expect(older.nodeId == node)
        #expect(older.flags == 0)
        // Bytes past 24 are ignored.
        let forward = try #require(AdvertPayload(serviceData: full + [0xAA, 0xBB]))
        #expect(forward.digestCue == 7)
        #expect(forward.psm == 200)
        // Shorter than 23 is not a Knit advert.
        #expect(AdvertPayload(serviceData: []) == nil)
        #expect(AdvertPayload(serviceData: [UInt8](repeating: 0, count: 22)) == nil)
    }

    @Test func advertKeepsTheLowCapabilityByteAndTheDigestCuesLowBits() throws {
        let node = try #require(NodeId(nodeA))
        let payload = AdvertPayload(capabilities: Capabilities(rawValue: 0xFFF), nodeId: node, digestCue: 0x9ABC_DEF0, psm: 1)
        let parsed = try #require(AdvertPayload(serviceData: payload.bytes))
        #expect(parsed.capabilities == 0xFF)
        #expect(parsed.digestCue == 0x9ABC_DEF0)
        let flagged = AdvertPayload(capabilities: [], nodeId: node, digestCue: 0, psm: 1, flags: AdvertPayload.dialsGattPeersFlag)
        #expect(AdvertPayload(serviceData: flagged.bytes)?.flags == AdvertPayload.dialsGattPeersFlag)
    }

    @Test func theGATTValueIsThePayloadWithItsCueZeroed() throws {
        let node = try #require(NodeId(nodeA))
        let payload = AdvertPayload(capabilities: Capabilities(rawValue: 0x9), nodeId: node, digestCue: 0x1234_5678, psm: 0x80, flags: 2)
        #expect(Hex.encode(payload.gattValue) == "09294213fa67091e03c2f2ae8d071b9d6700000000008002")
        #expect(AdvertPayload(serviceData: payload.gattValue)?.psm == 0x80)
    }

    @Test func theGATTIdentifiersArePinned() {
        #expect(AdvertPayload.serviceUUID == "0000fe30-0000-1000-8000-00805f9b34fb")
        #expect(AdvertPayload.characteristicUUID == "848eedcd-a2e3-4fb2-86f9-e2c80821a497")
        #expect(AdvertPayload.doorbellUUID == "f34c056b-5830-4243-a888-01f92f49e446")
    }
}
