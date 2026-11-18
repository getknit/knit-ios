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
                    .onOpenURL { url in delegate.launch.open(url: url) }
                    // A contact link tapped in a message opens Add contact here, as one tapped in Messages does, rather
                    // than Safari, and in a debug build a relay invite opens its consent sheet; every other address goes where
                    // iOS sends it (ADR 2026-11.w5ew, ADR 2026-11.adrq).
                    .environment(
                        \.openURL,
                        OpenURLAction { [launch = delegate.launch] url in
                            guard Launch.opensHere(url) else {
                                return .systemAction
                            }
                            launch.open(url: url)
                            return .handled
                        }
                    )
            }
            // Inactive, under Control Center or an alert, is still on screen: only the background seeks peers and pauses
            // the relays.
            .onChange(of: scenePhase) { _, phase in
                delegate.launch.scene(AppPhase(phase))
            }
        }
    }

    extension AppPhase {
        /// SwiftUI's phase: a phase this build does not know keeps things as they are, as `.inactive` does.
        init(_ phase: ScenePhase) {
            switch phase {
            case .active:
                self = .active
            case .background:
                self = .background
            default:
                self = .inactive
            }
        }
    }

    /// Builds the environment at launch, before any scene, so the Bluetooth managers exist when iOS relaunches
    /// Knit in the background to restore them; subscribes to MetricKit's crash and hang reports; and routes
    /// notification taps.
    @MainActor
    internal final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        let launch: Launch
        /// Saves what MetricKit says of the last crash or hang (ADR 2026-10.qhsv), whether or not the phone has been
        /// unlocked since it started. MetricKit is no in-process handler: it hands a failure to the launch after it,
        /// whenever this subscribes, so the subscription waits until the Bluetooth managers exist.
        private let collector: MetricKitCollector

        override init() {
            collector = MetricKitCollector(store: .live)
            launch = Launch(crashes: .live)
            super.init()
        }

        func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
            UNUserNotificationCenter.current().delegate = self
            launch.begin(.launch)
            collector.start()
            return true
        }

        func applicationProtectedDataDidBecomeAvailable(_: UIApplication) {
            collector.importPast()
            launch.begin(.protectedData)
        }

        func applicationDidReceiveMemoryWarning(_: UIApplication) {
            launch.memoryRunsLow()
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
