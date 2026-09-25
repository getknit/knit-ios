/// A v2 or v3 DM ratchet header (`RatchetHeader` in knit-next's `Wire.kt`).
///
/// This build decodes it so ratchet frames round-trip and can be carried; the ratchet itself is the milestone
/// after the MVP (`.agents/context/crypto.md`).
public struct RatchetHeader: CBORRepresentable, Equatable {
    /// The reset flag: a fresh X3DH init that replaces the session.
    public static let resetFlag = 0x1

    /// The sender's epoch number.
    public var se: Int
    /// The sender's epoch X25519 public key, 32 bytes.
    public var ek: [UInt8]
    /// Which of the receiver's epochs is the DH base; 0 means its signed prekey.
    public var pe: Int
    /// The message index within the sender's epoch chain.
    public var n: Int
    /// The session bootstrap, sent until the session is confirmed.
    public var initial: RatchetInit?
    /// Header flags, ``resetFlag`` included.
    public var flags: Int

    /// Makes a header.
    public init(se: Int, ek: [UInt8], pe: Int, n: Int, initial: RatchetInit? = nil, flags: Int = 0) {
        self.se = se
        self.ek = ek
        self.pe = pe
        self.n = n
        self.initial = initial
        self.flags = flags
    }

    /// Reads a header from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "RatchetHeader")
        se = try fields.required("se", .int32)
        ek = try fields.required("ek", .bytes)
        pe = try fields.required("pe", .int32)
        n = try fields.required("n", .int32)
        initial = try fields.nullable("init", .object(RatchetInit.self))
        flags = try fields.optional("flags", .int32) ?? 0
    }

    /// The header as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("se", se)
        writer.bytes("ek", ek)
        writer.int("pe", pe)
        writer.int("n", n)
        writer.object("init", optional: initial)
        writer.int("flags", flags, default: 0)
        return writer.cbor
    }
}

/// A ratchet session bootstrap (`RatchetInit` in knit-next's `Wire.kt`).
public struct RatchetInit: CBORRepresentable, Equatable {
    /// The initiator's ephemeral X25519 public key, 32 bytes.
    public var eph: [UInt8]
    /// The id of the responder's signed prekey it used.
    public var pkid: Int
    /// When the initiator minted it, in epoch milliseconds.
    public var at: Int64

    /// Makes a bootstrap record.
    public init(eph: [UInt8], pkid: Int, at: Int64) {
        self.eph = eph
        self.pkid = pkid
        self.at = at
    }

    /// Reads a bootstrap record from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "RatchetInit")
        eph = try fields.required("eph", .bytes)
        pkid = try fields.required("pkid", .int32)
        at = try fields.required("at", .int64)
    }

    /// The record as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.bytes("eph", eph)
        writer.int("pkid", pkid)
        writer.long("at", at)
        return writer.cbor
    }
}

/// A v2 group ratchet header (`GroupRatchetHeader` in knit-next's `Wire.kt`).
public struct GroupRatchetHeader: CBORRepresentable, Equatable {
    /// The sender's group epoch.
    public var se: Int
    /// The message index within it.
    public var n: Int

    /// Makes a group header.
    public init(se: Int, n: Int) {
        self.se = se
        self.n = n
    }

    /// Reads a group header from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupRatchetHeader")
        se = try fields.required("se", .int32)
        n = try fields.required("n", .int32)
    }

    /// The header as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("se", se)
        writer.int("n", n)
        return writer.cbor
    }
}
