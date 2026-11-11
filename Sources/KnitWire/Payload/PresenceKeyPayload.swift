/// One or two of a contact's presence keys, ``MessageContent/pk`` under ``MessageContent/Control/presenceKey``
/// (`PresenceKeyPayload`, `Wire.kt:828-848` at knit-next `cad69c77b`; knit-next ADR 2026-11.xp6d, "The presence key"; ADR
/// 2026-11.sv5t). Each key is the 32 bytes the sender's blinded advert's tag is a MAC under (`BlindTag` in KnitCrypto).
/// This port receives them (ADR 2026-11.sv5t) and sends its own, padded by ``PresenceKeyFrame`` (ADR 2026-11.prsp).
///
/// Read as kotlinx's `cryptoCbor` reads it (`Crypto.kt:95-100`): ``generation`` and ``key`` required, the rest nullable,
/// every `Long` wrapped and every key a byte string, so a value of the wrong kind fails the whole content, as it fails
/// Android's open (`DECRYPT_FAILED`). Shape only: the 32-byte keys, a positive generation, the next pair both or neither
/// and above the current one are `PresenceKeyPolicy`'s to refuse, after the open commits.
///
/// Its printing shows the generations only, never a key, as Kotlin's `toString` (`Wire.kt:846-847`), so a log line,
/// `dump`, a failed `#expect` or ``MessageContent``'s own printing never shows one.
public struct PresenceKeyPayload: CBORRepresentable, Equatable {
    /// The current key's generation (`g`): an order only, never a time.
    public var generation: Int64
    /// The current key (`k`), as received.
    public var key: [UInt8]
    /// The next key's generation (`ng`).
    public var nextGeneration: Int64?
    /// The key the sender airs at its next rotation (`nk`), as received.
    public var nextKey: [UInt8]?
    /// Filler that sizes every ctl 11 plaintext alike (`p`); it means nothing, and is kept only so the content re-encodes
    /// to its bytes.
    public var pad: [UInt8]?

    /// Makes a presence-key payload.
    public init(generation: Int64, key: [UInt8], nextGeneration: Int64? = nil, nextKey: [UInt8]? = nil, pad: [UInt8]? = nil) {
        self.generation = generation
        self.key = key
        self.nextGeneration = nextGeneration
        self.nextKey = nextKey
        self.pad = pad
    }

    /// Reads a presence-key payload from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "PresenceKeyPayload")
        generation = try fields.required("g", .int64)
        key = try fields.required("k", .bytes)
        nextGeneration = try fields.nullable("ng", .int64)
        nextKey = try fields.nullable("nk", .bytes)
        pad = try fields.nullable("p", .bytes)
    }

    /// The payload as an item, in declaration order, nulls omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.long("g", generation)
        writer.bytes("k", key)
        writer.long("ng", optional: nextGeneration)
        if let nextKey {
            writer.bytes("nk", nextKey)
        }
        if let pad {
            writer.bytes("p", pad)
        }
        return writer.cbor
    }
}

extension PresenceKeyPayload: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The generations only (`PresenceKeyPayload(g=…, next=…)`, as Kotlin prints it).
    public var description: String {
        "PresenceKeyPayload(g=\(generation), next=\(nextGeneration.map(String.init) ?? "-"))"
    }

    /// As ``description``.
    public var debugDescription: String { description }

    /// The generations only, so reflection shows no key.
    public var customMirror: Mirror {
        Mirror(self, children: ["generation": generation, "nextGeneration": nextGeneration as Any], displayStyle: .struct)
    }
}
