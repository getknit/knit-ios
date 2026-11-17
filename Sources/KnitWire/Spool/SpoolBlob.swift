/// One blob the spool sends for a `pull` (`SpoolBlob`). It carries no `q`, so the client attributes it by scope and by
/// whether a pull named the id.
public struct SpoolBlob: CBORRepresentable, Equatable, Sendable {
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The blob's id, the SHA-256 of ``data``.
    public var blobId: [UInt8]
    /// The sealed blob.
    public var data: [UInt8]

    /// Makes a pulled blob.
    public init(scope: [UInt8], blobId: [UInt8], data: [UInt8]) {
        self.scope = scope
        self.blobId = blobId
        self.data = data
    }

    /// Reads a pulled blob as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolBlob")
        _ = try fields.required("t", .text)
        scope = try fields.required("scope", .bytes)
        blobId = try fields.required("blobId", .bytes)
        data = try fields.required("data", .bytes)
    }

    /// The pulled blob as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.blob)
        writer.bytes("scope", scope)
        writer.bytes("blobId", blobId)
        writer.bytes("data", data)
        return writer.cbor
    }
}

/// Store a blob (`SpoolPush`). The spool checks the hash, the size, the quota and the tombstones, folds the digest, and
/// fans an `event` out to every other subscriber. A duplicate is acked with no fan-out (S-7.2-7).
public struct SpoolPush: CBORRepresentable, Equatable, Sendable {
    /// The request number, `q`.
    public var request: Int64
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The blob's id, the SHA-256 of ``data``.
    public var blobId: [UInt8]
    /// The sealed blob.
    public var data: [UInt8]
    /// A stamp, sent only after the spool refused this scope with `pow`.
    public var pow: PowStamp?

    /// Makes a push.
    public init(request: Int64, scope: [UInt8], blobId: [UInt8], data: [UInt8], pow: PowStamp? = nil) {
        self.request = request
        self.scope = scope
        self.blobId = blobId
        self.data = data
        self.pow = pow
    }

    /// Reads a push as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolPush")
        _ = try fields.required("t", .text)
        request = try fields.required("q", .int64)
        scope = try fields.required("scope", .bytes)
        blobId = try fields.required("blobId", .bytes)
        data = try fields.required("data", .bytes)
        pow = try fields.nullable("pow", .object(PowStamp.self))
    }

    /// The push as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.push)
        writer.long("q", request)
        writer.bytes("scope", scope)
        writer.bytes("blobId", blobId)
        writer.bytes("data", data)
        writer.object("pow", optional: pow)
        return writer.cbor
    }
}

/// A blob another subscriber pushed, delivered live (`SpoolEvent`), never to the uploader. Best-effort: correctness
/// rests on the heal loop (§9), and a blob that fails to open here is dropped, never quarantined (C-9.3-4).
public struct SpoolEvent: CBORRepresentable, Equatable, Sendable {
    /// The scope's 32-byte id.
    public var scope: [UInt8]
    /// The blob's id, the SHA-256 of ``data``.
    public var blobId: [UInt8]
    /// The sealed blob.
    public var data: [UInt8]

    /// Makes an event.
    public init(scope: [UInt8], blobId: [UInt8], data: [UInt8]) {
        self.scope = scope
        self.blobId = blobId
        self.data = data
    }

    /// Reads an event as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolEvent")
        _ = try fields.required("t", .text)
        scope = try fields.required("scope", .bytes)
        blobId = try fields.required("blobId", .bytes)
        data = try fields.required("data", .bytes)
    }

    /// The event as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.event)
        writer.bytes("scope", scope)
        writer.bytes("blobId", blobId)
        writer.bytes("data", data)
        return writer.cbor
    }
}

/// A request's terminal success (`SpoolOk`). A pull's names the ids the spool did not hold.
public struct SpoolOk: CBORRepresentable, Equatable, Sendable {
    /// The request number it answers, `q`.
    public var request: Int64
    /// For a pull, the ids the spool does not hold; `nil` otherwise.
    public var missing: [[UInt8]]?

    /// Makes a success.
    public init(request: Int64, missing: [[UInt8]]? = nil) {
        self.request = request
        self.missing = missing
    }

    /// Reads a success as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolOk")
        _ = try fields.required("t", .text)
        request = try fields.required("q", .int64)
        missing = try fields.nullable("missing", .byteStrings)
    }

    /// The success as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.ok)
        writer.long("q", request)
        writer.byteStrings("missing", optional: missing)
        return writer.cbor
    }
}

/// A terminal failure (`SpoolErr`): a request's when it carries `q`, a scope's when it carries `scope` alone, the
/// connection's when it carries neither. ``code`` is whatever the spool sent, unbounded until the caller cuts it to
/// ``SpoolRecordLayer/maxErrorCodeCharacters``; ``message`` is free text for a log, never for the screen.
public struct SpoolErr: CBORRepresentable, Equatable, Sendable {
    /// The code, one of ``SpoolErrorCode``'s or one this build does not know.
    public var code: String
    /// The request it answers, `q`.
    public var request: Int64?
    /// The scope it is about.
    public var scope: [UInt8]?
    /// The spool's own words.
    public var message: String?
    /// How long the spool asks the client to wait, a hint inside the client's own park window (C-9.1-5).
    public var retryMs: Int64?

    /// Makes a failure.
    public init(code: String, request: Int64? = nil, scope: [UInt8]? = nil, message: String? = nil, retryMs: Int64? = nil) {
        self.code = code
        self.request = request
        self.scope = scope
        self.message = message
        self.retryMs = retryMs
    }

    /// Reads a failure as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolErr")
        _ = try fields.required("t", .text)
        code = try fields.required("code", .text)
        request = try fields.nullable("q", .int64)
        scope = try fields.nullable("scope", .bytes)
        message = try fields.nullable("msg", .text)
        retryMs = try fields.nullable("retryMs", .int64)
    }

    /// The failure as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.err)
        writer.text("code", code)
        writer.long("q", optional: request)
        writer.raw("scope", optional: scope.map(CBOR.bytes))
        writer.text("msg", optional: message)
        writer.long("retryMs", optional: retryMs)
        return writer.cbor
    }
}
