#if os(iOS) && DEBUG
    import AVFoundation
    import KnitAppCore
    import KnitMesh

    /// Where voice notes play (knit-next ADR 034's `VoicePlayer`): `AVAudioPlayer` reading the note's plaintext from
    /// memory, so a sealed note is never written out. The player reads the type from the bytes, so a picked file's
    /// container plays as well as a recorded note's ADTS.
    ///
    /// Playing takes the session for spoken audio and pauses whatever else plays, as Android's transient focus does, and
    /// a pause gives it back. The system pausing it, for a call or Siri or the headphones leaving, leaves it paused at its
    /// place, which ``VoicePlayback`` reads at its next tick, as Android's focus loss does.
    @MainActor
    internal final class PlayerVoiceOutput: NSObject, VoiceOutput {
        private let log: any KnitLog
        private var player: AVAudioPlayer?
        /// Whether the loaded note played to its end, which the player's delegate says.
        private var playedOut = false

        /// A player logging to `log`.
        init(log: any KnitLog) {
            self.log = log
            super.init()
            // The app makes one player for its life (`AppEnvironment.voiceNotes`), so the observer is never removed. It
            // holds the player weakly, so it does nothing once the player has gone.
            // swiftlint:disable:next discarded_notification_center_observer - it is never removed, as said above.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(
                    AVAudioSession.RouteChangeReason.init)
                guard reason == .oldDeviceUnavailable else {
                    return
                }
                MainActor.assumeIsolated { self?.pause() }
            }
        }

        func play(_ bytes: [UInt8], from milliseconds: Int) -> Bool {
            stop()
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let loaded = try AVAudioPlayer(data: Data(bytes))
                loaded.delegate = self
                guard loaded.prepareToPlay() else {
                    log.log(.warning, "voice: the player would not prepare \(bytes.count) bytes")
                    deactivate()
                    return false
                }
                loaded.currentTime = Self.seconds(milliseconds)
                guard loaded.play() else {
                    log.log(.warning, "voice: the player would not play")
                    deactivate()
                    return false
                }
                player = loaded
                playedOut = false
                return true
            } catch {
                log.log(.warning, "voice: the player would not open \(bytes.count) bytes: \(error)")
                deactivate()
                return false
            }
        }

        func pause() {
            guard let player, player.isPlaying else {
                return
            }
            player.pause()
            deactivate()
        }

        func resume() {
            guard let player else {
                return
            }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }

        func seek(to milliseconds: Int) {
            player?.currentTime = Self.seconds(milliseconds)
        }

        func stop() {
            guard let player else {
                return
            }
            player.stop()
            self.player = nil
            deactivate()
        }

        var position: Int {
            Int(((player?.currentTime ?? 0) * Self.millisecondsPerSecond).rounded(.down))
        }

        var state: VoiceOutputState {
            guard let player, !playedOut else {
                return .finished
            }
            // Anything else not playing was paused: by a tap, or by the system for a call, Siri or a route that left.
            return player.isPlaying ? .playing : .paused
        }

        /// The delegate's word that `finished` played to its end, if it is still the note loaded.
        private func played(_ finished: AVAudioPlayer) {
            guard finished === player else {
                return
            }
            playedOut = true
            deactivate()
        }

        private func deactivate() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private static let millisecondsPerSecond = 1000.0

        private static func seconds(_ milliseconds: Int) -> TimeInterval {
            TimeInterval(max(milliseconds, 0)) / millisecondsPerSecond
        }
    }

    extension PlayerVoiceOutput: AVAudioPlayerDelegate {
        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
            Task { @MainActor [weak self] in
                self?.played(player)
            }
        }
    }
#endif
