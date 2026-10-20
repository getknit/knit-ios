#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitMesh
    import Observation

    /// Where the launch stands, and the screen a notification asked for. The app delegate builds this before any
    /// scene exists, so the Bluetooth managers are there when the system relaunches Knit to restore them.
    @MainActor
    @Observable
    internal final class Launch {
        /// Where the launch stands.
        enum Stage {
            /// Protected data is not readable yet: the phone has not been unlocked since it started.
            case waiting(String)
            /// Running.
            case ready(AppEnvironment)
        }

        /// What started the app: the launch itself, protected data arriving at the first unlock, Knit coming to the
        /// front, or the waiting screen's Retry.
        enum Trigger: String {
            case launch = "launch"
            case protectedData = "protected data"
            case foreground = "foreground"
            case retry = "retry"
        }

        /// How this launch went, which a debug build's bridge reports for MVP item 1's reboot check.
        struct History {
            /// When the process began its launch, in wall milliseconds.
            let startedAt: Int64
            /// Why the first try failed, when one did: the phone had not been unlocked since it started.
            var waited: String?
            /// What started the app, and when; nil until something has.
            var readyBy: Trigger?
            var readyAt: Int64?

            /// This history, with the app started now by `trigger`.
            func started(by trigger: Trigger) -> Self {
                var started = self
                started.readyBy = trigger
                started.readyAt = SystemClock().wallMilliseconds()
                return started
            }
        }

        private(set) var stage = Stage.waiting("")
        /// A thread a tapped notification asked for, until the screens take it.
        var requestedConversation: String?
        /// Whether a tapped notification asked for the message requests.
        var requestedRequests = false
        /// A contact link opened from outside Knit, until Add contact takes it (ADR 2026-10.tpr5).
        var requestedContactLink: String?

        @ObservationIgnored private var history = History(startedAt: SystemClock().wallMilliseconds())

        /// The launch's options, read as each try builds the environment, once protected data can be read: from the
        /// process's own arguments in a debug build (`-seedDemo`, the `-demo…` flags and `-ratchet on|off`), and from
        /// none in a release one, which always runs live with the ratchet on (ADR 2026-10.8cy5). A debug build also keeps
        /// `-ratchet`'s choice in its defaults for every launch after it that names none (ADR 2026-10.5sk9), the ones iOS
        /// makes by itself after an install or a reboot among them. A running process keeps what its own start read, so a
        /// `devicectl` launch that brings it forward without `--terminate-existing` changes nothing. A release build reads
        /// and keeps nothing.
        nonisolated private static func options() -> LaunchOptions {
            #if DEBUG
                let defaults = UserDefaults.standard
                // `scripts/check.sh release` fails when a release build holds this key: it would mean the kept switch ships.
                let key = "debug.launch.ratchet"
                let stored = defaults.string(forKey: key).flatMap(LaunchOptions.Choice.init(word:))
                let read = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, storedRatchet: stored)
                if let choice = read.ratchetChoice {
                    defaults.set(choice.word, forKey: key)
                }
                return read
            #else
                return LaunchOptions(arguments: [])
            #endif
        }

        /// Builds the environment, unless it is already running. Called at launch, and again after a launch before
        /// the first unlock: when protected data becomes available, when Knit comes to the front, or from Retry.
        func begin(_ trigger: Trigger) {
            if case .ready = stage {
                return
            }
            do {
                let environment = try AppEnvironment.make(Self.options(), launch: history.started(by: trigger))
                stage = .ready(environment)
                environment.run()
            } catch {
                history.waited = history.waited ?? "\(error)"
                stage = .waiting("\(error)")
            }
        }

        /// A tapped notification: open its thread, or the requests when it names none.
        func open(conversation: String?) {
            if let conversation {
                requestedConversation = conversation
            } else {
                requestedRequests = true
            }
        }

        /// A URL that opened Knit, a `knit://` link or a tapped `https://getknit.app/c#…` one, which SwiftUI hands over
        /// as a universal link: Add contact takes a contact link, and anything else is ignored, as Android's inbox
        /// stages only what reads as a card (`ContactCardInbox.offer`).
        func open(url: URL) {
            let text = url.absoluteString
            if AddContactModel.isContactLink(text) {
                requestedContactLink = text
            }
        }

        /// Knit went to the background, where iOS may suspend it, or came back. A launch still waiting reads the state
        /// itself once it is ready.
        func setInBackground(_ background: Bool) {
            guard case .ready(let environment) = stage else {
                return
            }
            environment.setInBackground(background)
        }

        /// iOS warned that memory runs low: the content filter's models let go, to load again for the next photo or message.
        func memoryRunsLow() {
            if case .ready(let environment) = stage {
                environment.releaseModel()
            }
        }

        /// The app came to the front or left it. At the front the phone is unlocked, so a launch still waiting starts
        /// then: iOS may have suspended a launch it made before the first unlock by the time protected data arrived.
        func setActive(_ active: Bool) {
            if active {
                begin(.foreground)
            }
            guard case .ready(let environment) = stage else {
                return
            }
            let session = environment.session
            Task { await session.setActive(active) }
            if active {
                environment.foregrounded()
            } else {
                environment.backgrounded()
            }
        }
    }
#endif
