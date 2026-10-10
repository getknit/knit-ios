import Foundation

/// The bridge's screen-recording commands, which a debug build of the app answers for knit-next's demo film
/// (ADR 2026-10.x2cq):
///
/// - `{"cmd":"record-start","mic":true}`: records the screen, with the microphone unless `"mic":false`, and answers
///   once recording runs. iOS may first ask the person holding the phone.
/// - `{"cmd":"record-stop"}`: stops, and answers with the finished file's name, size, SHA-256 and duration.
/// - `{"cmd":"record-fetch","offset":0,"length":1048576}`: up to ``chunkLimit`` bytes of the finished file, in base64.
/// - `{"cmd":"record-delete"}`: deletes the finished file.
/// - `{"cmd":"record-status"}`: whether it records, and the finished file if there is one.
public struct RecordCommand: Equatable, Sendable {
    /// The most bytes one `record-fetch` returns, about 1.4 MB of base64 on its reply line.
    public static let chunkLimit: Int64 = 1_048_576

    /// What the command asks.
    public enum Action: Equatable, Sendable {
        /// `record-start`.
        case start(microphone: Bool)
        /// `record-stop`.
        case stop
        /// `record-fetch`: `length` bytes from `offset`, before ``RecordCommand/chunkLimit`` caps them.
        case fetch(offset: Int64, length: Int64)
        /// `record-delete`.
        case delete
        /// `record-status`.
        case status
    }

    /// What it asks.
    public let action: Action
    /// Echoed as `"tag"` on the reply.
    public let tag: String?

    /// A command, as a caller builds one.
    public init(_ action: Action, tag: String? = nil) {
        self.action = action
        self.tag = tag
    }

    private struct Raw: Decodable {
        var cmd: String
        var mic: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var offset: Int64?
        var length: Int64?
        var tag: String?
    }

    /// The command on `line`, when it is one of these.
    public static func parse(_ line: String) -> Self? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else {
            return nil
        }
        let asked: Action
        switch raw.cmd {
        case "record-start":
            asked = .start(microphone: raw.mic ?? true)
        case "record-stop":
            asked = .stop
        case "record-fetch":
            asked = .fetch(offset: raw.offset ?? 0, length: raw.length ?? chunkLimit)
        case "record-delete":
            asked = .delete
        case "record-status":
            asked = .status
        default:
            return nil
        }
        return Self(asked, tag: raw.tag)
    }

    /// The name a reply carries back.
    public var name: String {
        switch action {
        case .start:
            "record-start"
        case .stop:
            "record-stop"
        case .fetch:
            "record-fetch"
        case .delete:
            "record-delete"
        case .status:
            "record-status"
        }
    }

    /// Does what the command asks of `recording`, and answers.
    public func answer(_ recording: ScreenRecording) async -> String {
        var reply: [String: JSONValue] = ["reply": .string(name)]
        if let tag {
            reply["tag"] = .string(tag)
        }
        let outcome: Result<[String: JSONValue], RecordingRefusal>
        switch action {
        case .start(let microphone):
            outcome = await recording.start(microphone: microphone)
        case .stop:
            outcome = await recording.stop()
        case .fetch(let offset, let length):
            outcome = await recording.fetch(offset: offset, length: length)
        case .delete:
            outcome = await recording.delete()
        case .status:
            outcome = .success(await recording.status())
        }
        switch outcome {
        case .success(let fields):
            reply.merge(fields) { _, field in field }
            reply["ok"] = true
        case .failure(let refusal):
            reply["ok"] = false
            reply["code"] = .string(refusal.code.rawValue)
            reply["error"] = .string(refusal.reason)
        }
        return JSONValue.object(reply).line
    }
}

/// Why a recording command did not do what it asked: a `code` a script branches on, and a `reason` a person reads.
public struct RecordingRefusal: Error, Equatable, Sendable {
    /// The kinds of refusal, as `"code"` on the reply.
    public enum Code: String, Sendable {
        /// The person holding the phone said no to recording.
        case declined = "declined"
        /// The phone cannot record now: ReplayKit is unavailable, or a call or AirPlay holds the screen.
        case unavailable = "unavailable"
        /// Nobody answered iOS's question in time.
        case timeout = "timeout"
        /// A recording is already starting, running or finishing.
        case busy = "busy"
        /// Nothing is recording.
        case idle = "idle"
        /// iOS stopped the recording itself, and kept nothing.
        case lost = "lost"
        /// There is no finished file.
        case noTake = "none"
        /// The offset or length is outside the file.
        case range = "range"
        /// Anything else, with iOS's reason.
        case failed = "failed"
    }

    /// What kind of refusal.
    public let code: Code
    /// What happened, for a person.
    public let reason: String

    /// A refusal of kind `code`, for `reason`.
    public init(_ code: Code, _ reason: String) {
        self.code = code
        self.reason = reason
    }
}
