/// The run's switches for device trials, apart from `PeerCommand.swift` to keep its length in bounds.
extension RunOptions {
    /// The longest `--stop-reading-after` taken: a day.
    static let longestStopReadingAfter = 86_400

    /// `--stop-reading-after SECONDS`, or `nil` when not given: the far end's writes to the peer stall once it stops
    /// reading, which that end's overfull bound and stall close are tried against (ADR 2026-10.f5zs).
    static func stopReadingAfter(_ text: String?) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let seconds = Int(text), (0...longestStopReadingAfter).contains(seconds) else {
            throw .invalid(flag: "--stop-reading-after", value: text)
        }
        return seconds
    }
}
