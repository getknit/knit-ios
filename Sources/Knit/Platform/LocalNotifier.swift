#if os(iOS)
    import Foundation
    import KnitAppCore
    import UserNotifications

    /// Posts what ``NotificationPolicy`` decides through UserNotifications, and asks for the permission. Each
    /// conversation's notification, and the one for requests, has a fixed id, so a new one replaces the last. While
    /// the last still shows, the replacement is passive: no sound, no banner, the screen stays dark.
    internal struct LocalNotifier: Notifier, NotificationPermission {
        /// The user-info key that carries the thread a tap opens.
        static let conversationKey = "conversation"

        private var center: UNUserNotificationCenter { .current() }

        func post(_ notification: LocalNotification) async {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.threadIdentifier = notification.threadId
            let showing = await center.deliveredNotifications().contains { $0.request.identifier == notification.id }
            if showing {
                content.interruptionLevel = .passive
            } else {
                content.sound = .default
            }
            if let conversation = notification.conversationId {
                content.userInfo = [Self.conversationKey: conversation]
            }
            let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
            try? await center.add(request)
        }

        func withdraw(threadId: String) async {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == threadId }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }

        func authorization() async -> NotificationAuthorization {
            Self.authorization(await center.notificationSettings().authorizationStatus)
        }

        func request() async -> NotificationAuthorization {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            return await authorization()
        }

        private static func authorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
            switch status {
            case .notDetermined:
                .notDetermined
            case .authorized, .provisional, .ephemeral:
                .allowed
            case .denied:
                .denied
            @unknown default:
                .denied
            }
        }
    }
#endif
