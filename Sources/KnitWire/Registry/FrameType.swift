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
    /// An unsigned, point-to-point query for which of some blobs a neighbour holds (knit-next ADR 2026-10.6e5t).
    public static let blobHave = Self(rawValue: "blobhave")
    /// The answer to a ``blobHave``, sent back to the neighbour that asked.
    public static let blobHas = Self(rawValue: "blobhas")
    /// A file's receiver telling its sender how much of the file it holds (knit-next ADR 2026-10.nsr7): unsigned and point
    /// to point like a ``blobHave``.
    public static let blobProgress = Self(rawValue: "blobprog")
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

    /// Whether a frame of this type is the unsigned point-to-point blob traffic (`FrameType.isUnsignedPointToPoint`
    /// in `Wire.kt`): taken without a signature, so its sender id is a claim nobody checked. None of it is ever carried,
    /// parked, flooded or the cause of a key request.
    public var isUnsignedPointToPoint: Bool {
        self == .blobRequest || self == .blobHave || self == .blobHas || self == .blobProgress
    }
}
