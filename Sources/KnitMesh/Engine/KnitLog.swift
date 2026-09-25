/// Where the mesh writes what it did: links, drops, relays. Debug builds of the app send it to the unified log,
/// the Linux peer writes JSON lines, and tests ignore it. `print` is banned in `Sources/`, so this is the only way
/// out.
public protocol KnitLog: Sendable {
    /// Writes one line. The message is built only if the log keeps it.
    func log(_ level: LogLevel, _ message: @autoclosure () -> String)
}

/// How much a log line matters.
public enum LogLevel: Sendable, Comparable {
    /// Routine detail, for debugging a session.
    case debug
    /// A state change worth keeping: a link up or down, a profile pinned.
    case info
    /// Something went wrong that the mesh recovered from.
    case warning
}

/// A log that keeps nothing.
public struct SilentLog: KnitLog {
    /// Makes a silent log.
    public init() {
        // Nothing to set up.
    }

    public func log(_: LogLevel, _: @autoclosure () -> String) {
        // Discarded unbuilt.
    }
}
