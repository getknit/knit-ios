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
    }
}
