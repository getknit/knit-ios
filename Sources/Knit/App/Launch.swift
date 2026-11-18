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
        /// The sample chats while they're open (ADR 2026-11.pydf), drawn over `stage`'s environment, which runs on under them:
        /// its radio, its links and its notifications don't change. Nothing keeps them, so every launch comes up live,
        /// a relaunch to restore Bluetooth among them.
        private(set) var sample: AppEnvironment?
        /// A thread a tapped notification asked for, until the screens take it.
        var requestedConversation: String?
        /// Whether a tapped notification asked for the message requests.
        var requestedRequests = false
        /// A contact link opened from outside Knit, until Add contact takes it (ADR 2026-10.tpr5).
        var requestedContactLink: String?
        /// A relay invite opened from outside Knit or tapped in a message, held in memory alone until the live screens,
        /// after onboarding and the terms, hand it to the relay settings (ADR 2026-11.adrq, P6). Only a debug build sets it.
        var requestedRelayInvite: String?

        @ObservationIgnored private var history = History(startedAt: SystemClock().wallMilliseconds())
        /// The scene's last phase, which an environment built after it hears at once: a launch that waited for protected data
        /// or Retry at the front would otherwise miss the `.active` that runs its relays.
        @ObservationIgnored private var phase: AppPhase?
        /// The saved crash and hang reports, which the app delegate's collector fills before any environment exists.
        @ObservationIgnored private let crashes: CrashStore

        init(crashes: CrashStore) {
            self.crashes = crashes
        }

        /// The launch's options, read as each try builds the environment, once protected data can be read: from the
        /// process's own arguments in a debug build (`-seedDemo`, the `-demo…` flags, `-ratchet on|off` and `-blind on|off`),
        /// and from none in a release one, which always runs live with the ratchet on and no blinded advert (ADR 2026-10.8cy5,
        /// ADR 2026-11.prsp). A debug build also keeps `-ratchet`'s and `-blind`'s choices in its defaults for every launch
        /// after it that names none (ADR 2026-10.5sk9), the ones iOS makes by itself after an install or a reboot among them,
        /// and the bridge's `advert` keeps `-blind`'s there too. A running process keeps what its own start read, so a
        /// `devicectl` launch that brings it forward without `--terminate-existing` changes nothing. A release build reads
        /// and keeps nothing.
        nonisolated private static func options() -> LaunchOptions {
            #if DEBUG
                let defaults = UserDefaults.standard
                // `scripts/check.sh release` fails when a release build holds this key: it would mean the kept switch ships.
                let key = "debug.launch.ratchet"
                let stored = defaults.string(forKey: key).flatMap(LaunchOptions.Choice.init(word:))
                let blindKey = AppEnvironment.blindSwitchKey
                let storedBlind = defaults.string(forKey: blindKey).flatMap(LaunchOptions.Choice.init(word:))
                let read = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, storedRatchet: stored, storedBlind: storedBlind)
                if let choice = read.ratchetChoice {
                    defaults.set(choice.word, forKey: key)
                }
                if let choice = read.blindChoice {
                    defaults.set(choice.word, forKey: blindKey)
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
                let environment = try AppEnvironment.make(Self.options(), launch: history.started(by: trigger), crashes: crashes)
                stage = .ready(environment)
                environment.run()
                #if DEBUG
                    environment.offerSample(self)
                #endif
                // The scene's own phase, never the application's state, so only a scene at the front runs the relays.
                if trigger != .foreground, let phase {
                    environment.scene(phase)
                }
            } catch {
                history.waited = history.waited ?? "\(error)"
                stage = .waiting("\(error)")
            }
        }

        /// Opens the sample chats over the running app, from the first-run card or Settings, neither of which sits over a
        /// thread. Everyone agrees to the terms first, here as everywhere (ADR 2026-10.cgm3): App Review checks it, so a new way
        /// in can't skip them by accident.
        func openSample() {
            guard case .ready(let live) = stage, sample == nil, live.preferences.acceptedTerms >= Terms.version else {
                return
            }
            let environment = AppEnvironment.sample(beside: live)
            live.session.hideThreads()
            sample = environment
            environment.run()
        }

        /// Closes the sample chats, and with them all they held. The live screens come back.
        func closeSample() {
            sample?.close()
            sample = nil
        }

        /// A tapped notification: open its thread, or the requests when it names none. Only the live session posts one, so
        /// its thread is the live app's: the sample chats close first.
        func open(conversation: String?) {
            closeSample()
            if let conversation {
                requestedConversation = conversation
            } else {
                requestedRequests = true
            }
        }

        /// A URL that opened Knit, a `knit://` link or a tapped `https://getknit.app/c#…` one, which SwiftUI hands over
        /// as a universal link: Add contact takes a contact link, and anything else is ignored, as Android's inbox
        /// stages only what reads as a card (`ContactCardInbox.offer`).
        ///
        /// In a debug build a relay invite, `https://getknit.app/r#…` or `knit://r/…` at the very start of the address, closes
        /// the sample chats too and waits for the relay settings' consent sheet (ADR 2026-11.adrq, P6). A store build has no
        /// relays, and ignores one as it ignores any other address.
        func open(url: URL) {
            let text = url.absoluteString
            if AddContactModel.isContactLink(text) {
                closeSample()
                requestedContactLink = text
                return
            }
            #if DEBUG
                if RelayIntake.isInviteLink(text) {
                    // `scripts/check.sh release` fails when a release build holds this line: it would mean relay invites open.
                    UnifiedLog(clock: SystemClock()).log(.info, "a relay invite opened in this debug build")
                    closeSample()
                    requestedRelayInvite = text
                }
            #endif
        }

        /// Whether a link tapped in a message opens here rather than where iOS sends it: a contact link, and in a debug build a
        /// relay invite, so a tapped invite reaches the same consent sheet as one opened from outside Knit.
        static func opensHere(_ url: URL) -> Bool {
            let text = url.absoluteString
            #if DEBUG
                return AddContactModel.isContactLink(text) || RelayIntake.isInviteLink(text)
            #else
                return AddContactModel.isContactLink(text)
            #endif
        }

        /// iOS warned that memory runs low: the content filter's models let go, to load again for the next photo or message.
        func memoryRunsLow() {
            if case .ready(let environment) = stage {
                environment.releaseModel()
            }
        }

        /// The scene moved to `phase`: the one call the app's scene makes. At the front the phone is unlocked, so a launch still
        /// waiting starts then: iOS may have suspended a launch it made before the first unlock by the time protected data
        /// arrived. The live environment hears every phase, in order, and so does its mesh, through one stream: the links
        /// seek peers in the background, and the relays run only at the front (``SpoolLifecycle``). Inactive, under Control
        /// Center or an alert, is still on screen.
        func scene(_ phase: AppPhase) {
            self.phase = phase
            let active = phase == .active
            if active {
                begin(.foreground)
            }
            guard case .ready(let environment) = stage else {
                return
            }
            environment.scene(phase)
            let session = environment.session
            Task { await session.setActive(active) }
            // The sample's session hears it too, so an answer that lands behind Knit counts as unread. Its mesh hears nothing
            // of the background: it has no links to seek, and its seeking lines would read as the live one's (ADR 2026-11.pydf).
            if let front = sample?.session {
                Task { await front.setActive(active) }
            }
            if active {
                environment.foregrounded()
                // At the front a contact link the share sheet left can open Add contact (ADR 2026-10.z7a8).
                if let shares = environment.shares {
                    Task {
                        if let link = await shares.drain(atFront: true) {
                            closeSample()
                            requestedContactLink = link
                        }
                    }
                }
            } else {
                environment.backgrounded()
            }
        }
    }
#endif
