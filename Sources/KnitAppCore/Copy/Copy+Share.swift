import Foundation

extension Copy {
    /// Sharing to Knit from another app (ADR 2026-10.z7a8).
    public enum Share {
        /// The notification's words when a share did not go, by why. Its title is the chat's.
        public static func held(_ refusal: ShareManifest.Refusal) -> String {
            switch refusal {
            case .words:
                NSLocalizedString(
                    "share.held.words",
                    bundle: .main,
                    value: "Knit didn't post your share to Nearby, which everyone in range can see. It's waiting in the chat.",
                    comment: "Notification: a shared message with profanity or abuse was not posted in Nearby"
                )
            case .explicitPhoto:
                NSLocalizedString(
                    "share.held.explicit",
                    bundle: .main,
                    value: "Knit didn't post your photo to Nearby because it looks explicit. It's waiting in the chat.",
                    comment: "Notification: a shared photo that looks explicit was not posted in Nearby"
                )
            case .unreadablePhoto:
                NSLocalizedString(
                    "share.held.unreadable",
                    bundle: .main,
                    value: "Knit couldn't open the photo you shared. Your words are waiting in the chat.",
                    comment: "Notification: a shared photo could not be read, so the share did not go"
                )
            case .photoTooLarge:
                NSLocalizedString(
                    "share.held.too-large",
                    bundle: .main,
                    value: "The photo you shared is too large to send. Your words are waiting in the chat.",
                    comment: "Notification: a shared photo was too large to send, so the share did not go"
                )
            case .closed:
                NSLocalizedString(
                    "share.held.closed",
                    bundle: .main,
                    value: "This chat can't take messages right now, so your share is waiting in it.",
                    comment: "Notification: a share went to a chat that is blocked, left or a request"
                )
            }
        }
    }
}
