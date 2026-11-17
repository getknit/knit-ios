/// The first record each side sends (`SpoolHello`, §7.1–7.2): the spool's carries the versions it speaks, its limits and
/// its proof-of-work difficulty; the client's carries only the version it chose, `{t:"hello", v:1}`.
///
/// A spool's hello may also carry optional capabilities this build never uses: a commons, TURN, tickets, STUN, casts and
/// signals. Each is checked as kotlinx types it and dropped, so a hello Android's decode refuses (and answers by closing
/// 4002) is refused here too.
public struct SpoolHello: CBORRepresentable, Equatable, Sendable {
    /// The highest record-layer version the sender speaks; the client's chosen one in its own hello.
    public var version: Int
    /// The lowest version the spool speaks, or `nil` for ``version`` alone.
    public var minimum: Int?
    /// The spool's limits, which are claims to clamp, not bounds to trust (knit-next ADR 025).
    public var limits: SpoolLimits?
    /// The leading zero bits the spool wants in a stamp for a scope it does not hold; 0 or `nil` for none.
    public var powBits: Int?

    /// Makes a hello.
    public init(version: Int, minimum: Int? = nil, limits: SpoolLimits? = nil, powBits: Int? = nil) {
        self.version = version
        self.minimum = minimum
        self.limits = limits
        self.powBits = powBits
    }

    /// The client's hello: the version it chose, and nothing that identifies it (B-7.1-5).
    public static var client: Self { Self(version: SpoolRecordLayer.version) }

    /// Reads a hello as kotlinx does, its capability fields checked and dropped.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolHello")
        _ = try fields.required("t", .text)
        version = try fields.required("v", .int32)
        minimum = try fields.nullable("min", .int32)
        limits = try fields.nullable("limits", .object(SpoolLimits.self))
        powBits = try fields.nullable("powBits", .int32)
        _ = try fields.nullable("commons", .checked(as: SpoolCommonsShape.self))
        _ = try fields.nullable("turn", .bool)
        _ = try fields.nullable("ent", .bool)
        _ = try fields.nullable("stun", .texts)
        _ = try fields.nullable("cast", .checked(as: SpoolRateShape.self))
        _ = try fields.nullable("entGates", .int64)
        _ = try fields.nullable("rooms", .checked(asListOf: SpoolRoomShape.self))
        _ = try fields.nullable("turnHosts", .texts)
        _ = try fields.nullable("sig", .checked(as: SpoolRateShape.self))
    }

    /// The hello as an item, in `SpoolHello`'s declaration order.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("t", SpoolRecordType.hello)
        writer.int("v", version)
        writer.int("min", optional: minimum)
        writer.object("limits", optional: limits)
        writer.int("powBits", optional: powBits)
        return writer.cbor
    }
}

/// The hard limits a spool advertises in its hello (`SpoolLimits`). The attachment three come all together or not at
/// all, and this build sends no attachment record whatever they say.
public struct SpoolLimits: CBORRepresentable, Equatable, Sendable {
    /// The largest blob the spool stores.
    public var maxBlob: Int
    /// The largest record it reads.
    public var maxRecord: Int
    /// The most scopes one connection may subscribe.
    public var maxScopes: Int
    /// The most ids one `pull` may name.
    public var maxPull: Int
    /// The highest `maxFrames` it applies to a scope.
    public var maxFramesCap: Int
    /// The longest `ttlMs` it applies to a scope.
    public var maxTtlMs: Int64
    /// An attachment-capable spool's per-scope byte quota.
    public var maxAttachBytes: Int?
    /// An attachment-capable spool's largest chunk.
    public var maxAChunk: Int?
    /// An attachment-capable spool's most chunks a `aget`.
    public var maxAget: Int?

    /// Makes a set of limits.
    public init(
        maxBlob: Int, maxRecord: Int, maxScopes: Int, maxPull: Int, maxFramesCap: Int, maxTtlMs: Int64,
        maxAttachBytes: Int? = nil, maxAChunk: Int? = nil, maxAget: Int? = nil
    ) {
        self.maxBlob = maxBlob
        self.maxRecord = maxRecord
        self.maxScopes = maxScopes
        self.maxPull = maxPull
        self.maxFramesCap = maxFramesCap
        self.maxTtlMs = maxTtlMs
        self.maxAttachBytes = maxAttachBytes
        self.maxAChunk = maxAChunk
        self.maxAget = maxAget
    }

    /// Reads the limits as kotlinx does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolLimits")
        maxBlob = try fields.required("maxBlob", .int32)
        maxRecord = try fields.required("maxRecord", .int32)
        maxScopes = try fields.required("maxScopes", .int32)
        maxPull = try fields.required("maxPull", .int32)
        maxFramesCap = try fields.required("maxFramesCap", .int32)
        maxTtlMs = try fields.required("maxTtlMs", .int64)
        maxAttachBytes = try fields.nullable("maxAttachBytes", .int32)
        maxAChunk = try fields.nullable("maxAChunk", .int32)
        maxAget = try fields.nullable("maxAget", .int32)
    }

    /// The limits as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("maxBlob", maxBlob)
        writer.int("maxRecord", maxRecord)
        writer.int("maxScopes", maxScopes)
        writer.int("maxPull", maxPull)
        writer.int("maxFramesCap", maxFramesCap)
        writer.long("maxTtlMs", maxTtlMs)
        writer.int("maxAttachBytes", optional: maxAttachBytes)
        writer.int("maxAChunk", optional: maxAChunk)
        writer.int("maxAget", optional: maxAget)
        return writer.cbor
    }
}

extension SpoolLimits {
    /// The most ids a pull may name, whatever the spool says (`MAX_PULL_CEILING`).
    public static let maxPullCeiling = 256

    /// The limits held to what this client tracks (`SpoolLimits.clamped`, `SpoolConnection.kt`, knit-next ADR 025): a
    /// spool's limits are its claim about itself, and a hostile one could advertise `Int.max` and so set its own budget
    /// for every check written against them. `maxBlob` and `maxRecord` go no higher than
    /// ``SpoolRecordLayer/maxInboundRecord`` and `maxPull` stays within 1 to ``maxPullCeiling``, as Kotlin holds them. Every
    /// other limit is held at 0 or above, which Kotlin needs no clamp for: a negative count or range bound traps in Swift.
    /// The attachment three are never read here.
    public func clamped() -> Self {
        var limits = self
        limits.maxBlob = min(max(maxBlob, 0), SpoolRecordLayer.maxInboundRecord)
        limits.maxRecord = min(max(maxRecord, 0), SpoolRecordLayer.maxInboundRecord)
        limits.maxScopes = max(maxScopes, 0)
        limits.maxPull = min(max(maxPull, 1), Self.maxPullCeiling)
        limits.maxFramesCap = max(maxFramesCap, 0)
        limits.maxTtlMs = max(maxTtlMs, 0)
        return limits
    }
}

/// A hello's `commons` (`SpoolCommonsInfo`), checked and dropped: this build joins no commons.
private struct SpoolCommonsShape: CBORShape {
    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolCommonsInfo")
        _ = try fields.nullable("name", .text)
        try Self.checkBounds(fields)
        _ = try fields.optional("attach", .bool)
    }

    static func checkBounds(_ fields: CBORFields) throws(WireDecodingError) {
        _ = try fields.required("maxFrames", .int32)
        _ = try fields.required("ttlMs", .int64)
        _ = try fields.required("maxBlob", .int32)
    }
}

/// One of a hello's `rooms` (`SpoolCommonsRoom`), checked and dropped.
private struct SpoolRoomShape: CBORShape {
    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolCommonsRoom")
        _ = try fields.required("tag", .bytes)
        _ = try fields.nullable("name", .text)
        try SpoolCommonsShape.checkBounds(fields)
        _ = try fields.optional("attach", .bool)
    }
}

/// A hello's `cast` or `sig` (`SpoolCastInfo`, `SpoolSigInfo`, the same two fields), checked and dropped: this build
/// sends neither.
private struct SpoolRateShape: CBORShape {
    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "SpoolRateInfo")
        _ = try fields.required("maxBytes", .int32)
        _ = try fields.required("rate", .int32)
    }
}
