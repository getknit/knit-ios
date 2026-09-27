#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit
    import UserNotifications

    // periphery:ignore - the @main entry point; xtool's wrapper executable is its only caller
    /// The app entry point xtool packs from the `Knit` library product.
    @main
    internal struct KnitApp: App {
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
        @Environment(\.scenePhase) private var scenePhase

        var body: some Scene {
            WindowGroup {
                RootView(launch: delegate.launch)
            }
            .onChange(of: scenePhase) { _, phase in
                delegate.launch.setActive(phase == .active)
            }
        }
    }

    /// Builds the environment at launch, before any scene, so the Bluetooth managers exist when iOS relaunches
    /// Knit in the background to restore them; and routes notification taps.
    @MainActor
    internal final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        let launch = Launch()

        func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
            UNUserNotificationCenter.current().delegate = self
            launch.begin()
            return true
        }

        func applicationProtectedDataDidBecomeAvailable(_: UIApplication) {
            launch.begin()
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            // swiftlint:disable:next unneeded_escaping - UserNotifications declares the handler escaping
            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            // The policy already kept the thread on screen quiet. A passive one replaces a notification still showing.
            let passive = notification.request.content.interruptionLevel == .passive
            completion(passive ? [.list] : [.banner, .list, .sound])
        }

        nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let conversation = response.notification.request.content.userInfo[LocalNotifier.conversationKey] as? String
            await MainActor.run {
                launch.open(conversation: conversation)
            }
        }
    }
#endif
