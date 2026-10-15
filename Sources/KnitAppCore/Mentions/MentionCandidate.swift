public import KnitStore
import KnitWire

/// Someone the composer offers to mention (`MentionCandidate` in knit-next's `ChatViewModel.kt`): their label, which a
/// pick writes after the "@", and their face for the picker's row.
public struct MentionCandidate: Sendable, Equatable, Identifiable {
    /// Their collision-aware label: the name, or "Name (alias words)" when another known person shares it.
    public var label: PeerLabel
    /// Their face.
    public var face: Face
    /// For the `@everyone` row, the node ids it mentions, in ascending order; `nil` for a person.
    public var everyone: [String]?

    /// A candidate.
    public init(label: PeerLabel, face: Face) {
        self.label = label
        self.face = face
    }

    /// The `@everyone` row of a group (ADR 2026-10.jwst): one mention for each of `members`, which the caller has
    /// already cleared of us and the blocked.
    init(everyone members: [String]) {
        self.label = PeerLabel(nodeId: Self.everyoneName, name: Self.everyoneName, alias: Self.everyoneName, discriminator: nil)
        self.face = .room
        self.everyone = members.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// The token after the "@" and the name of every mention the row writes. ASCII and never localized: the name is
    /// frozen in the sender's body.
    public static let everyoneName = "everyone"

    /// Whether this is the `@everyone` row.
    public var isEveryone: Bool {
        everyone != nil
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

    /// Every mention a pick adds: the person's own, or one `everyone` for each member the row stands for.
    public var mentions: [MessageMention] {
        everyone.map { $0.map { MessageMention(nodeId: $0, name: Self.everyoneName) } } ?? [mention]
    }
}

extension MentionCandidate {
    /// The people a thread offers (`mentionCandidates`, `ChatViewModel.kt:1131-1148`): everyone who wrote a message in it
    /// (`senders`, which a store reads from every row, not the window a screen holds), and a group's members, so a
    /// group's people can be mentioned before they speak. We and the people blocked are left out, and the rest go in the
    /// order of their labels, lowercased, then their node ids. A DM offers its peer once they have written in it, as on
    /// Android. A group's list starts with the `@everyone` row, unless its roster holds nobody but us and the blocked;
    /// `isGroup` says whether the thread is one, and the row reads the roster alone, not the senders.
    static func offered(senders: Set<NodeId>, members: [String], isGroup: Bool, directory: Directory) -> [Self] {
        let roster = members.compactMap(NodeId.init)
        let people = senders.union(roster)
        let list =
            people
            .filter { $0 != directory.me && !directory.blocked.contains($0) }
            .map { Self(label: directory.label(for: $0), face: directory.face(for: $0)) }
            .sorted { ($0.label.text.lowercased(), $0.label.nodeId) < ($1.label.text.lowercased(), $1.label.nodeId) }
        guard isGroup else {
            return list
        }
        let everyone = Set(roster).filter { $0 != directory.me && !directory.blocked.contains($0) }.map(\.string)
        return everyone.isEmpty ? list : [Self(everyone: everyone)] + list
    }
}
