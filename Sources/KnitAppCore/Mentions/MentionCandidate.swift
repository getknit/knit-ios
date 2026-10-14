public import KnitStore
import KnitWire

/// Someone the composer offers to mention (`MentionCandidate` in knit-next's `ChatViewModel.kt`): their label, which a
/// pick writes after the "@", and their face for the picker's row.
public struct MentionCandidate: Sendable, Equatable, Identifiable {
    /// Their collision-aware label: the name, or "Name (alias words)" when another known person shares it.
    public var label: PeerLabel
    /// Their face.
    public var face: Face

    /// A candidate.
    public init(label: PeerLabel, face: Face) {
        self.label = label
        self.face = face
    }

    /// Their node id.
    public var id: String {
        label.nodeId
    }

    /// The mention a pick of them adds: their node id, and their label as the text after the "@", as Android writes
    /// `resolved.text` (knit-next ADR 058). A quote names its author by the plain name instead (ADR 2026-10.mn29).
    public var mention: MessageMention {
        MessageMention(nodeId: label.nodeId, name: label.text)
    }
}

extension MentionCandidate {
    /// The people a thread offers (`mentionCandidates`, `ChatViewModel.kt:1131-1148`): everyone who wrote a message in it
    /// (`senders`, which a store reads from every row, not the window a screen holds), and a group's members, so a
    /// group's people can be mentioned before they speak. We and the people blocked are left out, and the rest go in the
    /// order of their labels, lowercased, then their node ids. A DM offers its peer once they have written in it, as on
    /// Android.
    static func offered(senders: Set<NodeId>, members: [String], directory: Directory) -> [Self] {
        let people = senders.union(members.compactMap(NodeId.init))
        return
            people
            .filter { $0 != directory.me && !directory.blocked.contains($0) }
            .map { Self(label: directory.label(for: $0), face: directory.face(for: $0)) }
            .sorted { ($0.label.text.lowercased(), $0.label.nodeId) < ($1.label.text.lowercased(), $1.label.nodeId) }
    }
}
