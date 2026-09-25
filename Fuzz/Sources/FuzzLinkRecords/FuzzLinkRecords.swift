import KnitWire

/// Arbitrary bytes as a link's byte stream, delivered in chunks the input chooses, then every record parsed
/// the way a link session will: HELLO, digest and file-header JSON, and frames down to their payloads.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzLinkRecords(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    guard let chunkSeed = bytes.first else {
        return 0
    }
    let chunkSize = Int(chunkSeed % maxChunkBytes) + 1
    var reader = LinkRecordReader()
    var offset = 1
    while offset < bytes.count {
        reader.append(bytes[offset..<min(offset + chunkSize, bytes.count)])
        offset += chunkSize
        do {
            while let record = try reader.next() {
                parse(record)
            }
        } catch {
            return 0
        }
    }
    return 0
}

/// The largest chunk the first input byte can choose; radios deliver anything from one byte to an MTU.
private let maxChunkBytes: UInt8 = 64

private func parse(_ record: LinkRecord) {
    switch record.tag {
    case .hello:
        _ = Hello(payload: record.payload)
    case .digest:
        _ = LinkJSON.digestIds(from: record.payload)
    case .fileHeader:
        _ = LinkJSON.fileHeader(from: record.payload)
    case .frame:
        guard let wire = try? WireEnvelope(decoding: record.payload), let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            return
        }
        _ = FrameKey.of(wire, envelope)
        _ = try? ChatContent(decoding: envelope.payload)
        _ = try? ProfileContent(decoding: envelope.payload)
        _ = try? ReceiptContent(decoding: envelope.payload)
    case .fileChunk, .fileEnd, .keepalive:
        break
    }
}
