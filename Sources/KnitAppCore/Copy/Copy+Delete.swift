import Foundation

extension Copy {
    /// Deleting a message, a chat or a request, and clearing the room (ADR 2026-10.u7cq). Every delete is local to this
    /// iPhone and tells nobody, as on Android (`chat_delete_confirm_*`, `chat_list_delete_confirm_*`,
    /// `chat_list_clear_nearby_confirm_*` and `message_requests_delete_confirm_*` in knit-next's `strings.xml`).
    public enum Delete {
        /// The button that deletes, on a row's swipe, in a bubble's menu and in each confirmation.
        public static var delete: String {
            NSLocalizedString(
                "delete.delete", bundle: .main, value: "Delete", comment: "Delete: the button that deletes a message, chat or request")
        }

        /// The button that clears the Nearby room, on its row's swipe and in the confirmation.
        public static var clear: String {
            NSLocalizedString(
                "delete.clear", bundle: .main, value: "Clear", comment: "Delete: the button that clears the Nearby room's messages")
        }

        /// The message confirmation's title.
        public static var messageTitle: String {
            NSLocalizedString(
                "delete.message.title", bundle: .main, value: "Delete message?", comment: "Delete: the confirmation's title for one message"
            )
        }

        /// What deleting a message does.
        public static var messageBody: String {
            NSLocalizedString(
                "delete.message.body",
                bundle: .main,
                value: "Knit deletes it from this iPhone. Other phones keep their copies.",
                comment: "Delete: what deleting one message does"
            )
        }

        /// The chat confirmation's title, for a DM or a group.
        public static var chatTitle: String {
            NSLocalizedString(
                "delete.chat.title", bundle: .main, value: "Delete chat?", comment: "Delete: the confirmation's title for a whole chat")
        }

        /// What deleting a DM does.
        public static var directBody: String {
            NSLocalizedString(
                "delete.chat.direct.body",
                bundle: .main,
                value: "Knit deletes every message in this chat from this iPhone. Other phones keep their copies.",
                comment: "Delete: what deleting a chat with one person does"
            )
        }

        /// What deleting a group's chat does: the membership stays.
        public static var groupBody: String {
            NSLocalizedString(
                "delete.chat.group.body",
                bundle: .main,
                value: """
                    Knit deletes the group's messages from this iPhone. You stay in the group, and the chat comes back with its next \
                    message.
                    """,
                comment: "Delete: what deleting a group's chat does"
            )
        }

        /// The room confirmation's title.
        public static var roomTitle: String {
            NSLocalizedString(
                "delete.room.title",
                bundle: .main,
                value: "Clear Nearby?",
                comment: "Delete: the confirmation's title for clearing the Nearby room"
            )
        }

        /// What clearing the room does.
        public static var roomBody: String {
            NSLocalizedString(
                "delete.room.body",
                bundle: .main,
                value: "Knit deletes every Nearby message from this iPhone. The room stays in your chat list.",
                comment: "Delete: what clearing the Nearby room does"
            )
        }

        /// The request confirmation's title.
        public static var requestTitle: String {
            NSLocalizedString(
                "delete.request.title",
                bundle: .main,
                value: "Delete request?",
                comment: "Delete: the confirmation's title for a message request"
            )
        }

        /// What deleting a request does.
        public static var requestBody: String {
            NSLocalizedString(
                "delete.request.body",
                bundle: .main,
                value: "Knit deletes it from this iPhone. If they write again, you'll get a new request.",
                comment: "Delete: what deleting a message request does"
            )
        }
    }
}
