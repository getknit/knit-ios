import KnitWire

/// Arbitrary bytes as a link's byte stream, delivered in chunks the input chooses, then every record parsed
/// the way a link session will: HELLO, digest and file-header JSON, frames down to their payloads, and the FILE
/// records through a ``FileIntake``, as the link manager feeds them (ADR 2026-10.nh55).
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzLinkRecords(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    guard let chunkSeed = bytes.first else {
        return 0
    }
    let chunkSize = Int(chunkSeed % maxChunkBytes) + 1
    var reader = LinkRecordReader()
    var intake = FileIntake()
    var offset = 1
    while offset < bytes.count {
        reader.append(bytes[offset..<min(offset + chunkSize, bytes.count)])
        offset += chunkSize
        do {
            while let record = try reader.next() {
                parse(record, into: &intake)
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

private func parse(_ record: LinkRecord, into intake: inout FileIntake) {
    switch record.tag {
    case .hello:
        _ = Hello(payload: record.payload)
    case .digest:
        _ = LinkJSON.digestIds(from: record.payload)
    case .fileHeader:
        _ = intake.header(record.payload) { header, key in
            header.kind == .avatar || key.string.utf8.first.map { $0 < UInt8(ascii: "8") } == true ? fuzzFileLimit : nil
        }
    case .fileChunk:
        _ = intake.chunk(record.payload, room: fuzzRoom)
    case .fileEnd:
        _ = intake.end()
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
        break
    }
}
