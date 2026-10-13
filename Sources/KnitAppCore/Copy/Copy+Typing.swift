import Foundation

extension Copy {
    /// Someone typing in a thread (`chat_typing` and `chat_typing_multiple` in knit-next). The row shows faces and a
    /// moving stitch and no words, so these are what VoiceOver reads for it.
    public enum Typing {
        /// One person, `name`, is typing.
        public static func one(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "typing.one",
                    bundle: .main,
                    value: "%@ is typing",
                    comment: "Typing: the spoken label of the row that shows someone typing; %@ is their name"
                ),
                name
            )
        }

        /// More than one person is typing, `name` first by name.
        public static func many(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "typing.many",
                    bundle: .main,
                    value: "%@ and others are typing",
                    comment: "Typing: the spoken label of the row while several people type; %@ is the first one's name"
                ),
                name
            )
        }
    }
}
