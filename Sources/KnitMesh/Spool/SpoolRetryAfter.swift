/// A full spool's `Retry-After`, as the socket hands it over: the header's first ``keptBytes`` bytes and whether there
/// were more (ADR 2026-11.adrq, P4b1). Nothing reads it but ``milliseconds``.
public struct SpoolRetryAfter: Sendable, Equatable, CustomStringConvertible {
    /// The most bytes of the header kept.
    public static let keptBytes = 16

    /// The bytes kept.
    public let bytes: [UInt8]
    /// Whether the header ran past ``keptBytes``.
    public let truncated: Bool

    /// The header's bytes, cut to ``keptBytes``.
    public init(header: some Collection<UInt8>) {
        bytes = Array(header.prefix(Self.keptBytes))
        truncated = header.count > Self.keptBytes
    }

    /// Its size alone: the bytes are a server's.
    public var description: String { "retry-after(\(bytes.count) bytes)" }

    /// The floor it asks for, read as this port's rule: delta-seconds alone, ASCII digits with optional spaces or tabs
    /// around them; a sign, an HTTP-date or anything else is no floor. Held to 0…60 s (``SpoolBackoff/maxRetryAfterMilliseconds``)
    /// without trapping. Digits that ran past the cut read as the cap, never as the shorter number they were cut to; any other
    /// header past the cut is no floor.
    /// `Retry-After` is a hint: a floor under the backoff, never in its place.
    var milliseconds: Int64? {
        let trimmed = bytes.drop { Self.isSpace($0) }.reversed().drop { Self.isSpace($0) }.reversed()
        guard !trimmed.isEmpty, trimmed.allSatisfy(Self.isDigit) else {
            return nil
        }
        // Digits the cut stopped hide more of them; anything else past the cut is unread, so no floor.
        if truncated {
            return bytes.allSatisfy(Self.isDigit) ? SpoolBackoff.maxRetryAfterMilliseconds : nil
        }
        // At most ``keptBytes`` digits, so the seconds stay under 10^16 and fit; only the milliseconds can overflow.
        let seconds = trimmed.reduce(Int64(0)) { $0 * Self.decimal + Int64($1 - UInt8(ascii: "0")) }
        let (total, over) = seconds.multipliedReportingOverflow(by: Self.millisecondsPerSecond)
        return over ? SpoolBackoff.maxRetryAfterMilliseconds : min(total, SpoolBackoff.maxRetryAfterMilliseconds)
    }

    private static let decimal: Int64 = 10
    private static let millisecondsPerSecond: Int64 = 1000

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }
}
