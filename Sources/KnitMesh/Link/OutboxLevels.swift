import KnitSync

/// How full one channel's queue is: what the link manager handed the radio and the radio has not written yet, and
/// every byte it has written since the channel opened (``Radio/outboxLevel(on:)``).
public struct OutboxLevel: Sendable, Equatable {
    /// Bytes handed to the radio for this channel and not yet written to its socket or stream: in the channel's
    /// ``LinkOutbox``, or still on their way to it through the radio's own queue.
    public var queuedBytes: Int
    /// Every byte written to the channel's socket or stream so far. It only grows, so the link manager reads progress
    /// as a change in it (``WriteStallWatch``).
    public var writtenBytes: Int64
    /// Of ``writtenBytes``, those the socket or stream has taken and not yet sent: the buffer below the link, which the
    /// `custody-carry-policy` contract counts as unwritten (§2). Only BlueZ reads it (`SocketBacklog`); CoreBluetooth's
    /// L2CAP stream does not say, so KnitBLE leaves it 0 (§9). Never more than ``writtenBytes``. The stall watch does not
    /// read it: a socket draining with nothing new queued is no stall.
    public var belowBytes: Int

    /// A level.
    public init(queuedBytes: Int = 0, writtenBytes: Int64 = 0, belowBytes: Int = 0) {
        self.queuedBytes = queuedBytes
        self.writtenBytes = writtenBytes
        self.belowBytes = belowBytes
    }

    /// Everything handed over and not yet sent: ``queuedBytes`` and ``belowBytes``.
    public var unwrittenBytes: Int { max(0, queuedBytes) + max(0, belowBytes) }
}

/// Every open channel's ``OutboxLevel``, kept by a radio where any thread may read it: the `Mesh` actor reads it
/// synchronously, never through the radio's own queue or thread (ADR 2026-10.f5zs).
///
/// The radio counts at its entry points. A write adds its bytes when the link manager hands them over, before they hop
/// to the CoreBluetooth queue or the BlueZ loop, and each byte the socket or stream takes moves from queued to written.
/// Counting inside ``LinkOutbox`` alone would miss the bytes still crossing to it, and a link manager reading a level
/// to hold a reply round would read low. A digest that takes the place of one still waiting gives the older one's bytes
/// back (``discarded(_:on:)``).
///
/// A channel counts from ``open(_:)``, which the radio calls when it numbers the channel, before the link manager can
/// write to it, until ``close(_:)``, which it calls when it reports the channel closed or a dial failed, or drops the
/// channel quietly. Bytes for a channel it does not hold are not counted: the radio drops them too. Its lock is
/// `KnitSync`'s (ADR 2026-09.ahrr).
public final class OutboxLevels: Sendable {
    private let levels = Lock<[ChannelID: OutboxLevel]>([:])

    /// No channel yet.
    public init() {
        // Channels open as the radio numbers them.
    }

    /// Starts counting `channel`, empty.
    public func open(_ channel: ChannelID) {
        levels.withLock { $0[channel] = $0[channel] ?? OutboxLevel() }
    }

    /// The link manager handed the radio `count` bytes for `channel`.
    public func queued(_ count: Int, on channel: ChannelID) {
        guard count > 0 else {
            return
        }
        levels.withLock { $0[channel]?.queuedBytes += count }
    }

    /// `count` bytes queued for `channel` will never be written: a newer digest took their place.
    public func discarded(_ count: Int, on channel: ChannelID) {
        guard count > 0 else {
            return
        }
        levels.withLock { levels in
            guard var level = levels[channel] else {
                return
            }
            level.queuedBytes = max(0, level.queuedBytes - count)
            levels[channel] = level
        }
    }

    /// The socket or stream took `count` of `channel`'s bytes.
    public func wrote(_ count: Int, on channel: ChannelID) {
        guard count > 0 else {
            return
        }
        levels.withLock { levels in
            guard var level = levels[channel] else {
                return
            }
            level.queuedBytes = max(0, level.queuedBytes - count)
            level.writtenBytes += Int64(count)
            levels[channel] = level
        }
    }

    /// Stops counting `channel`: it closed, its dial failed, or the radio dropped it.
    public func close(_ channel: ChannelID) {
        levels.withLock { $0[channel] = nil }
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

    /// `channel`'s level: empty for a channel not counted.
    public func level(on channel: ChannelID) -> OutboxLevel {
        levels.withLock { $0[channel] ?? OutboxLevel() }
    }

    /// Whether no channel is counted, for tests that check a closed one is dropped.
    public var isEmpty: Bool {
        levels.withLock { $0.isEmpty }
    }
}
