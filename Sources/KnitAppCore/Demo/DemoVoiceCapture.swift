import Foundation

/// The demo's microphone, under `-demoVoice`: a press records the clip the app bundles for the demo, since the Simulator
/// has no microphone a UI test can speak into. Its level rises and falls as a voice's would, so the recording dot moves.
@preconcurrency
@MainActor
public final class DemoVoiceCapture: VoiceCapture {
    /// How many ticks a rise and fall of the level takes.
    private static let syllable = 6.0

    private let clip: [UInt8]
    private var ticks = 0
    private var recording = false

    /// A microphone that records `clip`, AAC-LC in ADTS.
    public init(clip: [UInt8]) {
        self.clip = clip
    }

    public var level: Double {
        guard recording else {
            return 0
        }
        ticks += 1
        return abs(sin(Double(ticks) / Self.syllable * .pi))
    }

    public func start() -> Bool {
        ticks = 0
        recording = true
        return true
    }

    public func stop() -> [UInt8] {
        recording = false
        return clip
    }

    public func cancel() {
        recording = false
    }
}

/// The demo's microphone permission, under `-demoVoice`: allowed, as a UI test has no prompt to tap.
public struct DemoMicrophone: MicrophoneAccess {
    /// A permission that is allowed.
    public init() {
        // Allowed from the start.
    }

    public var authorization: MicrophoneAuthorization {
        .allowed
    }

    public func request() -> MicrophoneAuthorization {
        .allowed
    }
}
