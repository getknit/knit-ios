#if os(iOS) && DEBUG
    import Foundation
    import KnitControl
    import KnitMesh
    import UIKit

    /// The bridge's screen recordings (ADR 2026-10.x2cq) tied to the app: ReplayKit's recorder, what iOS ends by itself,
    /// and Knit leaving the front, which ends a take while there is still time to write it.
    @MainActor
    internal final class BridgeRecorder {
        private let takes: ScreenRecording
        /// The background time asked for while a take finishes, if any.
        private var finishing = UIBackgroundTaskIdentifier.invalid

        private init(clock: any MeshClock) {
            let capture = ReplayCapture()
            let recordings = ScreenRecording(
                capture: capture,
                directory: FileManager.default.temporaryDirectory.appending(path: "Recordings"),
                clock: clock
            )
            takes = recordings
            Task {
                for await reason in capture.losses {
                    await recordings.lose(reason)
                }
            }
        }

        /// The recordings the bridge's `record-` commands drive, dated by `clock`. They live as long as the app.
        static func start(clock: any MeshClock) -> ScreenRecording {
            let recorder = Self(clock: clock)
            let center = NotificationCenter.default
            // Not the scene going inactive, which Control Center and a banner do too: only leaving the front ends a
            // take. The observer holds the recorder for the app's life, and is never removed.
            // swiftlint:disable:next discarded_notification_center_observer - it is never removed, as said above.
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { recorder.finish() }
            }
            return recorder.takes
        }

        /// Ends a running take and keeps the file while iOS still lets Knit run, since a suspended Knit would lose it.
        /// A script reads it with `record-stop` once Knit is back.
        private func finish() {
            guard finishing == .invalid else {
                return
            }
            finishing = UIApplication.shared.beginBackgroundTask(withName: "knit.record-finish") { [weak self] in
                MainActor.assumeIsolated { self?.release() }
            }
            let running = takes
            Task { [weak self] in
                await running.finishForBackground()
                self?.release()
            }
        }

        private func release() {
            guard finishing != .invalid else {
                return
            }
            UIApplication.shared.endBackgroundTask(finishing)
            finishing = .invalid
        }
    }
#endif
