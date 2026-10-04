import Foundation

extension Copy {
    /// The content filter (ADR 2026-10.rpmq): Settings' toggle, a photo it hides, and what picking an explicit photo
    /// asks or says. Android's `moderation_*` strings, for photos alone until messages are screened too.
    public enum Moderation {
        /// Settings' toggle.
        public static var filter: String {
            NSLocalizedString(
                "moderation.filter",
                bundle: .main,
                value: "Content filtering",
                comment: "Settings: the toggle that hides explicit photos other people send"
            )
        }

        /// What the toggle does, under it. It promises no more than the classifier gives.
        public static var filterFooter: String {
            NSLocalizedString(
                "moderation.filter.footer",
                bundle: .main,
                value: """
                    Explicit photos from other people stay hidden until you tap them, and an explicit profile photo shows as the \
                    person's initial. Knit checks each photo on this iPhone. It can miss one, or hide one that's fine.
                    """,
                comment: "Settings: what Content filtering does, and that it can be wrong"
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

        /// The title over both answers to an explicit photo picked: the DM's or group's question, and the room's refusal.
        public static var explicitTitle: String {
            NSLocalizedString(
                "moderation.explicit.title",
                bundle: .main,
                value: "This photo looks explicit",
                comment: "Chat: a photo just picked looks explicit"
            )
        }

        /// The question a DM or a group asks before an explicit photo goes in the composer.
        public static var explicitAsk: String {
            NSLocalizedString(
                "moderation.explicit.ask",
                bundle: .main,
                value: "Send it only if whoever you're sending it to wants photos like this.",
                comment: "Chat, in a DM or a group: before an explicit-looking photo is added"
            )
        }

        /// The button that adds the photo anyway.
        public static var sendAnyway: String {
            NSLocalizedString(
                "moderation.explicit.send",
                bundle: .main,
                value: "Send anyway",
                comment: "Chat: adds an explicit-looking photo to the message after all"
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
