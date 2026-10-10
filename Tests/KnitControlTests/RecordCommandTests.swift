import Foundation
import KnitControl
import KnitMesh
import KnitSync
import Testing

/// The bridge's screen-recording commands: what they parse from, and what a recording answers through its life.
@Suite struct RecordCommandTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "knit-record-\(UInt64.random(in: 0...UInt64.max))")

    @Test func theRecordCommandsParse() {
        let cases: [(String, RecordCommand)] = [
            (#"{"cmd":"record-start"}"#, RecordCommand(.start(microphone: true))),
            (#"{"cmd":"record-start","mic":true,"tag":"t"}"#, RecordCommand(.start(microphone: true), tag: "t")),
            (#"{"cmd":"record-start","mic":false}"#, RecordCommand(.start(microphone: false))),
            (#"{"cmd":"record-stop"}"#, RecordCommand(.stop)),
            (#"{"cmd":"record-fetch"}"#, RecordCommand(.fetch(offset: 0, length: RecordCommand.chunkLimit))),
            (#"{"cmd":"record-fetch","offset":5,"length":7}"#, RecordCommand(.fetch(offset: 5, length: 7))),
            (#"{"cmd":"record-delete"}"#, RecordCommand(.delete)),
            (#"{"cmd":"record-status"}"#, RecordCommand(.status)),
        ]
        for (line, command) in cases {
            #expect(RecordCommand.parse(line) == command, "\(line)")
        }
        #expect(RecordCommand.parse(#"{"cmd":"status"}"#) == nil)
        #expect(RecordCommand.parse(#"{"cmd":"record-fetch","offset":"x"}"#) == nil)
        #expect(RecordCommand.parse("not json") == nil)
    }

    @Test func aTakeStartsStopsAndIsFetchedInChunks() async throws {
        let movie = Array((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let clock = SteppingClock()
        let recording = ScreenRecording(capture: FakeCapture(movie: movie), directory: directory, clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try reply(await RecordCommand(.start(microphone: true), tag: "s").answer(recording))
        #expect(started["ok"] as? Bool == true)
        #expect(started["recording"] as? Bool == true)
        #expect(started["startedAt"] as? Int == 1_790_300_000_000)
        #expect(started["tag"] as? String == "s")
        let again = try reply(await RecordCommand(.start(microphone: true)).answer(recording))
        #expect(again["code"] as? String == "busy")
        #expect(try reply(await RecordCommand(.status).answer(recording))["state"] as? String == "recording")

        clock.advance(by: 61_500)
        let stopLine = await RecordCommand(.stop).answer(recording)
        let stopped = try reply(stopLine)
        #expect(stopped["ok"] as? Bool == true)
        #expect(stopped["file"] as? String == "knit-1790300000000.mp4")
        #expect(stopped["bytes"] as? Int == movie.count)
        #expect(stopped["durationMs"] as? Int == 61_500)
        #expect(stopped["endedBy"] as? String == "stop")
        #expect(stopped["microphone"] as? Bool == true)
        #expect((stopped["sha256"] as? String)?.count == 64)
        #expect(await RecordCommand(.stop).answer(recording) == stopLine)

        var pulled: [UInt8] = []
        var offset = 0
        var eof = false
        while !eof {
            let chunk = try reply(await RecordCommand(.fetch(offset: Int64(offset), length: 4_000_000)).answer(recording))
            let encoded = try #require(chunk["data"] as? String)
            let data = try #require(Data(base64Encoded: encoded))
            #expect(data.count <= RecordCommand.chunkLimit)
            #expect(chunk["offset"] as? Int == offset)
            #expect(chunk["bytes"] as? Int == movie.count)
            pulled += data
            offset += data.count
            eof = try #require(chunk["eof"] as? Bool)
        }
        #expect(pulled == movie)

        let past = try reply(await RecordCommand(.fetch(offset: Int64(movie.count) + 1, length: 10)).answer(recording))
        #expect(past["code"] as? String == "range")
        let atEnd = try reply(await RecordCommand(.fetch(offset: Int64(movie.count), length: 10)).answer(recording))
        #expect(atEnd["eof"] as? Bool == true)
        #expect((atEnd["data"] as? String)?.isEmpty == true)

        let deleted = try reply(await RecordCommand(.delete).answer(recording))
        #expect(deleted["deleted"] as? String == "knit-1790300000000.mp4")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "knit-1790300000000.mp4").path))
        #expect(try reply(await RecordCommand(.fetch(offset: 0, length: 1)).answer(recording))["code"] as? String == "none")
        #expect(try reply(await RecordCommand(.stop).answer(recording))["code"] as? String == "idle")
    }

    @Test func aRecordingKnitLeavesTheFrontWithIsKeptForTheNextStop() async throws {
        let recording = ScreenRecording(capture: FakeCapture(movie: [1, 2, 3]), directory: directory, clock: SteppingClock())
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await RecordCommand(.start(microphone: true)).answer(recording)
        await recording.finishForBackground()
        let stopped = try reply(await RecordCommand(.stop).answer(recording))
        #expect(stopped["ok"] as? Bool == true)
        #expect(stopped["endedBy"] as? String == "background")
        #expect(stopped["bytes"] as? Int == 3)
    }

    @Test func aNewStartReplacesTheLastTake() async throws {
        let recording = ScreenRecording(capture: FakeCapture(movie: [9]), directory: directory, clock: SteppingClock())
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await RecordCommand(.start(microphone: false)).answer(recording)
        _ = await RecordCommand(.stop).answer(recording)
        _ = await RecordCommand(.start(microphone: false)).answer(recording)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty)
        #expect(try reply(await RecordCommand(.fetch(offset: 0, length: 1)).answer(recording))["code"] as? String == "none")
    }

    @Test func refusalsSayWhy() async throws {
        let declined = ScreenRecording(
            capture: FakeCapture(movie: [], refusal: RecordingRefusal(.declined, "the person declined")),
            directory: directory,
            clock: SteppingClock()
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let refused = try reply(await RecordCommand(.start(microphone: true)).answer(declined))
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["code"] as? String == "declined")
        #expect(refused["error"] as? String == "the person declined")
        #expect(try reply(await RecordCommand(.status).answer(declined))["state"] as? String == "idle")

        let lost = ScreenRecording(capture: FakeCapture(movie: [1]), directory: directory, clock: SteppingClock())
        _ = await RecordCommand(.start(microphone: true)).answer(lost)
        await lost.lose("a call took the screen")
        let stop = try reply(await RecordCommand(.stop).answer(lost))
        #expect(stop["code"] as? String == "lost")
        #expect(stop["error"] as? String == "a call took the screen")
        #expect(try reply(await RecordCommand(.stop).answer(lost))["code"] as? String == "idle")
    }

    @Test func aStartNobodyAnswersTimesOutAndALateStartIsStopped() async throws {
        let capture = FakeCapture(movie: [1], hold: true)
        let recording = ScreenRecording(capture: capture, directory: directory, clock: SteppingClock(hurried: true))
        defer { try? FileManager.default.removeItem(at: directory) }
        let timedOut = try reply(await RecordCommand(.start(microphone: true)).answer(recording))
        #expect(timedOut["code"] as? String == "timeout")
        #expect(try reply(await RecordCommand(.status).answer(recording))["state"] as? String == "idle")
        capture.release()
        for _ in 0..<200 where capture.ends == 0 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(capture.ends == 1)
    }

    private func reply(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

/// A capture that writes `movie` at each end, refuses with `refusal`, or holds each begin until ``release()``.
private final class FakeCapture: ScreenCapture {
    private let movie: [UInt8]
    private let refusal: RecordingRefusal?
    private struct State {
        var holding: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
        var ends = 0
    }

    private let held: Lock<State>

    init(movie: [UInt8], refusal: RecordingRefusal? = nil, hold: Bool = false) {
        self.movie = movie
        self.refusal = refusal
        held = Lock(State(holding: hold))
    }

    var ends: Int {
        held.withLock { $0.ends }
    }

    func release() {
        let waiters = held.withLock { state in
            state.holding = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func begin(microphone _: Bool) async throws(RecordingRefusal) {
        await withCheckedContinuation { continuation in
            let wait = held.withLock { state in
                if state.holding {
                    state.waiters.append(continuation)
                }
                return state.holding
            }
            if !wait {
                continuation.resume()
            }
        }
        if let refusal {
            throw refusal
        }
    }

    // swiftlint:disable:next async_without_await - the protocol's end is async; this fake writes at once.
    func end(writingTo file: URL) async throws(RecordingRefusal) {
        held.withLock { $0.ends += 1 }
        guard FileManager.default.createFile(atPath: file.path, contents: Data(movie)) else {
            throw RecordingRefusal(.failed, "could not write \(file.lastPathComponent)")
        }
    }
}

/// Clocks that move only when told; a sleeper waits until it is cancelled, or wakes at once when `hurried`.
private final class SteppingClock: MeshClock {
    private let monotonic = Lock<Int64>(1000)
    private let hurried: Bool

    init(hurried: Bool = false) {
        self.hurried = hurried
    }

    func advance(by milliseconds: Int64) {
        monotonic.withLock { $0 += milliseconds }
    }

    func wallMilliseconds() -> Int64 {
        1_790_300_000_000
    }

    func monotonicMilliseconds() -> Int64 {
        monotonic.withLock { $0 }
    }

    func sleep(untilMonotonic _: Int64) async throws {
        if !hurried {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
