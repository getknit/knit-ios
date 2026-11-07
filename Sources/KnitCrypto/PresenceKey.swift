/// A contact's presence key: the 32 bytes its blinded Bluetooth advert's tag is a MAC under (``BlindTag``; knit-next ADR
/// 2026-11.xp6d, "The presence key"; ADR 2026-11.sv5t). It reaches this port only in a ctl 11 a ratchet open accepted
/// (`PresenceKeyPayload`), filed under that frame's signed sender; this port mints none of its own (receive only, ADR
/// 2026-11.sv5t).
///
/// Whoever holds it can recognise its owner's adverts and forge its presence, so it is a secret: its `description`,
/// `debugDescription` and mirror show its length only, never a byte, so neither a log line, `dump` nor a failed
/// `#expect` prints one (knit-next ADR 2026-11.xp6d, "Logging"; `PresenceKeyPayload.toString`, `Wire.kt:846-847` at
/// knit-next `cad69c77b`).
public struct PresenceKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A presence key's length (`BlindTag.KEY_BYTES`, `BlindTag.kt:76`).
    public static let byteCount = 32

    /// The raw key, for the store and the tag's MAC alone. Never log it.
    public let bytes: [UInt8]

    /// The key for `bytes`, or `nil` unless they are exactly ``byteCount`` long: a peer delivered them, so a wrong length
    /// is a value to refuse, never a trap.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        self.bytes = bytes
    }

    /// Its length only.
    public var description: String { "PresenceKey(\(Self.byteCount) bytes)" }

    /// Its length only, as ``description``.
    public var debugDescription: String { description }

    /// No children, so reflection shows no byte.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
