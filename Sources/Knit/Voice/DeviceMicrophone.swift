// Every file in Voice/ compiles into a debug build alone while voice notes are (`AppEnvironment.voiceNotes`): a store
// build carries no microphone key, and App Store Connect flags a binary whose code reaches the microphone without one.
#if os(iOS) && DEBUG
    import AVFAudio
    import KnitAppCore

    /// The microphone's permission, as the recorder asks it (knit-next ADR 034's `MicGate`): read on the press that needs
    /// it, and asked without recording, since the finger has gone by the time the answer comes.
    internal struct DeviceMicrophone: MicrophoneAccess {
        var authorization: MicrophoneAuthorization {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                .notDetermined
            case .granted:
                .allowed
            case .denied:
                .denied
            @unknown default:
                .denied
            }
        }

        func request() async -> MicrophoneAuthorization {
            await AVAudioApplication.requestRecordPermission() ? .allowed : .denied
        }
    }
#endif
