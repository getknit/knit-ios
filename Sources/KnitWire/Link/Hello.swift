/// The link handshake's payload: `nodeId|version|capsHex` in UTF-8 (`Protocol.advertise` and
/// `Protocol.parse` in knit-next).
///
/// Both sides send one: the dialer first, then the responder's reply. The capabilities here are an
/// unauthenticated routing hint; the signed copy in the profile is the one that gates anything.
public struct Hello: Sendable, Equatable {
    private static let separator = "|"
    private static let hexRadix = 16
    private static let versionField = 1
    private static let capabilitiesField = 2

    /// The sender's node id, exactly as sent. The parser does not validate it; the link session does.
    public var nodeId: String
    /// The sender's protocol version, 0 when missing or unreadable.
    public var version: Int
    /// The sender's capability bits, 0 when missing or unreadable.
    public var capabilities: Capabilities

    /// Makes a HELLO.
    public init(nodeId: String, version: Int = WireProtocol.version, capabilities: Capabilities = .local) {
        self.nodeId = nodeId
        self.version = version
        self.capabilities = capabilities
    }

    /// Parses a HELLO payload the way Android does: it never fails, and a missing or unreadable field reads
    /// as 0. Invalid UTF-8 is replaced, as Kotlin's `decodeToString` does.
    public init(payload: [UInt8]) {
        // Kotlin's decodeToString replaces malformed UTF-8 rather than failing, and so must this.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: payload, as: UTF8.self)
        let parts = text.split(separator: Self.separator, omittingEmptySubsequences: false)
        nodeId = parts.first.map(String.init) ?? ""
        version = parts.count > Self.versionField ? Int(Int32(parts[Self.versionField]) ?? 0) : 0
        let capabilityBits = parts.count > Self.capabilitiesField ? Int64(parts[Self.capabilitiesField], radix: Self.hexRadix) : nil
        capabilities = Capabilities(rawValue: capabilityBits ?? 0)
    }

    /// The payload's bytes.
    public var payload: [UInt8] {
        Array([nodeId, String(version), capabilities.hex].joined(separator: Self.separator).utf8)
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
