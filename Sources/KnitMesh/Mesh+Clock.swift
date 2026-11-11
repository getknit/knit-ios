import Foundation

/// The wall clock's changes (ADR 2026-11.prsp; ADR 2026-09.gq84): the advert's slot turn and the reader's window run on the
/// wall clock while the timer sleeps on the monotonic one, so a set clock is heard here, as the radio's events are, and
/// handed to the links as one more entry.
extension Mesh {
    /// The system's notification that the wall clock was set, and its observer while the mesh runs (a test may name its own,
    /// ``LinkManager/Configuration/clockChangeName``).
    struct ClockWatch {
        #if canImport(Darwin)
            /// The system's: `NSSystemClockDidChange`, which only Apple's Foundation declares.
            static let system = Notification.Name.NSSystemClockDidChange
        #else
            /// Elsewhere its raw name, which nothing posts.
            static let system = Notification.Name("NSSystemClockDidChangeNotification")
        #endif

        /// The observer, while running.
        var observer: (any NSObjectProtocol)?
    }

    /// The wall clock was set: the links read the slot turn, the reader's window and their wall-clock waits again, and the
    /// timer is aimed anew. Ignored while stopped, when the next start reads the clock anyway.
    public func wallClockChanged() {
        guard isRunning else {
            return
        }
        apply(links.wallClockChanged())
        settle()
    }

    /// Turns the advert's blinding on or off at runtime, in a build whose links may blind (``LinkManager/setBlinding(_:)``).
    public func setBlinding(_ on: Bool) {
        links.setBlinding(on)
        settle()
    }

    /// Starts hearing the system's clock changes, while running.
    func observeClock() {
        let name = links.configuration.clockChangeName.map { Notification.Name(rawValue: $0) } ?? ClockWatch.system
        clockWatch.observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            Task {
                await self?.wallClockChanged()
            }
        }
    }

    /// Stops hearing them.
    func forgetClock() {
        clockWatch.observer.map(NotificationCenter.default.removeObserver)
        clockWatch.observer = nil
    }
}
