import KnitCrypto
import KnitWire
import Testing

@testable import KnitAppCore

/// The app's one voice-note player (knit-next ADR 034, `VoicePlayer.kt`): a tap toggles the loaded note and stops any
/// other, a seek moves the loaded note only, a note played out lets go, the system's pause keeps the place, and bytes
/// that don't play say so.
@MainActor
@Suite struct VoicePlaybackTests {
    /// A player the test steers.
    @MainActor
    final class FakeOutput: VoiceOutput {
        var plays = true
        var position = 0
        var state = VoiceOutputState.finished
        private(set) var played: [[UInt8]] = []
        private(set) var calls: [String] = []

        func play(_ bytes: [UInt8], from milliseconds: Int) -> Bool {
            calls.append("play \(milliseconds)")
            guard plays else {
                return false
            }
            played.append(bytes)
            position = milliseconds
            state = .playing
            return true
        }

        func pause() {
            calls.append("pause")
            state = .paused
        }

        func resume() {
            calls.append("resume")
            state = .playing
        }

        func seek(to milliseconds: Int) {
            calls.append("seek \(milliseconds)")
            position = milliseconds
        }

        func stop() {
            calls.append("stop")
            state = .finished
        }
    }

    let output = FakeOutput()
    let first = BlobHash(of: [1])
    let second = BlobHash(of: [2])

    @Test func aTapPlaysAndASecondPausesAndAThirdPlaysOn() async {
        let playback = VoicePlayback(output: output)
        await playback.toggle(first) { [1, 1] }
        #expect(output.played == [[1, 1]])
        #expect(playback.nowPlaying == .init(hash: first, position: 0, playing: true))
        output.position = 1200
        playback.tick()
        #expect(playback.position(of: first)?.position == 1200)
        #expect(playback.position(of: second) == nil)

        await playback.toggle(first) {
            Issue.record("a loaded note isn't read again")
            return nil
        }
        #expect(output.calls.last == "pause")
        #expect(playback.nowPlaying?.playing == false)
        await playback.toggle(first) { nil }
        #expect(output.calls.last == "resume")
        #expect(playback.nowPlaying?.playing == true)
    }

    @Test func aTapOnAnotherNoteStopsTheFirst() async {
        let playback = VoicePlayback(output: output)
        await playback.toggle(first) { [1] }
        await playback.toggle(second) { [2] }
        #expect(output.calls == ["play 0", "stop", "play 0"])
        #expect(playback.nowPlaying?.hash == second)
    }

    /// A seek moves the loaded note, playing or paused, and a note that isn't loaded has nothing to move.
    @Test func aSeekMovesTheLoadedNoteOnly() async {
        let playback = VoicePlayback(output: output)
        playback.seek(first, to: 500)
        #expect(output.calls.isEmpty)
        await playback.toggle(first) { [1] }
        await playback.toggle(first) { nil }
        playback.seek(first, to: 3000)
        #expect(output.calls.last == "seek 3000")
        #expect(playback.nowPlaying == .init(hash: first, position: 3000, playing: false), "a seek doesn't play on")
        playback.seek(second, to: 100)
        #expect(output.calls.last == "seek 3000")
        playback.seek(first, to: -5)
        #expect(output.calls.last == "seek 0")
    }

    /// A note played to its end lets go, and its bubble shows its length again.
    @Test func aNotePlayedOutLetsGo() async {
        let playback = VoicePlayback(output: output)
        await playback.toggle(first) { [1] }
        output.state = .finished
        playback.tick()
        #expect(playback.nowPlaying == nil)
    }

    /// A call or the headphones leaving pauses the player itself: the bubble shows it paused at its place.
    @Test func theSystemsPauseKeepsThePlace() async {
        let playback = VoicePlayback(output: output)
        await playback.toggle(first) { [1] }
        output.position = 4200
        output.state = .paused
        playback.tick()
        #expect(playback.nowPlaying == .init(hash: first, position: 4200, playing: false))
        await playback.toggle(first) { nil }
        #expect(output.calls.last == "resume")
    }

    @Test func leavingPausesAndClosingStops() async {
        let playback = VoicePlayback(output: output)
        playback.pause()
        playback.stop()
        #expect(output.calls.isEmpty, "with nothing loaded there is nothing to do")
        await playback.toggle(first) { [1] }
        output.position = 800
        playback.pause()
        #expect(playback.nowPlaying == .init(hash: first, position: 800, playing: false))
        playback.stop()
        #expect(playback.nowPlaying == nil)
        #expect(output.calls.last == "stop")
    }

    /// Bytes that are missing or don't play mark the note, until a later tap plays it.
    @Test func bytesThatDoNotPlaySaySo() async {
        let playback = VoicePlayback(output: output)
        await playback.toggle(first) { nil }
        #expect(playback.unplayable == [first])
        output.plays = false
        await playback.toggle(second) { [2] }
        #expect(playback.unplayable == [first, second])
        #expect(playback.nowPlaying == nil)
        output.plays = true
        await playback.toggle(second) { [2] }
        #expect(playback.unplayable == [first])
        #expect(playback.nowPlaying?.hash == second)
    }

    /// Bytes that load after a later tap play nothing: the later tap wins.
    @Test func aSlowLoadLosesToALaterTap() async {
        let playback = VoicePlayback(output: output)
        let (slow, release) = AsyncStream.makeStream(of: Void.self)
        let (reading, started) = AsyncStream.makeStream(of: Void.self)
        async let late: Void = playback.toggle(first) {
            started.yield()
            for await _ in slow {
                break
            }
            return [1]
        }
        for await _ in reading {
            break
        }
        await playback.toggle(second) { [2] }
        release.yield()
        await late
        #expect(output.played == [[2]])
        #expect(playback.nowPlaying?.hash == second)
    }
}
