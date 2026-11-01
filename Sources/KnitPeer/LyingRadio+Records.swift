public import KnitWire

extension LyingRadio {
    /// What the lies have done so far.
    public struct Counts: Sendable, Equatable {
        /// `blobhas` answers rewritten.
        public var blobhasRewritten = 0
        /// FILE headers for a junk hash rewritten.
        public var junkHeadersRewritten = 0
        /// `AVATAR` headers for the advertised photo written, which withholding should keep at 0.
        public var advertisedPhotoPushed = 0
        /// Padded profiles written, by the node each went to.
        public var forgedProfilesWritten: [NodeId: Int] = [:]
        /// One-shot asks written, by the node each went to.
        public var blobAsksSent: [NodeId: Int] = [:]

        /// Nothing done yet.
        public init() {
            // Every count starts at none.
        }
    }

    /// A padded profile to inject: its frame, signed once, and its id.
    public struct Forge: Sendable, Equatable {
        /// The frame, written as it is on every link.
        public let wire: WireEnvelope
        /// Its id, which says whether a channel has it already.
        public let id: String

        /// `wire`, whose id is `id`.
        public init(wire: WireEnvelope, id: String) {
            self.wire = wire
            self.id = id
        }
    }
}

/// The record-level reads and rewrites ``LyingRadio`` makes, apart from its locking and its channels.
internal enum LyingRecords {
    /// What a FILE header becomes.
    enum HeaderLie {
        /// An `ATTACHMENT` header for a junk hash, rewritten to declare what was set: the record, and its header.
        case declared(LinkRecord, FileHeader)
        /// An `AVATAR` header for the photo our profile advertises in place of our own, left as it is.
        case advertisedPhoto(BlobHash)
        /// Any other header, or none that reads.
        case honest
    }

    /// A record's tag and its whole length, header included, read from the start of `bytes`, or `nil` when `bytes` is
    /// shorter than a header or its tag is none of the eight.
    static func header(of bytes: [UInt8]) -> (tag: LinkRecord.Tag, total: Int)? {
        guard bytes.count >= LinkRecord.headerBytes, let tag = LinkRecord.Tag(rawValue: bytes[0]) else {
            return nil
        }
        let length = bytes[1..<LinkRecord.headerBytes].reduce(0) { $0 << UInt8.bitWidth | Int($1) }
        return (tag, LinkRecord.headerBytes + length)
    }

    /// `bytes` as one whole record, or `nil` when they are not exactly one.
    static func whole(_ bytes: [UInt8]) -> LinkRecord? {
        var reader = LinkRecordReader()
        reader.append(bytes)
        guard let record = try? reader.next(), reader.consumed == bytes.count else {
            return nil
        }
        return record
    }

    /// A FRAME carrying our `blobhas` answer with the hashes in `sizes` claimed at those sizes (``BlobHasLie``), and the
    /// hashes it claims, or `nil` when it carries no answer to rewrite.
    static func blobHasAnswer(_ record: LinkRecord, sizes: [BlobHash: Int64]) -> (record: LinkRecord, hashes: [BlobHash])? {
        guard let wire = try? WireEnvelope(decoding: record.payload), let lie = BlobHasLie.rewrite(wire, sizes: sizes) else {
            return nil
        }
        return (LinkRecord(.frame, payload: lie.wire.encoded), lie.rewritten)
    }

    /// What `record`, a FILE header, becomes: an `ATTACHMENT` header for a hash in `declared` declares that size, or none
    /// for `nil`, its offset kept, so with one the size is the tail's, as a header's size always is
    /// (`LinkJSON.fileHeaderPayload`). Every other header goes as it is.
    static func fileHeader(_ record: LinkRecord, declared: [BlobHash: Int?], advertised: BlobHash?) -> HeaderLie {
        guard var header = LinkJSON.fileHeader(from: record.payload), let hash = BlobHash(header.key) else {
            return .honest
        }
        if header.kind == .avatar {
            return hash == advertised ? .advertisedPhoto(hash) : .honest
        }
        guard let declare = declared[hash] else {
            return .honest
        }
        header.size = declare
        return .declared(LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)), header)
    }
}
