#if os(iOS)
    import KnitAppCore
    import KnitMesh

    extension AppEnvironment {
        /// Voice notes, a debug build's alone until the maintainer approves them for the store: no model on the phone
        /// screens speech, and App Review holds Knit to rule 1.2 (ADR 2026-10.tydq). A release build has none, so it has
        /// no mic, keeps the tile that says it can't play one, and never asks for the microphone, whose key only a debug
        /// build's Info.plist carries. Under `-demoVoice` the mic records `demoClip`, the microphone allowed.
        static func voiceNotes(log: any KnitLog, demoClip: [UInt8]?) -> VoiceNotes? {
            #if DEBUG
                // `scripts/check.sh release` fails when a release build holds this line: it would mean voice notes ship.
                log.log(.info, "voice notes are on in this debug build")
                let clock = SystemClock()
                return VoiceNotes(
                    capture: demoClip.map { DemoVoiceCapture(clip: $0) } ?? EngineVoiceCapture(log: log),
                    access: demoClip == nil ? DeviceMicrophone() : DemoMicrophone(),
                    playback: VoicePlayback(output: PlayerVoiceOutput(log: log)),
                    decoder: ToolboxVoiceDecoder()
                ) { clock.monotonicMilliseconds() }
            #else
                return nil
            #endif
        }
    }
#endif
