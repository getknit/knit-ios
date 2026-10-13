import Foundation

extension Copy {
    /// Quoted replies (ADR 2026-10.mn29): Reply in a bubble's menu, the composer's bar, the quote above a reply's words,
    /// and what VoiceOver says of them (`chat_action_reply` and `chat_reply_cancel` in knit-next).
    public enum Replies {
        /// A bubble's menu item and VoiceOver action that starts a reply to it.
        public static var reply: String {
            NSLocalizedString("replies.reply", bundle: .main, value: "Reply", comment: "Message menu: starts a reply to this message")
        }

        /// The composer's bar's button that puts the quote away.
        public static var cancel: String {
            NSLocalizedString(
                "replies.cancel",
                bundle: .main,
                value: "Cancel reply",
                comment: "Composer: the button on the reply bar that stops replying"
            )
        }

        /// What VoiceOver reads for the composer's bar: whom the reply quotes, and what, when there is anything to show.
        public static func replying(to author: String, line: String?) -> String {
            guard let line else {
                return format(
                    NSLocalizedString(
                        "replies.composer.label.author",
                        bundle: .main,
                        value: "Replying to %@",
                        comment: "Composer: VoiceOver label of the reply bar; %@ is who wrote the quoted message"
                    ),
                    author
                )
            }
            return format(
                NSLocalizedString(
                    "replies.composer.label",
                    bundle: .main,
                    value: "Replying to %1$@: %2$@",
                    comment: "Composer: VoiceOver label of the reply bar; %1$@ is who wrote the quoted message, %2$@ its words"
                ),
                author,
                line
            )
        }

        /// What VoiceOver reads for the quote in a reply: whom it quotes, and what, when there is anything to show.
        public static func quote(_ author: String, line: String?) -> String {
            guard let line else {
                return format(
                    NSLocalizedString(
                        "replies.quote.label.author",
                        bundle: .main,
                        value: "In reply to %@",
                        comment: "Thread: VoiceOver label of the quote above a reply; %@ is who wrote the quoted message"
                    ),
                    author
                )
            }
            return format(
                NSLocalizedString(
                    "replies.quote.label",
                    bundle: .main,
                    value: "In reply to %1$@: %2$@",
                    comment: "Thread: VoiceOver label of the quote above a reply; %1$@ is who wrote the quoted message, %2$@ its words"
                ),
                author,
                line
            )
        }

        /// A reply's VoiceOver action, and its quote's hint, that takes the thread to the quoted message.
        public static var showOriginal: String {
            NSLocalizedString(
                "replies.quote.show",
                bundle: .main,
                value: "Show original message",
                comment: "Thread: VoiceOver action that scrolls to the message a reply quotes"
            )
        }

        /// The line a quote shows in place of the words of someone the user blocked.
        public static var blockedQuote: String {
            NSLocalizedString(
                "replies.quote.blocked",
                bundle: .main,
                value: "Hidden because you blocked them",
                comment: "Thread: in a quote, in place of the words of someone the user blocked"
            )
        }
    }
}

extension Copy.Report {
    /// Under a reported reply's words, what it quoted.
    public static func emailQuote(_ author: String, _ words: String) -> String {
        Copy.format(
            NSLocalizedString(
                "report.email.quote",
                bundle: .main,
                value: "It was a reply to %1$@: %2$@",
                comment: "Report email: under the words of a message that replied to another; %1$@ is who wrote that one, %2$@ its words"
            ),
            author,
            words
        )
    }
}
