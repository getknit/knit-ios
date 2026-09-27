/// One record on an L2CAP link: `[type:1][length:4, big-endian][payload]` (`LinkFraming.kt` in knit-next).
public struct LinkRecord: Sendable, Equatable {
    /// A record's type tag. Android drops the link on any other value, so never send one outside this set.
    public enum Tag: UInt8, Sendable {
        /// A `WireEnvelope`.
        case frame = 1
        /// A file's JSON header.
        case fileHeader = 2
        /// Raw file bytes.
        case fileChunk = 3
        /// The end of a file.
        case fileEnd = 4
        /// A keepalive; Android never sends one and ignores it.
        case keepalive = 5
        /// The handshake: `nodeId|version|capsHex`.
        case hello = 6
        /// A custody digest: JSON `{"ids":[…]}`.
        case digest = 7
    }

    /// The largest payload either side accepts (`MAX_PAYLOAD_BYTES`).
    public static let maxPayloadBytes = 524_288 // 512 KiB
    /// The header: one tag byte and a four-byte length.
    public static let headerBytes = 5

    /// The record's type.
    public var tag: Tag
    /// The record's payload.
    public var payload: [UInt8]

    /// Makes a record.
    public init(_ tag: Tag, payload: [UInt8] = []) {
        self.tag = tag
        self.payload = payload
    }

    /// The record's bytes, or `nil` when the payload is too large for the link. Android drops an oversize
    /// record and keeps the link; so does the caller.
    public var encoded: [UInt8]? {
        guard payload.count <= Self.maxPayloadBytes else {
            return nil
        }
        let length = UInt32(payload.count)
        var output: [UInt8] = [tag.rawValue]
        output.reserveCapacity(Self.headerBytes + payload.count)
        for shift in stride(from: UInt32.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
            output.append(UInt8(truncatingIfNeeded: length >> UInt32(shift)))
        }
        return output + payload
    }
}

/// Why a link's byte stream is no longer a sequence of records. Android throws on each of these and drops
/// the link, and so does the link session.
public enum LinkRecordError: Error, Sendable, Equatable {
    /// A tag outside 1 to 7.
    case unknownTag(UInt8)
    /// A length outside 0 to ``LinkRecord/maxPayloadBytes``.
    case lengthOutOfRange(UInt32)
}

/// Splits a link's incoming bytes into records, however the radio chunked them.
///
/// Feed it bytes with ``append(_:)`` and drain complete records with ``next()``. It holds at most one partial
/// record, so memory stays bounded by ``LinkRecord/maxPayloadBytes``.
public struct LinkRecordReader: Sendable {
    /// Consumed bytes are dropped once they are more than half the buffer.
    private static let compactionDivisor = 2

    private var buffer: [UInt8] = []
    private var start = 0

    /// A reader with nothing buffered.
    public init() {
        // Nothing to set up.
    }

    /// Whether a partial record is buffered. At end of stream, a partial record means a truncated link.
    public var hasPartialRecord: Bool { start < buffer.count }

    /// How many of the link's bytes went into whole records: where the next record starts, counted from the first.
    public private(set) var consumed = 0

    /// Up to `count` buffered bytes from where the next record starts, which is what a bad record was, for the log.
    public func upcoming(_ count: Int) -> [UInt8] {
        Array(buffer[start..<min(buffer.count, start + count)])
    }

    /// Buffers bytes read from the link.
    public mutating func append(_ bytes: some Collection<UInt8>) {
        buffer += bytes
    }

    /// The next complete record, `nil` when more bytes are needed, or an error that ends the link.
    public mutating func next() throws(LinkRecordError) -> LinkRecord? {
        let available = buffer.count - start
        guard available >= LinkRecord.headerBytes else {
            return nil
        }
        guard let tag = LinkRecord.Tag(rawValue: buffer[start]) else {
            throw .unknownTag(buffer[start])
        }
        var length: UInt32 = 0
        for offset in 1..<LinkRecord.headerBytes {
            length = length << UInt32(UInt8.bitWidth) | UInt32(buffer[start + offset])
        }
        guard length <= LinkRecord.maxPayloadBytes else {
            throw .lengthOutOfRange(length)
        }
        let end = start + LinkRecord.headerBytes + Int(length)
        guard buffer.count >= end else {
            return nil
        }
        let record = LinkRecord(tag, payload: Array(buffer[(start + LinkRecord.headerBytes)..<end]))
        consumed += end - start
        start = end
        compact()
        return record
    }

    /// Drops consumed bytes once they are most of the buffer, so appends stay cheap.
    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > buffer.count / Self.compactionDivisor {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
