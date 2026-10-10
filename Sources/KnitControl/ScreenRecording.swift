import Crypto
public import Foundation
public import KnitMesh

/// What records the screen for ``ScreenRecording``: ReplayKit in a debug build of the app.
public protocol ScreenCapture: Sendable {
    /// Starts recording, with the microphone when `microphone` is set, and returns once recording runs. iOS may first
    /// ask the person holding the phone, so this can take as long as they do.
    func begin(microphone: Bool) async throws(RecordingRefusal)

    /// Stops recording and writes what it recorded to `file`, which does not exist yet.
    func end(writingTo file: URL) async throws(RecordingRefusal)
}

/// One finished recording, kept in ``ScreenRecording``'s directory until it is deleted or a new one starts.
public struct RecordingTake: Equatable, Sendable {
    /// The file's name in the directory.
    public let file: String
    /// Its size.
    public let bytes: Int64
    /// Its SHA-256, in lowercase hex.
    public let sha256: String
    /// When recording began, in wall milliseconds.
    public let startedAt: Int64
    /// How long it ran, in milliseconds, from the start's answer to the stop.
    public let durationMs: Int64
    /// Whether the microphone was asked for.
    public let microphone: Bool
    /// What ended it: `stop`, for `record-stop`, or `background`, when Knit left the front.
    public let endedBy: String

    var json: [String: JSONValue] {
        [
            "file": .string(file),
            "bytes": .int(bytes),
            "sha256": .string(sha256),
            "startedAt": .int(startedAt),
            "durationMs": .int(durationMs),
            "microphone": .bool(microphone),
            "endedBy": .string(endedBy),
        ]
    }
}

/// The bridge's screen recordings (``RecordCommand``): one at a time, and the last finished one kept as a file in
/// `directory` until a script fetches and deletes it, or a new recording replaces it. Nothing here outlives the app:
/// a relaunch starts with no recording and clears the directory at the next start.
public actor ScreenRecording {
    private enum Phase {
        case idle
        case starting
        case recording(startedAt: Int64, monotonic: Int64, microphone: Bool)
        case finishing(Task<Result<RecordingTake, RecordingRefusal>, Never>)
    }

    /// How long `record-start` waits for the person holding the phone to answer iOS's question.
    public static let consentWaitMilliseconds: Int64 = 120_000
    /// What the hash reads at a time: 4 MiB.
    private static let hashChunk = 4_194_304

    private let capture: any ScreenCapture
    private let directory: URL
    private let clock: any MeshClock
    private var phase = Phase.idle
    private var take: RecordingTake?
    /// Why iOS ended the last recording itself, told once to the next `record-stop`.
    private var lost: String?

    /// Recordings made by `capture` into `directory`, dated by `clock`.
    public init(capture: any ScreenCapture, directory: URL, clock: any MeshClock) {
        self.capture = capture
        self.directory = directory
        self.clock = clock
    }

    /// Starts a recording, in place of the last finished one.
    func start(microphone: Bool) async -> Result<[String: JSONValue], RecordingRefusal> {
        guard case .idle = phase else {
            return .failure(RecordingRefusal(.busy, "a recording is already running"))
        }
        phase = .starting
        lost = nil
        take = nil
        clear()
        switch await begin(microphone: microphone) {
        case .success:
            let startedAt = clock.wallMilliseconds()
            phase = .recording(startedAt: startedAt, monotonic: clock.monotonicMilliseconds(), microphone: microphone)
            return .success(["recording": true, "microphone": .bool(microphone), "startedAt": .int(startedAt)])
        case .failure(let refusal):
            phase = .idle
            return .failure(refusal)
        }
    }

    /// Stops the recording and answers with the file. Asked again, it answers with the same file, which is how a
    /// script learns of a recording that ended when Knit left the front.
    func stop() async -> Result<[String: JSONValue], RecordingRefusal> {
        switch phase {
        case .starting:
            return .failure(RecordingRefusal(.busy, "the recording is still starting"))
        case .idle:
            if let lost {
                self.lost = nil
                return .failure(RecordingRefusal(.lost, lost))
            }
            guard let take else {
                return .failure(RecordingRefusal(.idle, "nothing is recording"))
            }
            return .success(take.json)
        case .recording, .finishing:
            return await finish(endedBy: "stop").map(\.json)
        }
    }

    /// Ends a running recording and keeps what it recorded, because Knit is leaving the front and iOS is about to
    /// suspend it.
    public func finishForBackground() async {
        if case .recording = phase {
            _ = await finish(endedBy: "background")
        }
    }

    /// iOS ended the recording itself, keeping nothing, for `reason`.
    public func lose(_ reason: String) {
        guard case .recording = phase else {
            return
        }
        phase = .idle
        lost = reason
    }

    /// Up to ``RecordCommand/chunkLimit`` bytes of the finished file from `offset`, in base64.
    func fetch(offset: Int64, length: Int64) async -> Result<[String: JSONValue], RecordingRefusal> {
        guard let take else {
            return .failure(RecordingRefusal(.noTake, "there is no finished recording"))
        }
        guard offset >= 0, offset <= take.bytes, length > 0 else {
            return .failure(RecordingRefusal(.range, "offset \(offset) and length \(length) do not fit a file of \(take.bytes) bytes"))
        }
        let count = min(length, RecordCommand.chunkLimit, take.bytes - offset)
        let url = directory.appending(path: take.file)
        let read: Data? = count == 0 ? Data() : await Task.detached { Self.read(url, offset: offset, count: count) }.value
        guard let data = read, Int64(data.count) == count else {
            return .failure(RecordingRefusal(.failed, "could not read \(take.file)"))
        }
        return .success([
            "file": .string(take.file),
            "offset": .int(offset),
            "length": .int(count),
            "bytes": .int(take.bytes),
            "eof": .bool(offset + count >= take.bytes),
            "data": .string(data.base64EncodedString()),
        ])
    }

    /// Deletes the finished file, if there is one.
    func delete() -> Result<[String: JSONValue], RecordingRefusal> {
        let deleted = take?.file
        if take != nil {
            take = nil
            clear()
        }
        return .success(["deleted": .text(deleted)])
    }

    /// Whether it records, since when, and the finished file.
    func status() -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["take": take.map { .object($0.json) } ?? .null, "lost": .text(lost)]
        switch phase {
        case .idle:
            fields["state"] = "idle"
        case .starting:
            fields["state"] = "starting"
        case .recording(let startedAt, _, let microphone):
            fields["state"] = "recording"
            fields["startedAt"] = .int(startedAt)
            fields["microphone"] = .bool(microphone)
        case .finishing:
            fields["state"] = "finishing"
        }
        return fields
    }

    /// Waits for `capture` to start, or for the consent wait to run out. A start that comes after the wait ran out is
    /// stopped, and what it recorded thrown away, so nothing records that the script thinks is off.
    private func begin(microphone: Bool) async -> Result<Void, RecordingRefusal> {
        let source = capture
        let starting = Task { () -> Result<Void, RecordingRefusal> in
            do throws(RecordingRefusal) {
                try await source.begin(microphone: microphone)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let (outcomes, continuation) = AsyncStream<Result<Void, RecordingRefusal>>.makeStream()
        Task {
            continuation.yield(await starting.value)
        }
        let deadline = clock.monotonicMilliseconds() + Self.consentWaitMilliseconds
        let timing = clock
        let timer = Task {
            try await timing.sleep(untilMonotonic: deadline)
            continuation.yield(.failure(RecordingRefusal(.timeout, "nobody answered iOS's screen recording question in time")))
        }
        var iterator = outcomes.makeAsyncIterator()
        let first = await iterator.next() ?? .failure(RecordingRefusal(.failed, "the start was cancelled"))
        timer.cancel()
        continuation.finish()
        if case .failure(let refusal) = first, refusal.code == .timeout {
            let scratch = directory.appending(path: "late-start.mp4")
            Task {
                if case .success = await starting.value {
                    try? await source.end(writingTo: scratch)
                    try? FileManager.default.removeItem(at: scratch)
                }
            }
        }
        return first
    }

    /// Stops a running recording, or waits for the stop already under way.
    private func finish(endedBy: String) async -> Result<RecordingTake, RecordingRefusal> {
        if case .finishing(let running) = phase {
            return await running.value
        }
        guard case .recording(let startedAt, let began, let microphone) = phase else {
            return .failure(RecordingRefusal(.idle, "nothing is recording"))
        }
        let durationMs = clock.monotonicMilliseconds() - began
        let name = "knit-\(startedAt).mp4"
        let url = directory.appending(path: name)
        let source = capture
        let running = Task { () -> Result<RecordingTake, RecordingRefusal> in
            do throws(RecordingRefusal) {
                try await source.end(writingTo: url)
            } catch {
                return .failure(error)
            }
            guard let (bytes, sha256) = await Task.detached(operation: { Self.measure(url) }).value else {
                return .failure(RecordingRefusal(.failed, "iOS wrote no file at \(name)"))
            }
            return .success(
                RecordingTake(
                    file: name,
                    bytes: bytes,
                    sha256: sha256,
                    startedAt: startedAt,
                    durationMs: durationMs,
                    microphone: microphone,
                    endedBy: endedBy
                ))
        }
        phase = .finishing(running)
        let outcome = await running.value
        phase = .idle
        if case .success(let finished) = outcome {
            take = finished
        }
        return outcome
    }

    /// Removes every file in the directory, and makes it if it is missing.
    private func clear() {
        let files = FileManager.default
        try? files.removeItem(at: directory)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func read(_ url: URL, offset: Int64, count: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else {
            return nil
        }
        return try? handle.read(upToCount: Int(count))
    }

    /// The file's size and SHA-256, read a few megabytes at a time so a long recording never sits in memory whole.
    private static func measure(_ url: URL) -> (Int64, String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try? handle.read(upToCount: hashChunk), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
