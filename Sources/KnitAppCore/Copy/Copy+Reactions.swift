import Foundation

extension Copy {
    /// Reactions (ADR 2026-10.ehe6): the six in a bubble's menu, the chips under it, and what VoiceOver says of them. The
    /// emoji are never translated; VoiceOver reads each by its name.
    public enum Reactions {
        /// A bubble's VoiceOver action that reacts with `emoji`.
        public static func react(_ emoji: String) -> String {
            format(
                NSLocalizedString(
                    "reactions.react",
                    bundle: .main,
                    value: "React with %@",
                    comment: "Reactions: a VoiceOver action on a message; %@ is an emoji, which VoiceOver reads by name"
                ),
                emoji
            )
        }

        /// A bubble's VoiceOver action that takes back our `emoji` reaction.
        public static func remove(_ emoji: String) -> String {
            format(
                NSLocalizedString(
                    "reactions.remove",
                    bundle: .main,
                    value: "Remove your %@ reaction",
                    comment: "Reactions: a VoiceOver action that takes back the user's reaction; %@ is the emoji"
                ),
                emoji
            )
        }

        /// Who chose one chip's emoji: `count` people, us among them when `mine`.
        public static func chipValue(count: Int, mine: Bool) -> String {
            guard mine else {
                return Copy.count(
                    count,
                    one: NSLocalizedString(
                        "reactions.chip.people.one",
                        bundle: .main,
                        value: "%lld person",
                        comment: "Reactions: one person chose this emoji"
                    ),
                    other: NSLocalizedString(
                        "reactions.chip.people.other",
                        bundle: .main,
                        value: "%lld people",
                        comment: "Reactions: how many people chose this emoji; %lld is the count"
                    )
                )
            }
            guard count > 1 else {
                return NSLocalizedString(
                    "reactions.chip.you", bundle: .main, value: "You", comment: "Reactions: only the user chose this emoji")
            }
            return Copy.count(
                count - 1,
                one: NSLocalizedString(
                    "reactions.chip.you-and.one",
                    bundle: .main,
                    value: "You and %lld other",
                    comment: "Reactions: the user and one other person"
                ),
                other: NSLocalizedString(
                    "reactions.chip.you-and.other",
                    bundle: .main,
                    value: "You and %lld others",
                    comment: "Reactions: the user and others chose this emoji; %lld is how many others"
                )
            )
        }

        /// What a bubble's VoiceOver value adds for its reactions, `chips` already joined as "👍 You and 1 other, ❤️ 1 person".
        public static func summary(_ chips: String) -> String {
            format(
                NSLocalizedString(
                    "reactions.summary",
                    bundle: .main,
                    value: "Reactions: %@",
                    comment: "Reactions: a message's reactions for VoiceOver; %@ lists each emoji and who chose it"
                ),
                chips
            )
        }
    }
}
