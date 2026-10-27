import KnitSync

/// What a radio may do with a channel's input before its next read (``InboxCredits/gate(_:)``).
public enum InboxGate: Sendable, Equatable {
    /// Read on.
    case read
    /// Stop reading: the channel has just reached its credit, with `unprocessed` bytes delivered and not yet consumed. A
    /// radio logs this once, when its reads pause.
    case pause(unprocessed: Int)
    /// Stay stopped: the channel paused before, and has not fallen below half its credit since.
    case paused
}

/// Every open channel's inbound credit: the bytes a radio delivered as ``RadioEvent/received(_:_:)`` and its consumer
/// has not yet processed (``Radio/consumed(_:on:)``), kept where the stream thread, the BlueZ loop and the `Mesh` actor
/// all read it in place (ADR 2026-10.f5zs, rule 6).
///
/// A radio asks ``gate(_:)`` before each read and stops reading a channel at ``limit``. What its peer writes after
/// that waits in the operating system's buffer, and L2CAP's credits push back on the sender, so a neighbour's flood
/// waits on its own channel rather than in memory ahead of every honest link's records. ``consumed(_:on:)`` resumes the
/// channel once it falls below half, and tells the radio so: a CoreBluetooth stream signals `hasBytesAvailable` again
/// only after a read, so the radio kicks its own. Nothing is dropped. Android's inbound flow drops past 256 frames
/// without a count; this port never drops, and bounds the backlog per channel instead.
///
/// A channel counts from ``open(_:)``, which the radio calls when it numbers the channel, until ``close(_:)``, which it
/// calls when it reports the channel closed or a dial failed, or drops the channel quietly. So a loop that drains a
/// radio's events without a `Mesh` and closes each channel it is handed (knit-peer's `scan` and `stranger`) leaves
/// nothing behind. A channel not counted is not gated: the radio is done with it. The lock is `KnitSync`'s (ADR
/// 2026-09.ahrr).
public final class InboxCredits: Sendable {
    /// How many unprocessed bytes stop a channel's reads: 256 KiB, four of the radios' 64 KiB reads.
    public static let limitBytes = 262_144

    private struct Credit {
        var unprocessed = 0
        var isPaused = false
    }

    /// A paused channel resumes below this share of its limit: half.
    private static let resumeDivisor = 2

    /// How many unprocessed bytes stop a channel's reads. They resume below half.
    public let limit: Int
    private let credits = Lock<[ChannelID: Credit]>([:])

    /// No channel yet, each to stop at `limit` unprocessed bytes.
    public init(limit: Int = InboxCredits.limitBytes) {
        self.limit = limit
    }

    /// Starts counting `channel`, with nothing delivered.
    public func open(_ channel: ChannelID) {
        credits.withLock { $0[channel] = $0[channel] ?? Credit() }
    }

    /// Whether the radio may read `channel` now. The first answer at or over ``limit`` is ``InboxGate/pause(unprocessed:)``,
    /// and every one after it ``InboxGate/paused`` until ``consumed(_:on:)`` resumes the channel.
    public func gate(_ channel: ChannelID) -> InboxGate {
        credits.withLock { credits in
            guard var credit = credits[channel] else {
                return .read
            }
            if credit.isPaused {
                return .paused
            }
            guard credit.unprocessed >= limit else {
                return .read
            }
            credit.isPaused = true
            credits[channel] = credit
            return .pause(unprocessed: credit.unprocessed)
        }
    }

    /// The radio read `count` bytes from `channel` and is about to deliver them. It counts them first, so the consumer
    /// never reports bytes the count has not seen.
    public func delivered(_ count: Int, on channel: ChannelID) {
        guard count > 0 else {
            return
        }
        credits.withLock { $0[channel]?.unprocessed += count }
    }

    /// The consumer processed `count` of `channel`'s bytes. Answers what is still unprocessed when this resumes a paused
    /// channel, so the radio reads it again, and `nil` otherwise.
    public func consumed(_ count: Int, on channel: ChannelID) -> Int? {
        guard count > 0 else {
            return nil
        }
        return credits.withLock { credits in
            guard var credit = credits[channel] else {
                return nil
            }
            credit.unprocessed = max(0, credit.unprocessed - count)
            let resumes = credit.isPaused && credit.unprocessed < limit / Self.resumeDivisor
            if resumes {
                credit.isPaused = false
            }
            credits[channel] = credit
            return resumes ? credit.unprocessed : nil
        }
    }

    /// Stops counting `channel`: it closed, its dial failed, or the radio dropped it.
    public func close(_ channel: ChannelID) {
        credits.withLock { $0[channel] = nil }
    }

    /// Stops counting the channel `event` reports closed or never opened, so a radio passes every event it emits.
    public func note(_ event: RadioEvent) {
        switch event {
        case .closed(let channel), .dialFailed(let channel):
            close(channel)
        default:
            break
        }
    }

    /// The bytes delivered on `channel` and not yet processed: none for a channel not counted.
    public func unprocessed(on channel: ChannelID) -> Int {
        credits.withLock { $0[channel]?.unprocessed ?? 0 }
    }

    /// Whether no channel is counted, for tests that check a closed one is dropped.
    public var isEmpty: Bool {
        credits.withLock { $0.isEmpty }
    }
}
