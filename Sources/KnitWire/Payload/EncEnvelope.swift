/// A sealed message (`EncEnvelope` in knit-next's `Wire.kt`).
///
/// Version 1 (``Version/staticKeys``) is the only one this build seals and opens: an AES-256-GCM body and
/// one HPKE-wrapped key per recipient. Versions 2 and 3 are the epoch ratchet; they are decoded so a frame
/// that carries one can be relayed and carried, then dropped locally.
public struct EncEnvelope: CBORRepresentable, Equatable {
    /// The envelope's sealing scheme. An unknown value is a delivery gate, never a relay gate.
    public enum Version {
        /// Static keys: HPKE-wrapped content keys, no forward secrecy.
        public static let staticKeys = 1
        /// The v2 epoch ratchet (DM `r` header, or group `g` header).
        public static let ratchet = 2
        /// The v3 compact DM ratchet.
        public static let compactRatchet = 3
    }

    /// The scheme version (wire key `v`).
    public var version: Int
    /// The AES-GCM nonce: 12 bytes for v1 and v2, empty for v3.
    public var nonce: [UInt8]
    /// The ciphertext followed by its 16-byte tag.
    public var ct: [UInt8]
    /// One wrapped content key per recipient, sorted by ``WrappedKey/to``; empty for the ratchet versions.
    public var keys: [WrappedKey]
    /// The DM ratchet header, for v2 and v3 (wire key `r`).
    public var ratchet: RatchetHeader?
    /// The group ratchet header, for group v2 (wire key `g`).
    public var groupRatchet: GroupRatchetHeader?

    /// Makes an envelope; the default version is v1.
    public init(
        version: Int = Version.staticKeys,
        nonce: [UInt8],
        ct: [UInt8],
        keys: [WrappedKey],
        ratchet: RatchetHeader? = nil,
        groupRatchet: GroupRatchetHeader? = nil
    ) {
        self.version = version
        self.nonce = nonce
        self.ct = ct
        self.keys = keys
        self.ratchet = ratchet
        self.groupRatchet = groupRatchet
    }

    /// Reads an envelope from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "EncEnvelope")
        version = try fields.optional("v", .int32) ?? Version.staticKeys
        nonce = try fields.required("nonce", .bytes)
        ct = try fields.required("ct", .bytes)
        keys = try fields.required("keys", .list(of: WrappedKey.self))
        ratchet = try fields.nullable("r", .object(RatchetHeader.self))
        groupRatchet = try fields.nullable("g", .object(GroupRatchetHeader.self))
    }

    /// The envelope as an item. `nonce`, `ct` and `keys` are written even when empty, because they have no
    /// default.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("v", version, default: Version.staticKeys)
        writer.bytes("nonce", nonce)
        writer.bytes("ct", ct)
        writer.list("keys", keys)
        writer.object("r", optional: ratchet)
        writer.object("g", optional: groupRatchet)
        return writer.cbor
    }
}

/// One recipient's wrapped content key (`WrappedKey` in knit-next's `Wire.kt`).
public struct WrappedKey: CBORRepresentable, Equatable {
    /// The recipient's node id.
    public var to: String
    /// The HPKE output, `enc` (32 bytes) followed by the sealed key (48 bytes).
    public var wk: [UInt8]

    /// Makes a wrapped key.
    public init(to: String, wk: [UInt8]) {
        self.to = to
        self.wk = wk
    }

    /// Reads a wrapped key from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "WrappedKey")
        to = try fields.required("to", .text)
        wk = try fields.required("wk", .bytes)
    }

    /// The wrapped key as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("to", to)
        writer.bytes("wk", wk)
        return writer.cbor
    }
}
