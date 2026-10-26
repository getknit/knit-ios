import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Voice notes' strings (ADR 2026-10.ue3y), apart so the suite stays under the lint's length.
    static var voiceStrings: [String] {
        [
            Copy.Voice.play,
            Copy.Voice.pause,
            Copy.Voice.described(length: "0:07"),
            Copy.Voice.playing(length: "0:07", at: "0:01"),
            Copy.Voice.waiting,
            Copy.Voice.unplayable,
            Copy.Voice.notInNearby,
            Copy.Voice.recordStart,
            Copy.Voice.stop,
            Copy.Voice.recording,
            Copy.Voice.slideToCancel,
            Copy.Voice.cancel,
            Copy.Voice.remove,
            Copy.Voice.tooShort,
            Copy.Voice.unrecorded,
            Copy.Voice.microphoneOffTitle,
            Copy.Voice.microphoneOffMessage,
            Copy.System.microphoneUsage,
        ]
    }
}
