/// The link handshake's payload: `nodeId|version|capsHex`, then `|n<nonce>` from a build that proves its id, then up to
/// two advertised forms, `|t<form>` and `|a<form>`, in UTF-8 (`Protocol.hello` and `Protocol.parse` in knit-next; the
/// `link-hello-proof` contract, §2; knit-next ADR 2026-11.xp6d).
///
/// Both sides send one: the dialer first, then the responder's reply. On their own, the id and the capabilities here
/// are an unauthenticated claim: the signed copy in the profile is the one that gates anything. When both HELLOs carry
/// ``Capabilities/linkProof``, each side signs both payloads as they crossed, nonces included (`LinkProof` in KnitCrypto),
/// and the link is that peer's only once its signature holds.
public struct Hello: Sendable, Equatable {
    private static let separator: Unicode.Scalar = "|"
    private static let hexRadix = 16
    private static let versionField = 1
    private static let capabilitiesField = 2
    private static let nonceField = 3
    /// What starts the nonce's field.
    private static let noncePrefix = "n"
    /// What starts the told form's field (`TOLD_PREFIX`, `Protocol.kt:247` at knit-next `cad69c77b`).
    private static let toldPrefix = "t"
    /// What starts the addressed form's field (`ADDRESSED_PREFIX`, `Protocol.kt:248`): `a`, never `d`, which the Wi-Fi
    /// Aware SSI's digest suffix uses.
    private static let addressedPrefix = "a"
    /// A nonce's bytes, as `LinkProof.nonceByteCount` has them: 32 lowercase hex digits on the wire.
    public static let nonceByteCount = 16
    /// An advertised form's bytes in a `t` or `a` field: an advert's bytes 1–16, 32 lowercase hex digits on the wire
    /// (`HELLO_FORM_BYTES`, `Protocol.kt:241`).
    public static let formByteCount = 16
    private static let hexDigitsPerByte = 2

    /// The sender's node id, exactly as sent. The parser does not validate it; the link session does.
    public var nodeId: String
    /// The sender's protocol version, 0 when missing or unreadable.
    public var version: Int
    /// The sender's capability bits, 0 when missing or unreadable.
    public var capabilities: Capabilities
    /// The sender's nonce for this connection, ``nonceByteCount`` bytes, or `nil` when the fourth field is missing or not
    /// exactly `n` and 32 lowercase hex digits. A HELLO whose capabilities carry ``Capabilities/linkProof`` and that has no
    /// nonce fails the link's proof; every other reader ignores the field, as every shipped build does.
    public var nonce: [UInt8]?
    /// The form the sender says it airs now (`t`, Kotlin's `PeerWire.told`): its advert's bytes 1–16, a tag while it blinds.
    /// This port writes it only while it blinds (ADR 2026-11.prsp), after the nonce and only with one. Read before a proof it
    /// is a hint at most; on a proven link it is the proven sender's claim, never proof it owns a tag.
    public var told: [UInt8]?
    /// The form a dialer says it dialed (`a`, Kotlin's `PeerWire.addressed`): the advert bytes 1–16 it read, ``formByteCount``
    /// bytes. Written after the nonce, and only with one.
    public var addressed: [UInt8]?

    /// Makes a HELLO. A nonce is written only when given, and is meant to be ``nonceByteCount`` bytes; a told and an addressed
    /// form only beside a nonce, each meant to be ``formByteCount`` bytes. `told` is the tag this node airs, given only while it
    /// blinds (`Protocol.hello(told, addressed)`, `Protocol.kt:261-276` at knit-next `cad69c77b`; ADR 2026-11.prsp).
    public init(
        nodeId: String, version: Int = WireProtocol.version, capabilities: Capabilities = .local, nonce: [UInt8]? = nil,
        told: [UInt8]? = nil, addressed: [UInt8]? = nil
    ) {
        self.nodeId = nodeId
        self.version = version
        self.capabilities = capabilities
        self.nonce = nonce
        self.told = told
        self.addressed = addressed
    }

    /// Parses a HELLO payload the way Android does: it never fails, and a missing or unreadable field reads
    /// as 0. Invalid UTF-8 is replaced, as Kotlin's `decodeToString` does. Behind a valid nonce, the fields after it are
    /// read for ``told`` and ``addressed``, in any order, unknown ones skipped (`Protocol.parse`, `Protocol.kt:321-335` at
    /// knit-next `cad69c77b`). Android also refuses a HELLO whose id is not canonical; here the link session judges the id,
    /// and neither form depends on it.
    public init(payload: [UInt8]) {
        // Kotlin's decodeToString replaces malformed UTF-8 rather than failing, and so must this.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: payload, as: UTF8.self)
        // Split on the scalar, as Kotlin's `split('|')` does on the UTF-16 unit: a `|` followed by a combining mark is one
        // Character, and a Character split would not cut there, moving every later field (the nonce's and the forms').
        let parts = text.unicodeScalars.split(separator: Self.separator, omittingEmptySubsequences: false).map(Substring.init)
        nodeId = parts.first.map(String.init) ?? ""
        version = parts.count > Self.versionField ? Int(Int32(parts[Self.versionField]) ?? 0) : 0
        let capabilityBits = parts.count > Self.capabilitiesField ? Int64(parts[Self.capabilitiesField], radix: Self.hexRadix) : nil
        capabilities = Capabilities(rawValue: capabilityBits ?? 0)
        nonce = parts.count > Self.nonceField ? Self.nonce(in: parts[Self.nonceField]) : nil
        // The forms sit behind a valid nonce only, so an SSI's `|d<digest>` or a future field never reads as one.
        let forms = nonce == nil ? [] : parts.dropFirst(Self.nonceField + 1)
        told = Self.onlyForm(in: forms, prefix: Self.toldPrefix)
        addressed = Self.onlyForm(in: forms, prefix: Self.addressedPrefix)
    }

    /// The payload's bytes.
    public var payload: [UInt8] {
        var fields = [nodeId, String(version), capabilities.hex]
        if let nonce {
            fields.append(Self.noncePrefix + Hex.encode(nonce))
            // `t` before `a`, as `Protocol.hello` writes them (`Protocol.kt:266-279`).
            if let told {
                fields.append(Self.toldPrefix + Hex.encode(told))
            }
            if let addressed {
                fields.append(Self.addressedPrefix + Hex.encode(addressed))
            }
        }
        return Array(fields.joined(separator: String(Self.separator)).utf8)
    }

    /// The nonce a field holds: `n` and exactly 32 lowercase hex digits, and nothing else (`Protocol.hexField`).
    private static func nonce(in field: Substring) -> [UInt8]? {
        hexField(field, prefix: noncePrefix, byteCount: nonceByteCount)
    }

    /// The one exact-shape field with `prefix` among `forms`, or nil when there is none or more than one, even two equal
    /// ones: a signer that writes `|tX|tY` must not be read as X by one port and as Y by another (`Protocol.onlyForm`,
    /// `Protocol.kt:339-342`). A field of another shape with the letter does not count.
    private static func onlyForm(in forms: ArraySlice<Substring>, prefix: String) -> [UInt8]? {
        let found = forms.compactMap { hexField($0, prefix: prefix, byteCount: formByteCount) }
        return found.count == 1 ? found.first : nil
    }

    /// `prefix` and exactly `byteCount` bytes in lowercase hex, or nothing at all (`Protocol.hexField`, `Protocol.kt:345-353`).
    private static func hexField(_ field: Substring, prefix: String, byteCount: Int) -> [UInt8]? {
        guard field.hasPrefix(prefix), field.utf8.count == prefix.utf8.count + byteCount * hexDigitsPerByte else {
            return nil
        }
        // `Hex.decode` reads lowercase only, so an uppercase digit is no field, as on Android.
        return Hex.decode(String(field.dropFirst(prefix.count)))
    }
}

/// Protocol-wide constants shared with knit-next's `Protocol.kt`. They are cross-platform law: change one only
/// together with knit-next, and only additively. (Not named `Protocol`, which is an Objective-C runtime class on
/// Apple platforms.)
public enum WireProtocol {
    /// `Protocol.VERSION`, carried in every HELLO and in `ProfileContent.protoVersion`.
    public static let version = 1
    /// How far ahead of the receiver's clock a frame's `sentAt` may be before it is refused
    /// (`MAX_FUTURE_SKEW_MS`): five minutes.
    public static let maxFutureSkewMilliseconds: Int64 = 300_000
}
