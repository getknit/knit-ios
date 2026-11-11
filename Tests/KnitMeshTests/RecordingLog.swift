import KnitMesh
import KnitSync

/// A log that keeps every line, so a test can read what the mesh said and every message is built.
final class RecordingLog: KnitLog {
    private let lines = Lock<[String]>([])

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let line = "\(level) \(message())"
        lines.withLock { $0.append(line) }
    }

    /// Every line so far.
    var all: [String] {
        lines.withLock { $0 }
    }
}
