#if os(iOS) && DEBUG
    import AVFoundation

    /// Whether a voice note's bytes would play, for the debug bridge's `voice` command, which can't reach AVFoundation
    /// itself.
    internal enum VoiceProbe {
        /// Whether `bytes` load and prepare in a player, as ``PlayerVoiceOutput`` opens them, without playing.
        static func plays(_ bytes: [UInt8]) -> Bool {
            (try? AVAudioPlayer(data: Data(bytes)))?.prepareToPlay() ?? false
        }
    }
#endif
