public import KnitWire
public import Observation

/// What the player reports, read at each tick.
public enum VoiceOutputState: Sendable, Equatable {
    /// Playing.
    case playing
    /// Paused, by a tap or by the system: a call, Siri, or the headphones leaving.
    case paused
    /// Played to the end, or stopped.
    case finished
}

/// Where voice notes play: AVFoundation in the app, a stand-in in tests. It plays from memory, since a sealed note is
/// opened in memory and never written out (knit-next ADR 034).
@preconcurrency
@MainActor
public protocol VoiceOutput: AnyObject {
    /// Loads `bytes` and plays them from `milliseconds` in, or answers false when they don't play.
    func play(_ bytes: [UInt8], from milliseconds: Int) -> Bool
    /// Pauses, keeping the place.
    func pause()
    /// Plays on from the place it paused at.
    func resume()
    /// Moves the place to `milliseconds` in, playing or paused.
    func seek(to milliseconds: Int)
    /// Stops and lets the note go.
    func stop()
    /// Where it is, in milliseconds from the start.
    var position: Int { get }
    /// What it is doing.
    var state: VoiceOutputState { get }
}

/// The app's one voice-note player (`VoicePlayer`, a Koin single in knit-next): one note at a time, anywhere in the
/// app. A tap on the playing note pauses it and another tap plays on; a tap on another note stops the first. A tap on
/// the waveform moves the loaded note only, playing or paused. A note played to its end lets go, and its bubble shows
/// its length again. The app ticks it every ``tickMilliseconds`` while a note plays, and the bubbles read
/// ``nowPlaying`` from the environment, so the moving bars reconfigure no cell (ADR 2026-10.pkbu, as `PhotoArrivals`).
@preconcurrency
@MainActor
@Observable
public final class VoicePlayback {
    /// How often a playing note's place is read (`TICK_MS`, `VoicePlayer.kt:241`).
    nonisolated public static let tickMilliseconds = 60

    /// The note loaded, and how far in it is.
    public struct NowPlaying: Sendable, Equatable {
        /// The blob the note is stored under: a message's attachment hash, or a held note's own.
        public var hash: BlobHash
        /// Where it is, in milliseconds from the start.
        public var position: Int
        /// Whether it is playing, rather than paused.
        public var playing: Bool
    }

    @ObservationIgnored private let output: any VoiceOutput
    /// Counts taps, so bytes that load after a later tap play nothing.
    @ObservationIgnored private var taps = 0

    /// The note loaded, or `nil` when none is.
    public private(set) var nowPlaying: NowPlaying?
    /// The notes whose bytes didn't play, which their bubbles say ("Can't play this voice message").
    public private(set) var unplayable: Set<BlobHash> = []

    /// A player over `output`.
    public init(output: any VoiceOutput) {
        self.output = output
    }

    /// Where `hash`'s note is, if it is the one loaded.
    public func position(of hash: BlobHash) -> NowPlaying? {
        nowPlaying.flatMap { $0.hash == hash ? $0 : nil }
    }

    /// A tap on a note's play button. The loaded note pauses or plays on; any other stops what is loaded, then plays
    /// from the start once `bytes` hands over its plaintext, read off the main actor (`AppSession.attachment`).
    @preconcurrency
    public func toggle(_ hash: BlobHash, bytes: @Sendable () async -> [UInt8]?) async {
        if let loaded = nowPlaying, loaded.hash == hash {
            if loaded.playing {
                output.pause()
            } else {
                output.resume()
            }
            nowPlaying?.playing.toggle()
            return
        }
        stop()
        taps += 1
        let tap = taps
        let plaintext = await bytes()
        guard tap == taps else {
            return
        }
        guard let plaintext, output.play(plaintext, from: 0) else {
            unplayable.insert(hash)
            return
        }
        unplayable.remove(hash)
        nowPlaying = NowPlaying(hash: hash, position: 0, playing: true)
    }

    /// A tap on the waveform at `milliseconds` in: it moves the loaded note, playing or paused, and nothing else, since
    /// a note that isn't loaded has nothing to move (`VoicePlayer.seek`).
    public func seek(_ hash: BlobHash, to milliseconds: Int) {
        guard nowPlaying?.hash == hash else {
            return
        }
        let place = max(milliseconds, 0)
        output.seek(to: place)
        nowPlaying?.position = place
    }

    /// Reads the player's place. A note played to its end lets go, and one the system paused shows paused, keeping its
    /// place, as Android's focus loss does (`VoicePlayer.kt:71-78`).
    public func tick() {
        guard nowPlaying != nil else {
            return
        }
        switch output.state {
        case .finished:
            nowPlaying = nil
        case .paused:
            nowPlaying?.playing = false
            nowPlaying?.position = output.position
        case .playing:
            nowPlaying?.playing = true
            nowPlaying?.position = output.position
        }
    }

    /// Knit left the screen, or the thread closed: the note pauses where it is.
    public func pause() {
        guard nowPlaying?.playing == true else {
            return
        }
        output.pause()
        nowPlaying?.playing = false
        nowPlaying?.position = output.position
    }

    /// Stops and lets the note go, as a tap on another note or a closed thread does (`ChatViewModel.onCleared`).
    public func stop() {
        taps += 1
        guard nowPlaying != nil else {
            return
        }
        output.stop()
        nowPlaying = nil
    }
}
