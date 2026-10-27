public import KnitMesh
import KnitSync
public import KnitWire

/// knit-peer's `--flood`, a trial's switch: the peer's radio, which also writes undecodable FRAME records to every live
/// link at a set rate, as a neighbour flooding its peers would. The far end's link manager counts each as undecodable
/// and keeps the link up (`LinkManager.undecodableFrames`), so what the trial watches is the far end's inbound credit:
/// its reads pause, its memory stays flat, and once the flood stops it reads on with nothing lost (ADR 2026-10.f5zs,
/// rule 6).
///
/// Everything else passes through to the radio it wraps, ``Radio/consumed(_:on:)`` included: a wrapper that kept that to
/// itself would leave every channel paused at its credit. A link counts as live from the HELLO the link manager reports
/// (``Radio/heardHello(from:on:)``) until the channel closes or its dial fails. The link manager cuts a record into
/// slices of up to 8 KiB, so a junk record goes in only between two of its records, never between the slices of one, and
/// is small enough to need no cutting itself. It holds back on a link while ``heldBackBytes`` wait there unwritten, so
/// a far end that pushes back never brings the peer's own queue to its 4 MiB bound.
public final class FloodRadio: Radio {
    /// The largest junk record's payload, half the link manager's 8 KiB write.
    public static let recordPayloadBytes = 4096
    /// While this much waits unwritten on a link, the flood holds back on it.
    public static let heldBackBytes = 524_288
    /// The payload's one byte, repeated: CBOR's break code, which no envelope starts with, so it never decodes.
    public static let junkByte: UInt8 = 0xFF
    /// What ``State/owed`` counts in: thousandths of a byte, so a rate under a byte a millisecond still adds up. A rate
    /// in bytes a second times milliseconds comes out in them.
    private static let perByte: Int64 = 1000
    /// The most owed: a second's worth.
    private static let owedMilliseconds: Int64 = 1000

    private struct State {
        var linked: Set<ChannelID> = []
        /// Bytes still to come of the record the link manager is writing in slices on each channel.
        var unfinished: [ChannelID: Int] = [:]
        /// Thousandths of a byte owed to each live link, at most a second's worth.
        var owed: [ChannelID: Int64] = [:]
        var written: Int64 = 0
    }

    /// Bytes a second written to each live link.
    public let bytesPerSecond: Int
    public let events: AsyncStream<RadioEvent>
    private let inner: any Radio
    private let state: Lock<State>
    private let forwarding: Task<Void, Never>

    /// `inner`, flooding each live link with `bytesPerSecond` of junk as ``tick(milliseconds:)`` is called.
    public init(wrapping inner: any Radio, bytesPerSecond: Int) {
        let (stream, continuation) = AsyncStream<RadioEvent>.makeStream()
        let shared = Lock(State())
        self.inner = inner
        self.bytesPerSecond = bytesPerSecond
        state = shared
        events = stream
        forwarding = Task { [events = inner.events] in
            for await event in events {
                switch event {
                case .closed(let channel), .dialFailed(let channel):
                    shared.withLock { Self.forget(channel, in: &$0) }
                default:
                    break
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    deinit {
        forwarding.cancel()
    }

    /// Every junk byte written so far, headers included.
    public var floodedBytes: Int64 { state.withLock { $0.written } }

    /// The links the flood writes to now.
    public var floodedChannels: Set<ChannelID> { state.withLock { $0.linked } }

    /// Owes each live link `milliseconds` more of the rate, and writes what it owes as whole records, unless the link
    /// manager is partway through a record there or the link's queue is full.
    public func tick(milliseconds: Int64) {
        let rate = Int64(bytesPerSecond)
        state.withLock { state in
            for channel in state.linked.sorted(by: { $0.rawValue < $1.rawValue }) {
                var owed = min(state.owed[channel, default: 0] + rate * milliseconds, rate * Self.owedMilliseconds)
                defer { state.owed[channel] = owed }
                guard state.unfinished[channel, default: 0] == 0, inner.outboxLevel(on: channel).queuedBytes < Self.heldBackBytes else {
                    continue
                }
                while owed > 0 {
                    let payload = max(1, min(Self.recordPayloadBytes, Int(owed / Self.perByte) - LinkRecord.headerBytes))
                    owed -= Int64(LinkRecord.headerBytes + payload) * Self.perByte
                    // Always encodes: 4 KiB at most is far under `LinkRecord.maxPayloadBytes`.
                    if let record = LinkRecord(.frame, payload: [UInt8](repeating: Self.junkByte, count: payload)).encoded {
                        inner.write(record, to: channel)
                        state.written += Int64(record.count)
                    }
                }
            }
        }
    }

    public var advertisesServiceData: Bool { inner.advertisesServiceData }
    public var dialsGattPeers: Bool { inner.dialsGattPeers }
    public var servesDoorbell: Bool { inner.servesDoorbell }
    public var reportsFileWrites: Bool { inner.reportsFileWrites }

    public func start() {
        inner.start()
    }

    public func stop() {
        state.withLock { $0 = State(written: $0.written) }
        inner.stop()
    }

    public func advertise(_ payload: AdvertPayload) {
        inner.advertise(payload)
    }

    public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
        inner.dial(address, psm: psm)
    }

    /// Passes the slice on, under the flood's lock so no junk record lands between two slices of one record, and keeps
    /// track of how much of its record is still to come.
    public func write(_ bytes: [UInt8], to channel: ChannelID) {
        state.withLock { state in
            var left = state.unfinished[channel, default: 0]
            if left == 0, bytes.count >= LinkRecord.headerBytes {
                left = LinkRecord.headerBytes + bytes[1..<LinkRecord.headerBytes].reduce(0) { $0 << UInt8.bitWidth | Int($1) }
            } else if left == 0 {
                left = bytes.count
            }
            state.unfinished[channel] = max(0, left - bytes.count)
            inner.write(bytes, to: channel)
        }
    }

    public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        state.withLock { _ in inner.writeDigest(record, to: channel) }
    }

    public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        state.withLock { _ in inner.writeFileRecord(record, to: channel) }
    }

    public func close(_ channel: ChannelID) {
        state.withLock { Self.forget(channel, in: &$0) }
        inner.close(channel)
    }

    public func outboxLevel(on channel: ChannelID) -> OutboxLevel {
        inner.outboxLevel(on: channel)
    }

    public func consumed(_ count: Int, on channel: ChannelID) {
        inner.consumed(count, on: channel)
    }

    public func ring(_ channel: ChannelID) {
        inner.ring(channel)
    }

    /// The link is up: the flood writes to it from the next tick.
    public func heardHello(from node: NodeId, on channel: ChannelID) {
        state.withLock { _ = $0.linked.insert(channel) }
        inner.heardHello(from: node, on: channel)
    }

    public func seekPeers(_ seeking: Bool) {
        inner.seekPeers(seeking)
    }

    private static func forget(_ channel: ChannelID, in state: inout State) {
        state.linked.remove(channel)
        state.unfinished[channel] = nil
        state.owed[channel] = nil
    }
}
