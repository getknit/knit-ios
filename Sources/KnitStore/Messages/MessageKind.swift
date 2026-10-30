/// What a thread row is (`MessageEntity.kind`, `MessageEntity.kt:225-277`): an ordinary message, or a status line
/// this node wrote about an event, such as a member leaving a group.
///
/// The codes are knit-next's, and never leave this phone. Anything but ``message`` is a notice, including a code
/// this build has no words for, which a newer build may have written. Reading one never fails, because one row
/// that failed would empty a whole thread (ADR 2026-09.n393).
public struct MessageKind: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// An ordinary message (`KIND_NORMAL`).
    public static let message: Self = 0
    /// A member left a group by their own signed `groupleave` (`KIND_MEMBER_LEFT`).
    public static let memberLeft: Self = 1
    /// A member renamed a group; the row's body is the new name (`KIND_GROUP_RENAMED`).
    public static let groupRenamed: Self = 4
    /// A group was created (`KIND_GROUP_CREATED`).
    public static let groupCreated: Self = 6
    /// A member who left came back by a frame of their own (`KIND_MEMBER_REJOINED`).
    public static let memberRejoined: Self = 9

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }

    /// Whether the row is a status line rather than a message: never a preview, never acknowledged, and never what
    /// makes someone a sender in a thread (`isStatusNotice`).
    public var isNotice: Bool { self != .message }
}

/// What the content filter made of a message's words (`MessageEntity.moderation`, ADR 2026-10.e4kz): clear, flagged, or
/// not yet asked.
///
/// The first two codes are knit-next's, and none leaves this phone. Android classifies a message before it stores it,
/// so it never needs ``waiting``; here the engine stores someone else's message first, and the app screens it before it
/// shows or notifies it. A code this build does not know reads as ``clear``, as an unknown kind reads as a notice.
public struct MessageModeration: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// The words passed, or were never screened: our own, a status line, a message stored before v7, or one the model
    /// could not score (`MODERATION_NONE`).
    public static let clear: Self = 0
    /// The on-device text filter flagged the words (`MODERATION_TEXT_FLAGGED`).
    public static let flagged: Self = 1
    /// Someone else's words, stored and not yet screened. Nothing shows them while the filter is on.
    public static let waiting: Self = 2

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }
}
