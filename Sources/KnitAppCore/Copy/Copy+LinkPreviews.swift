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

        /// What the composer says while it fetches the draft's card (`chat_link_preview_loading`).
        public static var loading: String {
            NSLocalizedString(
                "linkPreviews.loading",
                bundle: .main,
                value: "Loading preview…",
                comment: "Chat composer: shown while Knit fetches a preview card for the link in the draft"
            )
        }

        /// The card held in the composer, for VoiceOver (`chat_link_staged_desc`).
        public static func staged(title: String, host: String) -> String {
            format(
                NSLocalizedString(
                    "linkPreviews.staged",
                    bundle: .main,
                    value: "Link preview: %1$@, %2$@. Sends with your message.",
                    comment: "Chat composer: VoiceOver's name for the preview card held for Send; %1$@ is the page's title, %2$@ the site"
                ),
                title,
                host
            )
        }

        /// The composer's cross on the card it holds.
        public static var remove: String {
            NSLocalizedString(
                "linkPreviews.remove",
                bundle: .main,
                value: "Send without preview",
                comment: "Chat composer: removes the preview card so the message goes with the link alone"
            )
        }

        /// The setting's name (`settings_link_previews_title`).
        public static var settingTitle: String {
            NSLocalizedString(
                "linkPreviews.setting.title", bundle: .main, value: "Link previews", comment: "Settings: the link previews toggle")
        }

        /// What the setting does, and who learns what when it is on (`settings_link_previews_subtitle`).
        public static var settingFooter: String {
            NSLocalizedString(
                "linkPreviews.setting.footer",
                bundle: .main,
                value: """
                    When your message has a link, Knit fetches the page's title, description and picture over the Internet \
                    and sends them along, so the people you send it to see a preview without contacting the site. The site \
                    sees your IP address.
                    """,
                comment: "Settings: below the link previews toggle; says the site sees the sender's IP address"
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
