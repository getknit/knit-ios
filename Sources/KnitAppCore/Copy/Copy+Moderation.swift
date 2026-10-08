import Foundation

extension Copy {
    /// The content filter (ADR 2026-10.rpmq, ADR 2026-10.e4kz): Settings' toggle, a photo or a message it hides, what
    /// picking an explicit photo asks or says, and why a message was not sent. Android's `moderation_*` strings.
    public enum Moderation {
        /// Settings' toggle.
        public static var filter: String {
            NSLocalizedString(
                "moderation.filter",
                bundle: .main,
                value: "Content filtering",
                comment: "Settings: the toggle that hides explicit photos and abusive messages other people send"
            )
        }

        /// What the toggle does, short, under it; ``filterInfo`` holds the rest. It promises no more than the classifier
        /// gives.
        public static var filterFooter: String {
            NSLocalizedString(
                "moderation.filter.footer.short",
                bundle: .main,
                value: "Explicit photos and abusive messages from other people stay hidden until you tap them.",
                comment: "Settings: what Content filtering does"
            )
        }

        /// The info button beside the toggle, and the title of the sheet it opens.
        public static var filterInfo: String {
            NSLocalizedString(
                "moderation.filter.info",
                bundle: .main,
                value: "About content filtering",
                comment: "Settings: the info button beside Content filtering, and the title of the sheet it opens"
            )
        }

        /// The sheet's first point: where the checking happens.
        public static var filterOnDevice: String {
            NSLocalizedString(
                "moderation.filter.on-device",
                bundle: .main,
                value: "Knit checks photos and messages on this iPhone.",
                comment: "Content filtering: the check runs on the phone"
            )
        }

        /// The sheet's second point: what happens to an explicit profile photo.
        public static var filterProfilePhoto: String {
            NSLocalizedString(
                "moderation.filter.profile-photo",
                bundle: .main,
                value: "An explicit profile photo shows as the person's initial.",
                comment: "Content filtering: an explicit profile photo is replaced by an initial"
            )
        }

        /// The sheet's third point: that it can be wrong.
        public static var filterMistakes: String {
            NSLocalizedString(
                "moderation.filter.mistakes",
                bundle: .main,
                value: "The filter can miss some, or hide some that are fine.",
                comment: "Content filtering: it can miss explicit content or hide content that is fine"
            )
        }

        /// What a hidden photo's bubble says until it is tapped.
        public static var hiddenPhoto: String {
            NSLocalizedString(
                "moderation.photo.hidden",
                bundle: .main,
                value: "Sensitive photo. Tap to show.",
                comment: "Chat: in place of a photo the content filter hides"
            )
        }

        /// What VoiceOver says of a message whose photo is hidden, after its words: Android's "Message hidden by content
        /// filtering", for a photo.
        public static var hiddenPhotoValue: String {
            NSLocalizedString(
                "moderation.photo.hidden.value",
                bundle: .main,
                value: "Photo hidden by content filtering",
                comment: "Chat: VoiceOver's description of a message whose photo the content filter hides"
            )
        }

        /// VoiceOver's action that shows a hidden photo.
        public static var showPhoto: String {
            NSLocalizedString(
                "moderation.photo.show",
                bundle: .main,
                value: "Show photo",
                comment: "Chat: VoiceOver's action that shows a photo the content filter hid"
            )
        }

        /// What a hidden message's bubble says in place of its words until it is tapped.
        public static var hiddenWords: String {
            NSLocalizedString(
                "moderation.message.hidden",
                bundle: .main,
                value: "Message hidden. Tap to show.",
                comment: "Chat: in place of a message's words that the content filter hides"
            )
        }

        /// A hidden message's line in the chat list and in a notification, and what VoiceOver says of its bubble.
        public static var hiddenMessage: String {
            NSLocalizedString(
                "moderation.message.hidden.line",
                bundle: .main,
                value: "Message hidden by content filtering",
                comment: "Chat list, notifications and VoiceOver: a message whose words the content filter hides"
            )
        }

        /// VoiceOver's action that shows a hidden message's words.
        public static var showMessage: String {
            NSLocalizedString(
                "moderation.message.show",
                bundle: .main,
                value: "Show message",
                comment: "Chat: VoiceOver's action that shows a message the content filter hid"
            )
        }

        /// What a message's bubble says in the moment before the filter has read words that just arrived.
        public static var checkingMessage: String {
            NSLocalizedString(
                "moderation.message.checking",
                bundle: .main,
                value: "Checking message…",
                comment: "Chat: a message that just arrived, before the content filter has read it"
            )
        }

        /// The title over the alert that says a message was not sent.
        public static var wordsRefusedTitle: String {
            NSLocalizedString(
                "moderation.refused.title",
                bundle: .main,
                value: "Message not sent",
                comment: "Chat: a message the content filter stopped from being sent"
            )
        }

        /// Why Nearby did not post a message, and that it is still in the composer.
        public static var wordsRefusedInRoom: String {
            NSLocalizedString(
                "moderation.refused.room",
                bundle: .main,
                value: """
                    Everyone in range can see Nearby, so Knit won't post profanity or abuse there. Your message is still there \
                    if you want to change it.
                    """,
                comment: "Chat, in Nearby: a message with profanity or abuse was not posted"
            )
        }

        /// The title over the room's refusal of an explicit photo.
        public static var explicitTitle: String {
            NSLocalizedString(
                "moderation.explicit.title",
                bundle: .main,
                value: "This photo looks explicit",
                comment: "Chat: a photo just picked looks explicit"
            )
        }

        /// Why a profile refused an explicit photo, under the photo (ADR 2026-10.spcy).
        public static var profileRefusal: String {
            NSLocalizedString(
                "moderation.explicit.profile",
                bundle: .main,
                value: "Everyone nearby sees your profile photo, so Knit won't use a photo like this one.",
                comment: "Own profile: an explicit-looking profile photo is refused"
            )
        }

        /// Why the room refuses an explicit photo, and where it can go instead.
        public static var roomRefusal: String {
            NSLocalizedString(
                "moderation.explicit.room",
                bundle: .main,
                value: """
                    Everyone in range can see Nearby, so Knit won't post photos like this there. You can still send it in a direct \
                    message or a group.
                    """,
                comment: "Chat, in Nearby: an explicit-looking photo is refused"
            )
        }
    }
}
