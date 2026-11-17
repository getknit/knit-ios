/// The bounds a member declares for a scope when it subscribes, and the spool echoes in a `digest` (`ScopeBounds`).
public struct ScopeBounds: CBORRepresentable, Equatable, Sendable {
    /// The most blobs the scope keeps.
    public var maxFrames: Int
    /// How long the scope keeps a blob, in milliseconds.
    public var ttlMs: Int64
    /// The largest blob the scope takes.
    public var maxBlob: Int

    /// Makes a set of bounds.
    public init(maxFrames: Int, ttlMs: Int64, maxBlob: Int) {
        self.maxFrames = maxFrames
        self.ttlMs = ttlMs
        self.maxBlob = maxBlob
    }

    /// Reads bounds as kotlinx does: all three required.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ScopeBounds")
        maxFrames = try fields.required("maxFrames", .int32)
        ttlMs = try fields.required("ttlMs", .int64)
        maxBlob = try fields.required("maxBlob", .int32)
    }

    /// The bounds as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("maxFrames", maxFrames)
        writer.long("ttlMs", ttlMs)
        writer.int("maxBlob", maxBlob)
        return writer.cbor
    }
}

/// A mined proof-of-work stamp (`PowStamp`, §8): counter `n` for the UTC day number `d`.
public struct PowStamp: CBORRepresentable, Equatable, Sendable {
    /// The counter that makes the hash's leading bits zero.
    public var counter: Int64
    /// The UTC day the stamp was mined for, `floor(unixMillis / 86 400 000)`.
    public var day: Int64

    /// Makes a stamp.
    public init(counter: Int64, day: Int64) {
        self.counter = counter
        self.day = day
    }

    /// Reads a stamp: both fields required.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "PowStamp")
        counter = try fields.required("n", .int64)
        day = try fields.required("d", .int64)
    }

    /// The stamp as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.long("n", counter)
        writer.long("d", day)
        return writer.cbor
    }
}

/// One scope a `sub` names (`ScopeSub`): its id, its bounds, and a stamp only once the spool has asked for one.
public struct ScopeSub: CBORRepresentable, Equatable, Sendable {
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The bounds declared for it.
    public var bounds: ScopeBounds
    /// The stamp, sent only after the spool refused the scope with `pow` (C-8-4).
    public var pow: PowStamp?

    /// Makes one subscription.
    public init(scope: [UInt8], bounds: ScopeBounds, pow: PowStamp? = nil) {
        self.scope = scope
        self.bounds = bounds
        self.pow = pow
    }

    /// Reads one subscription as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ScopeSub")
        scope = try fields.required("scope", .bytes)
        bounds = try fields.required("bounds", .object(ScopeBounds.self))
        pow = try fields.nullable("pow", .object(PowStamp.self))
    }

    /// The subscription as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.bytes("scope", scope)
        writer.object("bounds", bounds)
        writer.object("pow", optional: pow)
        return writer.cbor
    }
}

/// Subscribe to scopes (`SpoolSub`). Answered by one `digest`, or a scoped `err` with no `q`, per scope.
public struct SpoolSub: CBORRepresentable, Equatable, Sendable {
    /// The request number, `q`.
    public var request: Int64
    /// The scopes.
    public var subs: [ScopeSub]

    /// Makes a subscription request.
    public init(request: Int64, subs: [ScopeSub]) {
        self.request = request
        self.subs = subs
    }

    /// Reads a subscription request as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolSub")
        _ = try fields.required("t", .text)
        request = try fields.required("q", .int64)
        subs = try fields.required("subs", .list(of: ScopeSub.self))
    }

    /// The request as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.sub)
        writer.long("q", request)
        writer.list("subs", subs)
        return writer.cbor
    }
}

/// A scope's anti-entropy cue (`SpoolDigest`, §6.3): the fold of its live blob ids, how many there are, whether the
/// scope is full, and the bounds the spool applies. Sent on `sub` and whenever the spool chooses; no `q`.
public struct SpoolDigest: CBORRepresentable, Equatable, Sendable {
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The 8-byte big-endian XOR of FNV-1a-64 over the live blob ids.
    public var digest: [UInt8]
    /// How many blobs are live.
    public var count: Int
    /// Whether the scope is at its bounds.
    public var full: Bool
    /// The bounds the spool applies, the most recent `sub`'s clamped to its own limits.
    public var bounds: ScopeBounds

    /// Makes a digest.
    public init(scope: [UInt8], digest: [UInt8], count: Int, full: Bool, bounds: ScopeBounds) {
        self.scope = scope
        self.digest = digest
        self.count = count
        self.full = full
        self.bounds = bounds
    }

    /// Reads a digest as kotlinx does: every field required, `full` written even when false.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolDigest")
        _ = try fields.required("t", .text)
        scope = try fields.required("scope", .bytes)
        digest = try fields.required("digest", .bytes)
        count = try fields.required("count", .int32)
        full = try fields.required("full", .bool)
        bounds = try fields.required("bounds", .object(ScopeBounds.self))
    }

    /// The digest as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.digest)
        writer.bytes("scope", scope)
        writer.bytes("digest", digest)
        writer.int("count", count)
        writer.item("full", .bool(full))
        writer.object("bounds", bounds)
        return writer.cbor
    }
}

/// The id exchange behind a digest mismatch (`SpoolList`): asked with the scope alone, answered with the live ids and
/// the tombstones under the same `q`.
public struct SpoolList: CBORRepresentable, Equatable, Sendable {
    /// The request number, `q`, echoed in the answer.
    public var request: Int64
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The answer's live blob ids, `nil` in the request.
    public var blobIds: [[UInt8]]?
    /// The answer's tombstoned blob ids, `nil` in the request.
    public var tombstones: [[UInt8]]?

    /// Makes a listing request or answer.
    public init(request: Int64, scope: [UInt8], blobIds: [[UInt8]]? = nil, tombstones: [[UInt8]]? = nil) {
        self.request = request
        self.scope = scope
        self.blobIds = blobIds
        self.tombstones = tombstones
    }

    /// Reads a listing as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolList")
        _ = try fields.required("t", .text)
        request = try fields.required("q", .int64)
        scope = try fields.required("scope", .bytes)
        blobIds = try fields.nullable("blobIds", .byteStrings)
        tombstones = try fields.nullable("tombstones", .byteStrings)
    }

    /// The listing as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.list)
        writer.long("q", request)
        writer.bytes("scope", scope)
        writer.byteStrings("blobIds", optional: blobIds)
        writer.byteStrings("tombstones", optional: tombstones)
        return writer.cbor
    }
}

/// Ask for blobs by id (`SpoolPull`), at most the spool's `maxPull` at a time. Answered by a `blob` per id the spool
/// holds, then an `ok` naming the ones it does not.
public struct SpoolPull: CBORRepresentable, Equatable, Sendable {
    /// The request number, `q`.
    public var request: Int64
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The ids wanted.
    public var blobIds: [[UInt8]]

    /// Makes a pull.
    public init(request: Int64, scope: [UInt8], blobIds: [[UInt8]]) {
        self.request = request
        self.scope = scope
        self.blobIds = blobIds
    }

    /// Reads a pull as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolPull")
        _ = try fields.required("t", .text)
        request = try fields.required("q", .int64)
        scope = try fields.required("scope", .bytes)
        blobIds = try fields.required("blobIds", .byteStrings)
    }

    /// The pull as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.pull)
        writer.long("q", request)
        writer.bytes("scope", scope)
        writer.byteStrings("blobIds", blobIds)
        return writer.cbor
    }
}

extension CBORFieldWriter {
    /// A `List<ByteArray>`, each element a byte string.
    mutating func byteStrings(_ key: String, _ value: [[UInt8]]) {
        item(key, .array(value.map(CBOR.bytes)))
    }

    /// A nullable `List<ByteArray>`, left out when `nil`.
    mutating func byteStrings(_ key: String, optional value: [[UInt8]]?) {
        if let value {
            byteStrings(key, value)
        }
    }
}
