#if os(iOS) && DEBUG
    import Foundation

    /// The demo's voice notes, read from `DemoMedia` in the app's bundle, which only a debug build carries (ADR
    /// 2026-10.2acj): speech-shaped noise, which ffmpeg made from pink noise for the demo, so nobody's voice is in it.
    /// AAC-LC in ADTS at 16 kHz mono, as the recorder makes a note.
    internal enum DemoVoice {
        /// The thread's notes, six and a half seconds long.
        static func clip() -> [UInt8]? {
            read("voice-note")
        }

        /// What `-demoVoice`'s mic records, four seconds long: a note of its own, so playing it plays no note in the
        /// thread, which the player knows by its bytes.
        static func reply() -> [UInt8]? {
            read("voice-reply")
        }

        /// The bytes of `name` in the bundle's `DemoMedia`, or `nil` without the folder.
        private static func read(_ name: String) -> [UInt8]? {
            Bundle.main.url(forResource: name, withExtension: "aac", subdirectory: "DemoMedia")
                .flatMap { try? Data(contentsOf: $0) }
                .map { [UInt8]($0) }
        }
    }
#endif
