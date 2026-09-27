#if os(iOS)
    import Foundation
    import KnitAppCore
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

        private(set) var stage = Stage.waiting("")
        /// A thread a tapped notification asked for, until the screens take it.
        var requestedConversation: String?
        /// Whether a tapped notification asked for the message requests.
        var requestedRequests = false

        @ObservationIgnored private let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

        /// Builds the environment, unless it is already running. Called at launch, and again when protected data
        /// becomes available after a launch before the first unlock.
        func begin() {
            if case .ready = stage {
                return
            }
            do {
                let environment = try AppEnvironment.make(options)
                stage = .ready(environment)
                environment.run()
            } catch {
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

        /// The app came to the front or left it.
        func setActive(_ active: Bool) {
            if case .ready(let environment) = stage {
                environment.session.isActive = active
                if active {
                    environment.foregrounded()
                } else {
                    environment.backgrounded()
                }
            }
        }
    }
#endif
