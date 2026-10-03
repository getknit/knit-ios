#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit
    import UserNotifications

    // periphery:ignore - the @main entry point; the Xcode project's KnitApp target is its only caller
    /// The app entry point that the Xcode project (`App/project.yml`) packs from the `Knit` library product.
    @main
    internal struct KnitApp: App {
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
        @Environment(\.scenePhase) private var scenePhase

        var body: some Scene {
            WindowGroup {
                RootView(launch: delegate.launch)
                    .tint(Palette.accent)
            }
            .onChange(of: scenePhase) { _, phase in
                delegate.launch.setActive(phase == .active)
                // Inactive, under Control Center or an alert, is still on screen: only the background seeks peers.
                delegate.launch.setInBackground(phase == .background)
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
            launch.begin(.launch)
            return true
        }

        func applicationProtectedDataDidBecomeAvailable(_: UIApplication) {
            launch.begin(.protectedData)
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

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            // swiftlint:disable:next unneeded_escaping - UserNotifications declares the handler escaping
            withCompletionHandler completion: @escaping () -> Void
        ) {
            let conversation = response.notification.request.content.userInfo[LocalNotifier.conversationKey] as? String
            // UIKit hands a tap over on the main thread, and asserts that its handler is called there too. The async form
            // of this method called it from the cooperative pool, and the assertion aborted Knit whenever a tap reached it
            // in the background, as one on the lock screen does (2026-10-03).
            MainActor.assumeIsolated {
                launch.open(conversation: conversation)
            }
            completion()
        }
    }
#endif
