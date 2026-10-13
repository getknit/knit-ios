public import KnitWire

/// Someone typing in a thread, as the row at its foot shows them (`TypingPeer` in knit-next's `ChatViewModel`).
public struct Typist: Sendable, Equatable, Identifiable {
    /// Who.
    public var nodeId: NodeId
    /// Their label, collision-aware, as their messages show it.
    public var name: String
    /// Their face.
    public var face: Face

    /// The row's identity: who it is.
    public var id: NodeId { nodeId }
}

extension ChatState {
    /// What VoiceOver reads for the row at the thread's foot, or `nil` while nobody is typing: the first typist by name,
    /// and whether others are typing too, as Android's `chat_typing` and `chat_typing_multiple` say it.
    public var typingLabel: String? {
        typing.first.map { first in typing.count == 1 ? Copy.Typing.one(first.name) : Copy.Typing.many(first.name) }
    }
}

/// Who a thread shows typing (`ChatViewModel.kt:1152-1160`).
internal enum Typists {
    /// Of `typing`, the people the thread shows: not us, nobody blocked, and only someone its `audience` takes, so a DM
    /// shows its peer, a group its roster and the room anyone, as reactions show them (ADR 2026-10.ehe6). Each is named
    /// as their messages are, and they come in name order, case aside, as Android sorts them.
    static func shown(_ typing: [NodeId], me: NodeId, audience: ReactionAudience, directory: Directory) -> [Typist] {
        typing
            .filter { $0 != me && audience.shows($0, blocked: directory.blocked) }
            .map { Typist(nodeId: $0, name: directory.label(for: $0).text, face: directory.face(for: $0)) }
            .sorted { ($0.name.lowercased(), $0.nodeId) < ($1.name.lowercased(), $1.nodeId) }
    }
}
