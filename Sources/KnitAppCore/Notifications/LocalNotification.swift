public import KnitStore
public import KnitWire

/// A notification the app should post: what it says, and where a tap leads.
public struct LocalNotification: Sendable, Equatable {
    /// Replaces any notification with the same id: each conversation keeps one, and every request shares one.
    public var id: String
    /// Groups the notifications of one thread.
    public var threadId: String
    /// The thread a tap opens, or `nil` for the requests list.
    public var conversationId: String?
    /// The title: the sender, the room, or the requests heading.
    public var title: String
    /// The body.
    public var body: String

    /// Makes a notification.
    public init(id: String, threadId: String, conversationId: String?, title: String, body: String) {
        self.id = id
        self.threadId = threadId
        self.conversationId = conversationId
        self.title = title
        self.body = body
    }
}

/// Where notifications go: UserNotifications in the app, a recorder in tests.
public protocol Notifier: Sendable {
    /// Posts `notification`, replacing one with the same id. A replacement stays quiet while the one it replaces is
    /// still showing, so a burst of messages alerts once (Android's `setOnlyAlertOnce`).
    func post(_ notification: LocalNotification) async
    /// Removes what was posted for a thread, or for the requests list with ``NotificationPolicy/requestsThread``.
    func withdraw(threadId: String) async
}

/// What reaches the user as a notification (`MessageNotifier` in knit-next, the MVP's part of it).
///
/// A message notifies once, when it first arrives, and never our own. Each conversation keeps one notification that
/// shows its newest message, as Android's does, so a room's back-fill of 200 posts is one notification rather than
/// 200. The thread on screen while the app is in front stays quiet. A stranger's DM is a message request: it never
/// shows its words or its sender, and every request shares one notification that counts them. Control frames never
/// arrive here: the engine stores and reports only messages.
public enum NotificationPolicy {
    /// The id and thread of the one notification that counts requests.
    public static let requestsThread = "requests"

    /// What a decision reads besides the message.
    public struct Context: Sendable {
        /// This node.
        public var me: NodeId
        /// The thread on screen while the app is in front, or `nil`.
        public var visibleConversation: String?
        /// Who is who, for the sender's label.
        public var directory: Directory
        /// How many requests wait, this one included.
        public var pendingRequests: Int
        /// The title of the group the message came in, or `nil` outside a group.
        public var groupTitle: String?

        /// Bundles the context.
        public init(me: NodeId, visibleConversation: String?, directory: Directory, pendingRequests: Int, groupTitle: String? = nil) {
            self.me = me
            self.visibleConversation = visibleConversation
            self.directory = directory
            self.pendingRequests = pendingRequests
            self.groupTitle = groupTitle
        }
    }

    /// The notification for a message that just arrived, or `nil` when it should stay quiet.
    public static func notification(for message: MessageRecord, isRequest: Bool, in context: Context) -> LocalNotification? {
        guard message.senderId != context.me else {
            return nil
        }
        if isRequest {
            return LocalNotification(
                id: requestsThread,
                threadId: requestsThread,
                conversationId: nil,
                title: Copy.Notifications.requestTitle,
                body: Copy.Notifications.requestBody(max(context.pendingRequests, 1))
            )
        }
        guard message.conversationId != context.visibleConversation else {
            return nil
        }
        let sender = context.directory.label(for: message.senderId).text
        let isRoom = message.conversationId == Conversations.nearby
        // A group's notification is titled for the group and names its speaker, as the room's does.
        let shared = isRoom ? Copy.Notifications.nearbyTitle : context.groupTitle
        return LocalNotification(
            id: message.conversationId,
            threadId: message.conversationId,
            conversationId: message.conversationId,
            title: shared ?? sender,
            body: shared == nil ? message.body : Copy.Notifications.roomBody(sender: sender, body: message.body)
        )
    }
}
