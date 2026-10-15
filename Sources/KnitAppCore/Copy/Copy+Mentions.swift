import Foundation

extension Copy {
    /// Mentions (ADR 2026-10.nbhj): what VoiceOver says of the people an "@" in the composer offers. Android says nothing
    /// here; the picker's rows read as each person's label, which is never localized.
    public enum Mentions {
        /// The picker's label, above the composer.
        public static var picker: String {
            NSLocalizedString(
                "mentions.picker",
                bundle: .main,
                value: "People to mention",
                comment: "Composer: VoiceOver label of the list of people an @ offers to mention"
            )
        }

        /// What VoiceOver says as the picker opens, since the keyboard keeps the focus: how many people it offers.
        public static func offered(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString(
                    "mentions.offered.one",
                    bundle: .main,
                    value: "%lld person to mention",
                    comment: "Composer: VoiceOver announcement as the list of people to mention opens; a count"
                ),
                other: NSLocalizedString(
                    "mentions.offered.other",
                    bundle: .main,
                    value: "%lld people to mention",
                    comment: "Composer: VoiceOver announcement as the list of people to mention opens; a count"
                )
            )
        }

        /// The `@everyone` row's line under its title, in a group's picker (ADR 2026-10.jwst). The title is the token itself,
        /// "@everyone", which is never localized: the sender's body keeps it as written.
        public static var everyoneNote: String {
            NSLocalizedString(
                "mentions.everyone.note",
                bundle: .main,
                value: "Notifies everyone else in the group",
                comment: "Composer: the line under the @everyone row of the people an @ offers in a group"
            )
        }

        /// What VoiceOver reads for the `@everyone` row.
        public static var everyone: String {
            NSLocalizedString(
                "mentions.everyone",
                bundle: .main,
                value: "Mention everyone. Notifies everyone else in the group",
                comment: "Composer: VoiceOver label of the @everyone row of the people an @ offers in a group"
            )
        }
    }
}
