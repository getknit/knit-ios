import Foundation

extension Copy {
    /// A link's preview card in a thread (knit-next's "Link previews" strings, ADR 2026-11.hcvg).
    public enum LinkPreviews {
        /// A card for VoiceOver: the page's title and the site it is on (`chat_link_card_desc`).
        public static func card(title: String, host: String) -> String {
            format(
                NSLocalizedString(
                    "linkPreviews.card",
                    bundle: .main,
                    value: "Link preview: %1$@, %2$@",
                    comment: "Chat: VoiceOver's name for a link's preview card; %1$@ is the page's title, %2$@ the site's address"
                ),
                title,
                host
            )
        }

        /// What a hidden card says until it is tapped (`moderation_link_hidden`).
        public static var hidden: String {
            NSLocalizedString(
                "linkPreviews.hidden",
                bundle: .main,
                value: "Sensitive preview. Tap to show.",
                comment: "Chat: in place of a link's preview card that the content filter hides"
            )
        }

        /// What VoiceOver says of a message whose card is hidden, after its words.
        public static var hiddenValue: String {
            NSLocalizedString(
                "linkPreviews.hidden.value",
                bundle: .main,
                value: "Link preview hidden by content filtering",
                comment: "Chat: VoiceOver's description of a message whose link preview the content filter hides"
            )
        }

        /// VoiceOver's action that shows a hidden card.
        public static var show: String {
            NSLocalizedString(
                "linkPreviews.show",
                bundle: .main,
                value: "Show link preview",
                comment: "Chat: VoiceOver's action that shows a link's preview card the content filter hid"
            )
        }
    }
}
