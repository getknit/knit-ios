/// The link handshake's payload: `nodeId|version|capsHex`, then `|n<nonce>` from a build that proves its id, in UTF-8
/// (`Protocol.hello` and `Protocol.parse` in knit-next; the `link-hello-proof` contract, §2).
///
/// Both sides send one: the dialer first, then the responder's reply. On their own, the id and the capabilities here
/// are an unauthenticated claim: the signed copy in the profile is the one that gates anything. When both HELLOs carry
/// ``Capabilities/linkProof``, each side signs both payloads as they crossed, nonces included (`LinkProof` in KnitCrypto),
/// and the link is that peer's only once its signature holds.
public struct Hello: Sendable, Equatable {
    private static let separator = "|"
    private static let hexRadix = 16
    private static let versionField = 1
    private static let capabilitiesField = 2
    private static let nonceField = 3
    /// What starts the nonce's field.
    private static let noncePrefix = "n"
    /// A nonce's bytes, as `LinkProof.nonceByteCount` has them: 32 lowercase hex digits on the wire.
    public static let nonceByteCount = 16
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

    /// Makes a HELLO. A nonce is written only when given, and is meant to be ``nonceByteCount`` bytes.
    public init(nodeId: String, version: Int = WireProtocol.version, capabilities: Capabilities = .local, nonce: [UInt8]? = nil) {
        self.nodeId = nodeId
        self.version = version
        self.capabilities = capabilities
        self.nonce = nonce
    }

    /// Parses a HELLO payload the way Android does: it never fails, and a missing or unreadable field reads
    /// as 0. Invalid UTF-8 is replaced, as Kotlin's `decodeToString` does. Fields past the nonce are ignored.
    public init(payload: [UInt8]) {
        // Kotlin's decodeToString replaces malformed UTF-8 rather than failing, and so must this.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: payload, as: UTF8.self)
        let parts = text.split(separator: Self.separator, omittingEmptySubsequences: false)
        nodeId = parts.first.map(String.init) ?? ""
        version = parts.count > Self.versionField ? Int(Int32(parts[Self.versionField]) ?? 0) : 0
        let capabilityBits = parts.count > Self.capabilitiesField ? Int64(parts[Self.capabilitiesField], radix: Self.hexRadix) : nil
        capabilities = Capabilities(rawValue: capabilityBits ?? 0)
        nonce = parts.count > Self.nonceField ? Self.nonce(in: parts[Self.nonceField]) : nil
    }

    /// The payload's bytes.
    public var payload: [UInt8] {
        var fields = [nodeId, String(version), capabilities.hex]
        if let nonce {
            fields.append(Self.noncePrefix + Hex.encode(nonce))
        }
        return Array(fields.joined(separator: Self.separator).utf8)
    }

    /// The nonce a field holds: `n` and exactly 32 lowercase hex digits, and nothing else (`Protocol.nonceOf`).
    private static func nonce(in field: Substring) -> [UInt8]? {
        guard field.hasPrefix(noncePrefix), field.utf8.count == noncePrefix.utf8.count + nonceByteCount * hexDigitsPerByte else {
            return nil
        }
        // `Hex.decode` reads lowercase only, so an uppercase digit is no nonce, as on Android.
        return Hex.decode(String(field.dropFirst(noncePrefix.count)))
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
