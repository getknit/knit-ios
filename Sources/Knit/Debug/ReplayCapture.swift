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
            guard !recorder.isRecording else {
                throw RecordingRefusal(.busy, "ReplayKit is already recording")
            }
            recorder.isMicrophoneEnabled = microphone
            let failure: (any Error)? = await withCheckedContinuation { continuation in
                recorder.startRecording { error in continuation.resume(returning: error) }
            }
            if let failure {
                throw Self.refusal(failure, starting: true)
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
            return RecordingRefusal(.failed, "\(failure.localizedDescription) (\(failure.domain) \(failure.code))")
        }
    }
#endif
