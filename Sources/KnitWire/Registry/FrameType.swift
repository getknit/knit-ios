/// A frame's type string (`FrameType` in knit-next's `Wire.kt`).
///
/// Types are strings, not numbers, so a type this build has never heard of still decodes, relays and is
/// carried where custodial. The registry only grows, and a retired value is never reused: `meshpost` is
/// burned.
public struct FrameType: RawRepresentable, Hashable, Sendable {
    /// A chat message: a DM, a group message or a Nearby room post, by its addressing.
    public static let chat = Self(rawValue: "chat")
    /// A group roster change.
    public static let groupUpdate = Self(rawValue: "groupupdate")
    /// A member leaving a group, signed by that member.
    public static let groupLeave = Self(rawValue: "groupleave")
    /// A profile: name, status, public key bundle and capabilities.
    public static let profile = Self(rawValue: "profile")
    /// A cleartext delivery receipt.
    public static let receipt = Self(rawValue: "receipt")
    /// A cleartext reaction.
    public static let reaction = Self(rawValue: "reaction")
    /// An unsigned, point-to-point request for a blob.
    public static let blobRequest = Self(rawValue: "blobreq")
    /// A point-to-point request for missing profiles.
    public static let keyRequest = Self(rawValue: "keyreq")
    /// A one-hop typing cue, never carried.
    public static let typing = Self(rawValue: "typing")
    /// A post in a spool relay's commons room; not custodial, and never delivered from a radio.
    public static let commons = Self(rawValue: "commons")

    /// The raw type string.
    public let rawValue: String

    /// Wraps a type string, known or not.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether a frame of this type is parked for replay when its sender's key is missing: the locally
    /// delivered types (`FrameType.isReplayable`).
    public var isReplayable: Bool {
        self == .chat || self == .reaction || self == .receipt || self == .groupUpdate || self == .groupLeave
    }

    /// Whether a frame of this type is carried for store-and-forward (`FrameType.isCustodial`).
    ///
    /// This list is cross-platform law: adding a type here is a flag day across the whole fleet, never an
    /// additive change (`docs/WIRE_COMPAT.md` in knit-next).
    public var isCustodial: Bool { isReplayable || self == .profile }
}
