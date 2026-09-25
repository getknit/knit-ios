/// Where the mesh reads time. Nothing in the protocol targets reads a clock any other way, so a test drives
/// every timer and every expiry by hand (`.agents/context/architecture.md`).
///
/// There are two clocks because they answer different questions. The wall clock dates frames: `sentAt`,
/// custody expiry and profile stamps, all compared across devices. The monotonic clock times things on this
/// device: relay jitter, the seen window, HELLO and connect timeouts, backoff. It never jumps when the user
/// changes the time, and it keeps counting while the device sleeps.
public protocol MeshClock: Sendable {
    /// The wall clock, in milliseconds since the epoch.
    func wallMilliseconds() -> Int64

    /// The monotonic clock, in milliseconds from an arbitrary origin.
    func monotonicMilliseconds() -> Int64

    /// Suspends until the monotonic clock reads at least `deadline`, or throws when the task is cancelled.
    func sleep(untilMonotonic deadline: Int64) async throws
}
