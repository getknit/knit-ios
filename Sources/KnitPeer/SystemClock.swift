import Foundation
public import KnitMesh

/// The real clocks, for a node that runs on a device rather than in a test: the wall clock for dating frames, and
/// `ContinuousClock` for timers, which keeps counting while the machine sleeps, as Android's elapsed-realtime clock
/// does.
public struct SystemClock: MeshClock {
    private static let millisecondsPerSecond: Int64 = 1000
    private static let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    /// Where the monotonic reading starts, so that no deadline is ever zero or negative.
    private static let base: Int64 = 1000

    private let origin = ContinuousClock.now

    /// Clocks that start now.
    public init() {
        // Nothing to set up: the origin is the moment of creation.
    }

    public func wallMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * Double(Self.millisecondsPerSecond)).rounded(.down))
    }

    public func monotonicMilliseconds() -> Int64 {
        Self.base + Self.milliseconds(ContinuousClock.now - origin)
    }

    public func sleep(untilMonotonic deadline: Int64) async throws {
        try await Task.sleep(until: origin.advanced(by: .milliseconds(deadline - Self.base)), clock: .continuous)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * millisecondsPerSecond + attoseconds / attosecondsPerMillisecond
    }
}
