import KnitStore
public import KnitWire

/// The emoji a message's menu offers (ADR 2026-10.ehe6): Android's original six, in its order, ❤️ with the variation
/// selector as Android spells it (`RecentReactions.DEFAULTS`). Any emoji another phone sends still shows as a chip.
public enum ReactionChoices {
    /// 👍 ❤️ 😂 😮 😢 🙏, never translated.
    public static let six = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]
}

/// One emoji under a message: how many people chose it, and whether we are one of them (`ReactionSummary` in knit-next).
public struct ReactionChip: Sendable, Equatable, Identifiable {
    /// The emoji.
    public var emoji: String
    /// How many people chose it.
    public var count: Int
    /// Whether we are one of them, so a tap takes ours back.
    public var mine: Bool

    /// The emoji by its bytes, which is how chips are told apart.
    public var id: ExactKey { ExactKey(emoji) }
}

/// Whose reactions a thread shows (ADR 2026-10.ehe6). The frame names no thread, so anyone who saw a message's frame
/// id could react to it: a DM shows its two people's, a group its founding roster's, and Nearby anyone's. Blocked people's
/// are hidden everywhere and come back on unblock, as their messages do. Android shows them all.
internal enum ReactionAudience {
    /// Nearby: anyone not blocked.
    case anyone
    /// A DM or a group: these people, less the blocked.
    case only(Set<NodeId>)

    /// Whose reactions `thread` shows.
    static func of(_ thread: String, kind: ThreadKind, group: GroupRecord?, me: NodeId) -> Self {
        switch kind {
        case .room:
            .anyone
        case .direct:
            .only(Set([me] + [NodeId(thread)].compactMap(\.self)))
        case .group:
            .only(Set([me] + (group?.roster ?? []).compactMap { NodeId($0.nodeId) }))
        }
    }

    /// Whether `reactor`'s reactions show, given who is `blocked`.
    func shows(_ reactor: NodeId, blocked: Set<NodeId>) -> Bool {
        guard !blocked.contains(reactor) else {
            return false
        }
        switch self {
        case .anyone:
            return true
        case .only(let people):
            return people.contains(reactor)
        }
    }
}

/// A thread's chips, message by message.
internal enum ReactionChips {
    /// The chips each message shows, keyed by its id's bytes, from `reactions` oldest first: only those `audience` shows,
    /// one chip per emoji by its bytes, each where its emoji first appeared (`ChatViewModel.kt:947-985`).
    static func chips(
        _ reactions: [ReactionRecord], me: NodeId, audience: ReactionAudience, blocked: Set<NodeId>
    ) -> [ExactKey: [ReactionChip]] {
        var chips: [ExactKey: [ReactionChip]] = [:]
        for reaction in reactions where audience.shows(reaction.reactor, blocked: blocked) {
            guard let emoji = reaction.emoji else {
                continue
            }
            let mine = reaction.reactor == me
            let message = ExactKey(reaction.messageId)
            var row = chips[message, default: []]
            if let index = row.firstIndex(where: { $0.id == ExactKey(emoji) }) {
                row[index].count += 1
                row[index].mine = row[index].mine || mine
            } else {
                row.append(ReactionChip(emoji: emoji, count: 1, mine: mine))
            }
            chips[message] = row
        }
        return chips
    }
}

extension ChatMessage {
    /// Whether our reaction to it is `emoji`, compared by its bytes: the picker shows it chosen, and choosing it again
    /// takes it back.
    public func isOurReaction(_ emoji: String) -> Bool {
        reactions.contains { $0.mine && $0.id == ExactKey(emoji) }
    }

    /// What VoiceOver hears of its reactions, or `nil` for none: each emoji, and who chose it.
    public var reactionSummary: String? {
        guard !reactions.isEmpty else {
            return nil
        }
        return Copy.Reactions.summary(
            reactions.map { "\($0.emoji) \(Copy.Reactions.chipValue(count: $0.count, mine: $0.mine))" }.joined(separator: ", "))
    }
}
