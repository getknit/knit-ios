public import KnitMesh

/// A ``KnitLog`` that writes each line kept as a JSON line, `{"log":"info","message":"…"}`, through `write`: standard
/// error for `knit-peer`, so that standard output carries only control replies and events. Given a clock, each line
/// also carries `"ms"`, its wall-clock time, so a run's log lines up with a phone's logcat.
public struct JSONLinesLog: KnitLog {
    private let threshold: LogLevel
    private let clock: (any MeshClock)?
    private let write: @Sendable (String) -> Void

    /// A log that keeps `threshold` and above, stamped from `clock` when there is one.
    @preconcurrency
    public init(threshold: LogLevel, clock: (any MeshClock)? = nil, write: @escaping @Sendable (String) -> Void) {
        self.threshold = threshold
        self.clock = clock
        self.write = write
    }

    /// The level named `debug`, `info` or `warning`.
    public static func level(named name: String) -> LogLevel? {
        switch name {
        case "debug":
            .debug
        case "info":
            .info
        case "warning":
            .warning
        default:
            nil
        }
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= threshold else {
            return
        }
        var fields: [String: JSONValue] = ["log": .string(Self.name(of: level)), "message": .string(message())]
        if let clock {
            fields["ms"] = .int(clock.wallMilliseconds())
        }
        write(JSONValue.object(fields).line)
    }

    private static func name(of level: LogLevel) -> String {
        switch level {
        case .debug:
            "debug"
        case .info:
            "info"
        case .warning:
            "warning"
        }
    }
}
