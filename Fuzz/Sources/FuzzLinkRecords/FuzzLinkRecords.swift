import KnitWire

/// Arbitrary bytes as a link's byte stream, delivered in chunks the input chooses, then every record parsed
/// the way a link session will: HELLO, digest and file-header JSON, frames down to their payloads, and the FILE
/// records through a ``FileIntake``, as the link manager feeds them (ADR 2026-10.nh55). A KEEPALIVE stands for the link
/// being cut: the file being kept goes to a memory of kept prefixes, the next link gets a fresh intake, and a resumed
/// header reads its prefix back from that memory (knit-ios #2).
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzLinkRecords(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    guard let chunkSeed = bytes.first else {
        return 0
    }
    let chunkSize = Int(chunkSeed % maxChunkBytes) + 1
    var reader = LinkRecordReader()
    var session = FuzzLinkRecords()
    var offset = 1
    while offset < bytes.count {
        reader.append(bytes[offset..<min(offset + chunkSize, bytes.count)])
        offset += chunkSize
        do {
            while let record = try reader.next() {
                parse(record, into: &session)
            }
        } catch {
            return 0
        }
    }
    return 0
}

/// The largest chunk the first input byte can choose; radios deliver anything from one byte to an MTU.
private let maxChunkBytes: UInt8 = 64

/// The most of one file the harness keeps, small so a file passing it is reached often. The key's first character
/// says whether the file is kept at all, as the engine's want set says on a link.
private let fuzzFileLimit = 4096

/// The room every partial file shares, as the link manager's budget across links.
private let fuzzRoom = 8192

/// The clock's step per record, so the resume window both holds and lapses within one input.
private let recordMilliseconds: Int64 = 1000

/// One input's links, one after another, and what their cuts kept: the longest copy of each key, as the store keeps it.
private struct FuzzLinkRecords {
    var intake = FileIntake()
    var kept: [BlobHash: [UInt8]] = [:]
    var now: Int64 = 0
}

private func parse(_ record: LinkRecord, into session: inout FuzzLinkRecords) {
    session.now += recordMilliseconds
    switch record.tag {
    case .hello:
        _ = Hello(payload: record.payload)
    case .digest:
        _ = LinkJSON.digestIds(from: record.payload)
    case .fileHeader:
        let kept = session.kept
        _ = session.intake.header(
            record.payload,
            room: fuzzRoom,
            limit: { header, key in
                header.kind == .avatar || key.string.utf8.first.map { $0 < UInt8(ascii: "8") } == true ? fuzzFileLimit : nil
            },
            prefix: { key, count in kept[key].flatMap { $0.count >= count ? (Array($0.prefix(count)), 0) : nil } },
            now: session.now
        )
    case .fileChunk:
        _ = session.intake.chunk(record.payload, room: fuzzRoom)
    case .fileEnd:
        _ = session.intake.end()
    case .frame:
        guard let wire = try? WireEnvelope(decoding: record.payload), let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            return
        }
        _ = FrameKey.of(wire, envelope)
        _ = try? ChatContent(decoding: envelope.payload)
        _ = try? ProfileContent(decoding: envelope.payload)
        _ = try? ReceiptContent(decoding: envelope.payload)
        _ = try? BlobRequestContent(decoding: envelope.payload)
    case .keepalive:
        if let cut = session.intake.cut(), cut.bytes.count > session.kept[cut.key]?.count ?? 0 {
            session.kept[cut.key] = cut.bytes
        }
        session.intake = FileIntake()
    }
}
