public import KnitWire

/// The text in a device's verify code, its QR code: `knit-id:v1:<nodeId>:<bundle>` (`VerifyPayload.kt`).
///
/// Scanning a peer's code proves the key pinned for them is the key their phone holds (ADR 2026-10.65xx). The
/// bundle is standard base64, whose alphabet has no `:`, so the first colon after the prefix ends the node id
/// and everything after it is the bundle.
public enum VerifyPayload {
    /// What every code starts with.
    public static let prefix = "knit-id:v1:"

    /// The code for our own bundle: always 150 ASCII bytes, since a bundle's text is always 112 characters.
    public static func encode(_ bundle: PublicKeyBundle) -> String {
        prefix + bundle.nodeId.string + ":" + bundle.encoded
    }

    /// The two fields of a code, as text, or `nil` when the text is not one (`VerifyPayload.parse`): it lacks
    /// the prefix, the colon after the node id, or either field is blank.
    ///
    /// The fields are compared by their bytes, never as Swift strings (ADR 2026-09.jc2x), so the parse walks
    /// UTF-8 rather than characters: a combining mark after the prefix leaves the prefix whole, as it does for
    /// Kotlin's `startsWith`.
    public static func parse(_ text: String) -> Parsed? {
        guard text.utf8.starts(with: prefix.utf8) else {
            return nil
        }
        let rest = text.utf8.dropFirst(prefix.utf8.count)
        // Kotlin's `substringBefore(':', "")` answers "" without a colon, which is blank.
        guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else {
            return nil
        }
        let nodeId = String(Substring(rest[..<colon]))
        let bundle = String(Substring(rest[rest.index(after: colon)...]))
        guard !TextLimits.isBlank(nodeId), !TextLimits.isBlank(bundle) else {
            return nil
        }
        return Parsed(nodeId: nodeId, bundle: bundle)
    }

    /// A parsed code's two fields, exactly as the code wrote them.
    public struct Parsed: Sendable, Equatable {
        /// The node id's text.
        public let nodeId: String
        /// The bundle's text.
        public let bundle: String

        /// The node id, when the bundle's text derives to it, as `ContactCard.parseLegacy` checks
        /// (`ContactCard.kt:228-233`); `nil` for a code nobody's keys could have made.
        public var certifiedNodeId: NodeId? {
            let derived = NodeId(deriving: bundle)
            return derived.string.utf8.elementsEqual(nodeId.utf8) ? derived : nil
        }
    }
}
