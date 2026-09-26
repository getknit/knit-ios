import Foundation

extension Copy {
    /// Local notifications.
    public enum Notifications {
        /// A room post's title.
        public static var nearbyTitle: String {
            NSLocalizedString(
                "notifications.nearby",
                bundle: .main,
                value: "Nearby",
                comment: "Notification title: a post in the Nearby room"
            )
        }

        /// A room post: "Sam: see you there".
        public static func roomBody(sender: String, body: String) -> String {
            format(
                NSLocalizedString(
                    "notifications.room.body",
                    bundle: .main,
                    value: "%1$@: %2$@",
                    comment: "Notification: a room post; %1$@ is the sender, %2$@ the message"
                ),
                sender,
                body
            )
        }

        /// A request's title.
        public static var requestTitle: String {
            NSLocalizedString(
                "notifications.request",
                bundle: .main,
                value: "New message request",
                comment: "Notification title: a message request"
            )
        }

        /// How many requests wait. The request's words stay out of the notification until it is accepted.
        public static func requestBody(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString(
                    "notifications.request.one",
                    bundle: .main,
                    value: "%lld person wants to message you",
                    comment: "Notification"
                ),
                other: NSLocalizedString(
                    "notifications.request.other",
                    bundle: .main,
                    value: "%lld people want to message you",
                    comment: "Notification: requests; a count"
                )
            )
        }
    }
}
