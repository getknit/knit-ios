#if os(iOS) && DEBUG
    import Foundation
    import KnitControl
    import ReplayKit

    /// ReplayKit's in-app recorder, for the bridge's screen recordings (``ScreenRecording``, ADR 2026-10.x2cq). It records
    /// Knit's own windows and, when asked, the microphone, and writes the movie only at the stop
    /// (`stopRecording(withOutput:)`), so a long take costs no memory and needs no writer of ours. iOS asks the person
    /// holding the phone at a start, and asks again after eight minutes, or at every start on newer releases.
    @MainActor
    internal final class ReplayCapture: NSObject, ScreenCapture, RPScreenRecorderDelegate {
        /// `RPRecordingErrorCode.userDeclined`: the person said no to iOS's question.
        private static let userDeclined = -5801
        /// "Attempting to start a recording while already in recording state", which the lab iPhone returned while
        /// `isRecording` was false: a recording left over in ReplayKit, or one Control Center holds.
        private static let alreadyRecording = -5830

        /// What iOS ended by itself, with its reason, for ``ScreenRecording/lose(_:)``.
        nonisolated let losses: AsyncStream<String>
        nonisolated private let lost: AsyncStream<String>.Continuation

        override init() {
            (losses, lost) = AsyncStream<String>.makeStream()
            super.init()
            RPScreenRecorder.shared().delegate = self
        }

        func begin(microphone: Bool) async throws(RecordingRefusal) {
            let recorder = RPScreenRecorder.shared()
            guard recorder.isAvailable else {
                throw RecordingRefusal(.unavailable, "ReplayKit cannot record now: a call, AirPlay or mirroring may hold the screen")
            }
            recorder.isMicrophoneEnabled = microphone
            var failure = await Self.start(recorder)
            if let first = failure as NSError?, first.domain == RPRecordingErrorDomain, first.code == Self.alreadyRecording {
                // Once: stop whatever ReplayKit thinks it records, then try again.
                await discard()
                failure = await Self.start(recorder)
            }
            if let failure {
                throw Self.refusal(failure, starting: true)
            }
        }

        func isCapturing() -> Bool {
            RPScreenRecorder.shared().isRecording
        }

        func discard() async {
            let scratch = FileManager.default.temporaryDirectory.appending(path: "knit-discard-\(UUID().uuidString).mp4")
            _ =
                await withCheckedContinuation { continuation in
                    RPScreenRecorder.shared().stopRecording(withOutput: scratch) { error in continuation.resume(returning: error) }
                } as (any Error)?
            try? FileManager.default.removeItem(at: scratch)
        }

        private static func start(_ recorder: RPScreenRecorder) async -> (any Error)? {
            await withCheckedContinuation { continuation in
                recorder.startRecording { error in continuation.resume(returning: error) }
            }
        }

        func end(writingTo file: URL) async throws(RecordingRefusal) {
            let failure: (any Error)? = await withCheckedContinuation { continuation in
                RPScreenRecorder.shared().stopRecording(withOutput: file) { error in continuation.resume(returning: error) }
            }
            if let failure {
                throw Self.refusal(failure, starting: false)
            }
        }

        nonisolated func screenRecorder(
            _: RPScreenRecorder,
            didStopRecordingWith _: RPPreviewViewController?,
            error: (any Error)?
        ) {
            lost.yield(error.map { "iOS stopped the recording: \($0.localizedDescription)" } ?? "iOS stopped the recording")
        }

        private static func refusal(_ error: any Error, starting: Bool) -> RecordingRefusal {
            let failure = error as NSError
            if starting, failure.domain == RPRecordingErrorDomain, failure.code == userDeclined {
                return RecordingRefusal(.declined, "the person holding the phone did not allow screen recording")
            }
            if starting, failure.domain == RPRecordingErrorDomain, failure.code == alreadyRecording {
                return RecordingRefusal(
                    .elsewhere,
                    "ReplayKit still says a recording runs after Knit stopped its own: stop Control Center's Screen Recording "
                        + "(the red pill), or force-quit Knit"
                )
            }
            return RecordingRefusal(.failed, "\(failure.localizedDescription) (\(failure.domain) \(failure.code))")
        }
    }
#endif
