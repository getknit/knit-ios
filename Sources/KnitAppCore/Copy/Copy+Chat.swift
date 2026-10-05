import Foundation

extension Copy {
    /// A thread: the room or a DM.
    public enum Chat {
        /// The room with nothing in it yet.
        public static var roomEmpty: String {
            NSLocalizedString(
                "chat.room.empty",
                bundle: .main,
                value: "No messages yet. Say hello to people nearby.",
                comment: "Chat: the empty room"
            )
        }

        /// The bubble menu's action that copies a message's words.
        public static var copy: String {
            NSLocalizedString(
                "chat.copy", bundle: .main, value: "Copy", comment: "Chat: the bubble menu's action that copies the message's words")
        }

        /// A DM with nothing in it yet.
        public static func directEmpty(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "chat.direct.empty",
                    bundle: .main,
                    value: "Messages and photos between you and %@ are end-to-end encrypted.",
                    comment: "Chat: an empty DM; %@ is the other person's name"
                ),
                name
            )
        }

        /// What the room is, said once at its top.
        public static var roomNotice: String {
            NSLocalizedString(
                "chat.room.notice",
                bundle: .main,
                value: """
                    Posts and photos here are public. Everyone in range can see them, and phones pass them on to newcomers for up to 6 \
                    hours.
                    """,
                comment: "Chat: the room's notice; 6 hours is how long phones carry room posts"
            )
        }

        /// The composer's placeholder.
        public static var composerPlaceholder: String {
            NSLocalizedString("chat.composer.placeholder", bundle: .main, value: "Message", comment: "Chat: the composer's placeholder")
        }

        /// The send button.
        public static var send: String {
            NSLocalizedString("chat.send", bundle: .main, value: "Send", comment: "Chat: the send button")
        }

        /// The send button while a tap on it is still being handled, for VoiceOver: the words are checked, then stored.
        public static var sending: String {
            NSLocalizedString(
                "chat.sending",
                bundle: .main,
                value: "Sending…",
                comment: "Chat: the send button while a message is on its way"
            )
        }

        /// How much room the message has left, shown as it nears the limit.
        public static func remaining(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString(
                    "chat.remaining.one",
                    bundle: .main,
                    value: "%lld character left",
                    comment: "Chat: one character left"
                ),
                other: NSLocalizedString(
                    "chat.remaining.other",
                    bundle: .main,
                    value: "%lld characters left",
                    comment: "Chat: characters left; a count"
                )
            )
        }

        /// The DM header's button that opens the peer's profile.
        public static var profile: String {
            NSLocalizedString(
                "chat.profile",
                bundle: .main,
                value: "Profile",
                comment: "Chat: the header button that opens the other person's profile"
            )
        }

        /// A DM's peer is linked now.
        public static var inRange: String {
            NSLocalizedString(
                "chat.in-range",
                bundle: .main,
                value: "In range",
                comment: "Chat header: the other person's phone is linked now"
            )
        }

        /// A DM's peer is not linked now; messages still travel through other phones.
        public static var outOfRange: String {
            NSLocalizedString(
                "chat.out-of-range",
                bundle: .main,
                value: "Not in range. Messages travel through phones in between.",
                comment: "Chat header: the other person's phone is not linked now"
            )
        }

        /// The round button over a thread scrolled up, which jumps back to its newest message, for a screen reader.
        public static var scrollToNewest: String {
            NSLocalizedString(
                "chat.scroll-to-newest",
                bundle: .main,
                value: "Scroll to newest message",
                comment: "Chat: spoken label of the round button that jumps back to the newest message"
            )
        }

        /// The encryption badge, for a screen reader.
        public static var encrypted: String {
            NSLocalizedString(
                "chat.encrypted",
                bundle: .main,
                value: "End-to-end encrypted",
                comment: "Chat: spoken label of the lock badge"
            )
        }

        /// The encryption sheet: whom encryption covers, what travels unencrypted (ADR 2026-10.ehe6), and the one limit
        /// v1 has (ADR 2026-09.qsd9).
        public static func encryptionBody(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "chat.encryption.body",
                    bundle: .main,
                    value: """
                        Only you and %@ can read this chat or see its photos. Messages and photos are sealed before they leave your phone, \
                        so the phones that carry them can't open them. Reactions travel unencrypted: those phones can see who reacted to a \
                        message and with which emoji, but not what the message says. This version doesn't have forward secrecy yet: anyone \
                        who later gets the keys from either phone could open what they recorded earlier.
                        """,
                    comment: "Chat: what DM encryption covers; %@ is the other person's name"
                ),
                name
            )
        }

        /// A stranger's first DM.
        public static func requestTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "chat.request.title",
                    bundle: .main,
                    value: "%@ wants to message you",
                    comment: "Chat: a message request; %@ is a name"
                ),
                name
            )
        }

        /// What accepting a request does.
        public static var requestBody: String {
            NSLocalizedString(
                "chat.request.body",
                bundle: .main,
                value: "Accept to move this chat to your list and get notified when they write.",
                comment: "Chat: what accepting a message request does"
            )
        }

        /// The button that accepts a request.
        public static var accept: String {
            NSLocalizedString("chat.accept", bundle: .main, value: "Accept", comment: "Chat: the button that accepts a message request")
        }
    }

    /// How far one of our messages got.
    public enum Delivery {
        /// Sent, with no receipt yet.
        public static var sent: String {
            NSLocalizedString("delivery.sent", bundle: .main, value: "Sent", comment: "A message's status: sent, no receipt yet")
        }

        /// A receipt came back.
        public static var delivered: String {
            NSLocalizedString("delivery.delivered", bundle: .main, value: "Delivered", comment: "A message's status: a receipt came back")
        }

        /// A DM waiting for its recipient's key.
        public static var waitingForKey: String {
            NSLocalizedString(
                "delivery.waiting-for-key",
                bundle: .main,
                value: "Waiting for their key. It sends as soon as the key arrives.",
                comment: "A DM's status: waiting for the recipient's encryption key"
            )
        }
    }

    /// Message requests: DMs from people the user has not chatted with, and groups nobody they know has written in.
    public enum Requests {
        /// The screen's title.
        public static var title: String {
            NSLocalizedString("requests.title", bundle: .main, value: "Message requests", comment: "Requests: the screen's title")
        }

        /// What lands here.
        public static var explanation: String {
            NSLocalizedString(
                "requests.explanation",
                bundle: .main,
                value: """
                    Messages from people you haven't chatted with, and groups they add you to, wait here. Accept one to move it to \
                    your chats.
                    """,
                comment: "Requests: what the screen holds"
            )
        }

        /// No requests.
        public static var empty: String {
            NSLocalizedString("requests.empty", bundle: .main, value: "No message requests", comment: "Requests: nothing waits")
        }

        /// A row's accept button.
        public static var accept: String {
            NSLocalizedString("requests.accept", bundle: .main, value: "Accept", comment: "Requests: a row's accept button")
        }
    }
}
