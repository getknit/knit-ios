import KnitStore
import KnitWire
import Testing

/// A carried DM to `bob`, unsigned, as ``CustodyStoreTests`` makes them.
private func carried(
    _ id: String,
    sender: String = "peer",
    recipient: String? = "bob",
    group: String? = nil,
    type: FrameType = .chat,
    payload: [UInt8] = ChatContent().encoded,
    sentAt: Int64 = 1
) -> CarriedFrame {
    let envelope = RelayEnvelope(
        type: type,
        id: id,
        senderId: sender,
        sentAt: sentAt,
        recipientId: recipient,
        group: group.map { GroupInfo(id: $0, members: [sender], createdBy: sender) },
        payload: payload
    )
    return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
}

/// The index a digest answer picks from (``CustodyStore/liveIndex(now:)``, ADR 2026-10.f5zs), run against every store.
@Suite struct CustodyIndexTests {
    private static let kinds = CustodyStoreKind.allCases

    @Test(arguments: kinds)
    func theLiveIndexKeepsLiveFramesOrderAndLeavesExpiredRowsOut(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(ttlMilliseconds: 1000))
        store.store(carried("dead", sentAt: 0), origin: .relayed, now: 1)
        store.store(carried("edge", sentAt: 1), origin: .relayed, now: 2)
        store.store(carried("tie", sentAt: 900), origin: .relayed, now: 7)
        store.store(carried("live", sentAt: 900), origin: .relayed, now: 7)
        store.store(carried("later", sentAt: 900), origin: .relayed, now: 3)
        #expect(store.liveIndex(now: 1001).map(\.id) == store.liveFrames(now: 1001).map(\.envelope.id))
        #expect(store.liveIndex(now: 1001).map(\.id) == ["live", "tie", "later", "edge"])
        #expect(store.liveIndex(now: 2000).isEmpty)
    }

    @Test(arguments: kinds)
    func theLiveIndexReadsEachFieldWithoutDecoding(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        let group = carried("g1", sender: "alice", recipient: nil, group: "grp")
        let profile = carried("p1", sender: "bob", recipient: nil, type: .profile)
        let big = carried("big", payload: Array(repeating: 7, count: 70_000))
        let signed = [
            CarriedFrame(envelope: group.envelope, sig: Array(0..<64), signed: group.signed),
            CarriedFrame(envelope: profile.envelope, sig: Array(repeating: 0xAB, count: 64), signed: profile.signed),
            CarriedFrame(envelope: big.envelope, sig: Array(repeating: 0x01, count: 64), signed: big.signed),
            // An unsigned row, and a signature shorter than the key reads.
            carried("bare"),
            CarriedFrame(envelope: carried("short").envelope, sig: [0x0F, 0xF0], signed: carried("short").signed),
        ]
        for (offset, frame) in signed.enumerated() {
            store.store(frame, origin: .relayed, now: Int64(offset))
        }
        let index = store.liveIndex(now: 10)
        #expect(index.map(\.id) == ["short", "bare", "big", "p1", "g1"])
        for frame in signed {
            let entry = try #require(index.first { $0.id == frame.envelope.id })
            #expect(entry.senderId == frame.envelope.senderId)
            #expect(entry.type == frame.envelope.type)
            #expect(entry.groupId == frame.envelope.group?.id)
            #expect(entry.frameKey == FrameKey.ofSigned(frame.reserved))
            #expect(entry.reservedBytes == frame.reserved.encoded.count, "the bytes LinkManager.send writes")
        }
        #expect(index.first { $0.id == "g1" }?.frameKey == "0001020304050607")
        #expect(index.first { $0.id == "bare" }?.frameKey == nil)
    }

    @Test(arguments: kinds)
    func theLiveIndexListsARowWhoseBytesNoLongerDecode(kind: CustodyStoreKind) throws {
        // As liveIds does, so the round's pick skips it at its load rather than losing sight of what the digest lists.
        let store = try kind.make()
        let good = carried("m1")
        store.store(CarriedFrame(envelope: good.envelope, sig: [1], signed: [0xFF]), origin: .relayed, now: 0)
        #expect(store.liveIndex(now: 0).map(\.id) == ["m1"])
        #expect(
            store.liveIndex(now: 0).first?.reservedBytes
                == CarriedFrame(envelope: good.envelope, sig: [1], signed: [0xFF]).reserved.encoded.count)
    }

    @Test(arguments: [0, 23, 24, 255, 256, 65_535, 65_536])
    func theReserveSizeIsTheEncodedEnvelopesAtEveryHeaderWidth(signed: Int) {
        for sig in [0, 8, 64] {
            let wire = WireEnvelope(sig: Array(repeating: 1, count: sig), signed: Array(repeating: 2, count: signed))
            #expect(CustodyIndexEntry.reservedBytes(sig: sig, signed: signed) == wire.encoded.count)
        }
    }

    @Test func aByteStringPastFourGigabytesTakesCBORsEightByteHeader() {
        // No custody frame comes near this, so it is reckoned from lengths alone, with nothing allocated. RFC 8949: major
        // type 2 with additional info 27 (initial byte 0x5B), then the length in eight bytes. Every major type shares that
        // argument rule, so an unsigned integer of the same value checks the encoder without four gigabytes of string.
        let signed = Int(UInt32.max) + 1
        let eightByteHeader = 1 + 8
        #expect(CBOR.unsigned(UInt64(signed)).encoded.count == eightByteHeader, "the encoder's own shortest argument")
        #expect(CBOR.unsigned(UInt64(signed)).encoded.first.map { $0 & 0x1F } == 27)
        let fourByteHeader = 1 + 4
        let atFourBytes = CustodyIndexEntry.reservedBytes(sig: 64, signed: Int(UInt32.max))
        #expect(CustodyIndexEntry.reservedBytes(sig: 64, signed: signed) == atFourBytes - fourByteHeader + eightByteHeader + 1)
        let mapAndKeys = 1 + (1 + 3) + (1 + 6)
        let sigHeader = 1 + 1
        #expect(CustodyIndexEntry.reservedBytes(sig: 64, signed: signed) == mapAndKeys + sigHeader + 64 + eightByteHeader + signed)
    }
}
