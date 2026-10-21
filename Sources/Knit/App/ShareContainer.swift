#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitMesh
    import KnitStore

    /// Where the share sheet's inbox lives (ADR 2026-10.z7a8): the App Group's container, named by `KnitAppGroup` in
    /// `App/Info.plist`, which each build fills with its own group, so the debug and store builds never drain each
    /// other's shares.
    internal enum ShareContainer {
        /// This build's App Group, or `nil` when the plist names none.
        static var group: String? {
            (Bundle.main.object(forInfoDictionaryKey: "KnitAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The inbox in the App Group's container, or `nil` when the build has no group or iOS gives it no container,
        /// as for an unsigned build.
        static func inbox() -> ShareInbox? {
            guard let group, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                return nil
            }
            return ShareInbox(container: container)
        }

        /// The share sheet's host over `inbox` for `session`, checking pictures with `filter`, offering chats once
        /// `settings` say onboarding is done.
        @MainActor
        static func host(inbox: ShareInbox, session: AppSession, filter: PhotoScreening, settings: any AppPreferences) -> ShareHost {
            ShareHost(
                inbox: inbox,
                session: session,
                codec: DeviceImageCodec(),
                screening: filter,
                now: { SystemClock().wallMilliseconds() },
                onboarded: { settings.hasOnboarded },
                pause: { try? await Task.sleep(for: .seconds(1)) }
            )
        }

        /// Starts `shares`, and answers what hears the sheet's call that it left a share, which drains it at once.
        @MainActor
        static func start(_ shares: ShareHost) -> ShareWake? {
            shares.start()
            return group.map { group in
                ShareWake(name: ShareInbox.wakeName(group: group)) { Task { @MainActor in shares.sessionMoved() } }
            }
        }

        #if DEBUG
            /// A folder of the demo's own under `-demoShare`, emptied, with `words` waiting for the room, as if the share
            /// sheet had just left them. The UI tests walk the drain this way: the system's share sheet is out of their
            /// reach.
            static func demoInbox(_ words: String) -> ShareInbox {
                let root = FileManager.default.temporaryDirectory.appending(path: "DemoShare", directoryHint: .isDirectory)
                try? FileManager.default.removeItem(at: root)
                let inbox = ShareInbox(container: root)
                let share = ShareManifest.message(words, to: Conversations.nearby, hasPicture: false, at: SystemClock().wallMilliseconds())
                try? inbox.submit(share, picture: nil, id: "demo")
                return inbox
            }
        #endif
    }
#endif
