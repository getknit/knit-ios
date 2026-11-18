#if os(iOS)
    import KnitAppCore
    import UIKit

    // How the environment hears the scene's phases, apart from the class only to keep its file inside the lint's length.
    extension AppEnvironment {
        /// The scene moved to `phase`: the stream tells the links whether Knit is in the background, and the spool pauses and
        /// resumes as ``SpoolLifecycle`` says. Control Center or an alert over Knit is neither background nor front: Knit is
        /// still on screen, Android still finds it, and the relays keep their sockets. A return to the front first tries the
        /// relays' owed reads and deletes again. Going to the background takes a background task that ends once the mesh has
        /// paused the spool, so its stop is set and its sockets' closes issued before iOS suspends Knit. Going posts
        /// `-demoNotification`'s notification.
        func scene(_ phase: AppPhase) {
            let background = phase == .background
            if phase == .active {
                relays?.becameActive()
            }
            if background, relays != nil {
                let task = PauseTask.begin()
                phases.send(.scene(phase)) { Task { @MainActor in task.end() } }
            } else {
                phases.send(.scene(phase))
            }
            if background, let model {
                Task { await model.release() }
            }
            if let textModel {
                Task { await textModel.setInBackground(background) }
            }
            if background, let demoNotification {
                let alerts = notifier
                Task { await alerts.post(demoNotification) }
            }
        }

        /// Lets the filter's models go: memory runs low. The next photo or message screened loads its model again.
        func releaseModel() {
            if let model {
                Task { await model.release() }
            }
            if let textModel {
                Task { await textModel.release() }
            }
        }
    }

    /// The background task that covers the spool's pause as Knit leaves the front (ADR 2026-11.adrq, P6): taken when the
    /// scene goes to the background and ended once the mesh has paused, so the miner's stop is set and every socket's close is
    /// issued before iOS suspends Knit.
    @MainActor
    internal final class PauseTask {
        private var identifier = UIBackgroundTaskIdentifier.invalid

        /// A task begun now, which ends itself if iOS runs it out. The expiration handler holds the task strongly, so the task
        /// lives until it is ended, whichever comes first; UIKit lets the handler go when the task ends.
        static func begin() -> PauseTask {
            let task = PauseTask()
            task.identifier = UIApplication.shared.beginBackgroundTask(withName: "spool pause") {
                task.end()
            }
            return task
        }

        /// Ends the task, once.
        func end() {
            guard identifier != .invalid else {
                return
            }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif
