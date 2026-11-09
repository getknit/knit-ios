import KnitWire
import Testing

/// The seal's bytes on the wire (the `link-seal` contract, §1 and §3): the advert's flag, and the two records' lengths.
@Suite struct LinkSealWireTests {
    private let nodeA = "ffbbh6thbepahqxsv2gqog45m4"

    /// `FLAG_LINK_SEAL` is bit 4 of byte 23 (the `link-seal` contract, §1): written exactly when asked, round-tripped in the
    /// service data and the GATT value, and absent from a 23-byte advert, which has no flags byte.
    @Test func theLinkSealFlagIsBitFourAndRoundTrips() throws {
        #expect(AdvertPayload.linkSealFlag == 0x10)
        #expect(AdvertPayload.writtenFlags(dialsGattPeers: false, blinded: false, seals: true) == AdvertPayload.linkSealFlag)
        #expect(AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: false, seals: true) == 0x12)
        let node = try #require(NodeId(nodeA))
        let flags = AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: false, seals: true)
        let payload = AdvertPayload(capabilities: .local, nodeId: node, digestCue: 9, psm: 0x80, flags: flags)
        let parsed = try #require(AdvertPayload(serviceData: payload.bytes))
        #expect(parsed.seals)
        #expect(!parsed.blinded)
        #expect(try #require(AdvertPayload(gattValue: payload.gattValue)).seals, "an iPhone's flag reaches Android through its GATT value")
        let short = try #require(AdvertPayload(serviceData: Array(payload.bytes.prefix(AdvertPayload.minimumSize))))
        #expect(!short.seals, "23 bytes read the flag as clear")
        #expect(
            try !#require(AdvertPayload(serviceData: AdvertPayload(capabilities: .local, nodeId: node, digestCue: 0, psm: 1).bytes)).seals)
    }

    @Test func bothRecordsRoundTripThroughTheReader() throws {
        let records = [
            LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: LinkRecord.keyShareBytes)),
            LinkRecord(.sealed, payload: [UInt8](repeating: 0x11, count: 17)),
            LinkRecord(.sealed, payload: [UInt8](repeating: 0x11, count: 65_552)),
        ]
        var reader = LinkRecordReader()
        reader.append(records.flatMap { $0.encoded ?? [] })
        var read: [LinkRecord] = []
        while let record = try reader.next() {
            read.append(record)
        }
        #expect(read == records)
    }

    /// A KEY_SHARE is exactly 32 bytes and a SEALED frame 17 to 65,552, each read from the header before the payload is
    /// waited for, as `TAG_NEXT`'s one length is (the `link-seal` contract, §3).
    @Test func aKeyShareOrAFrameOfAnotherLengthEndsTheLinkFromItsHeader() {
        for (tag, length) in [(UInt8(10), UInt32(31)), (10, 33), (10, 0), (11, 16), (11, 0), (11, 65_553)] {
            var reader = LinkRecordReader()
            let header = [tag] + (0..<4).map { UInt8(truncatingIfNeeded: length >> UInt32(8 * (3 - $0))) }
            reader.append(header)
            #expect(throws: LinkRecordError.badLength(tag: tag, length: length), "tag \(tag) length \(length)") {
                try reader.next()
            }
        }
    }
}
