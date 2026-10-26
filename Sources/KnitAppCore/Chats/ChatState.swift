public import KnitWire

/// What a thread is.
public enum ThreadKind: Sendable, Equatable {
    /// The Nearby room.
    case room
    /// A DM.
    case direct
    /// A group.
    case group
}

/// A thread, as one value.
public struct ChatState: Sendable, Equatable {
    /// The room's name, the peer's label, or the group's title.
    public var title: String
    /// What the thread is.
    public var kind: ThreadKind
    /// The DM's peer, or `nil` for the room and a group.
    public var peer: NodeId?
    /// The messages and status lines in reading order.
    public var messages: [ChatMessage]
    /// Whether this DM or group is a stranger's message request, which waits for Accept.
    public var isRequest: Bool
    /// What a request's bar says.
    public var requestTitle: String
    /// What accepting the request does.
    public var requestBody: String
    /// Whether the DM's peer is linked now.
    public var isLinked: Bool
    /// Whether the DM's peer is verified.
    public var isVerified: Bool
    /// How many people a group holds, us included; `nil` outside a group.
    public var memberCount: Int?
    /// Whether everyone else has left the group, so nothing can be sent.
    public var nobodyElse: Bool
    /// Whether the group is still ours: `false` once we left it, or for one we never held.
    public var exists: Bool
    /// The thread's face, beside its title: the room's, the peer's, or the group's.
    public var face = Face.room
    /// Whether the DM's peer is blocked: the thread shows only what we wrote, and Unblock in the composer's place
    /// (ADR 2026-10.5wgg).
    public var isBlocked = false
    /// Who is typing here now, in name order: the row at the thread's foot.
    public var typing: [Typist] = []

    /// Whether this is the room.
    public var isRoom: Bool { kind == .room }
    /// Whether this is a group.
    public var isGroup: Bool { kind == .group }
    /// Whether its messages take a reaction: wherever the composer is, so not on a request, a blocked person's DM or a
    /// group nobody else is left in (ADR 2026-10.ehe6).
    public var canReact: Bool { exists && !isRequest && !isBlocked && !nobodyElse }
    /// Whether its messages take a reply: wherever the composer is, as for a reaction (ADR 2026-10.mn29).
    public var canReply: Bool { canReact }
}
