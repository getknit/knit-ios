import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// What the `LyingRadio` suites share: the nodes, a channel, a photo, and records as the link manager writes them.
protocol LyingRadioFixture {}

extension LyingRadioFixture {
    var local: NodeId { fixtureNodeId(1) }
    var peer: NodeId { fixtureNodeId(2) }
    var other: NodeId { fixtureNodeId(3) }
    var channel: ChannelID { ChannelID(5) }
    var photo: BlobHash { BlobHash(of: fixtureBytes(30_000, seed: 9)) }

    func lying(_ inner: CallRadio, profile: ForgingOwnProfileStore? = nil, log: any KnitLog = SilentLog()) -> LyingRadio {
        LyingRadio(wrapping: inner, localId: local, profile: profile, random: CountingGenerator(state: 77), log: log)
    }

    /// `record` cut as the link manager cuts one, into 8 KiB slices.
    func slices(_ record: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: record.count, by: 8192).map { Array(record[$0..<min($0 + 8192, record.count)]) }
    }

    func hello(_ node: NodeId) -> [UInt8] {
        record(.hello, Hello(nodeId: node.string, capabilities: 0x215F).payload)
    }

    /// Our `blobhas` answer, unsigned and point to point, as the engine writes one, with `extra` other hashes beside
    /// ``photo`` to make it as long as a test needs.
    func answer(extra: Int = 0, state: BlobHolding = .notHeld) -> WireEnvelope {
        var items = [BlobHasItem(hash: photo.string, state: state)]
        items += (0..<extra).map { BlobHasItem(hash: BlobHash(of: fixtureBytes(8, seed: $0)).string, state: .have, size: 100) }
        let envelope = RelayEnvelope(
            type: .blobHas, id: "answer-1", senderId: local.string, payload: BlobHasContent(items: items, load: 2, re: "q-1").encoded)
        return WireEnvelope(relay: false, sig: [], signed: envelope.encoded)
    }

    func forge(_ id: String = "forged") -> LyingRadio.Forge {
        let envelope = RelayEnvelope(type: .profile, id: id, senderId: local.string, sentAt: 5, payload: [0xA0])
        return LyingRadio.Forge(wire: WireEnvelope(relay: true, sig: [UInt8](repeating: 1, count: 64), signed: envelope.encoded), id: id)
    }

    /// Brings `channel` up as the dialer does: our HELLO first, then the peer's named, then the link registered.
    func dialed(_ radio: LyingRadio, _ channel: ChannelID, peer: NodeId) {
        radio.write(hello(local), to: channel)
        radio.heardHello(from: peer, told: nil, announced: nil, on: channel)
        radio.linkUp(peer, on: channel)
    }

    /// Brings `channel` up as the responder does: the peer's HELLO named first, then ours, then the link registered.
    func accepted(_ radio: LyingRadio, _ channel: ChannelID, peer: NodeId) {
        radio.heardHello(from: peer, told: nil, announced: nil, on: channel)
        radio.write(hello(local), to: channel)
        radio.linkUp(peer, on: channel)
    }
}

/// A log that keeps every line it is handed, built, so a test reads what a switch said.
final class LineLog: KnitLog {
    private let kept = Lock<[(level: LogLevel, line: String)]>([])

    /// Every line so far.
    var lines: [String] { kept.withLock { $0.map(\.line) } }

    /// The lines at `level`.
    func lines(at level: LogLevel) -> [String] {
        kept.withLock { $0.filter { $0.level == level }.map(\.line) }
    }

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let line = message()
        kept.withLock { $0.append((level, line)) }
    }
}

/// A clock a test moves by hand. A sleeper waits until it is cancelled, so no timer fires on its own.
final class HandClock: MeshClock {
    private let now = Lock((wall: StillClock.wall, monotonic: Int64(1000)))

    func wallMilliseconds() -> Int64 {
        now.withLock { $0.wall }
    }

    func monotonicMilliseconds() -> Int64 {
        now.withLock { $0.monotonic }
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }

    /// Moves both clocks on by `milliseconds`.
    func advance(_ milliseconds: Int64) {
        now.withLock { now in
            now.wall += milliseconds
            now.monotonic += milliseconds
        }
    }
}

/// An inner radio that records each call it is handed, slice by slice, and reports what the test emits.
final class CallRadio: Radio {
    enum Call: Equatable {
        case write(ChannelID, [UInt8])
        case digest(ChannelID, [UInt8])
        case file(ChannelID, [UInt8])
        case ring(ChannelID)
        case heard(NodeId, ChannelID)
        case up(NodeId, ChannelID)
        case close(ChannelID)
        case advertise(AdvertPayload)
        case seek(Bool)
    }

    let advertisesServiceData = true
    let dialsGattPeers = false
    let servesDoorbell = true
    let reportsFileWrites = true
    let events: AsyncStream<RadioEvent>
    private let emitter: AsyncStream<RadioEvent>.Continuation
    private let dialing: ChannelID
    private let state = Lock<(calls: [Call], dialed: ChannelID?)>(([], nil))

    init(dialing: ChannelID = ChannelID(99)) {
        self.dialing = dialing
        (events, emitter) = AsyncStream<RadioEvent>.makeStream()
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var dialed: ChannelID? { state.withLock { $0.dialed } }

    func emit(_ event: RadioEvent) {
        emitter.yield(event)
    }

    /// The slices handed to ``write(_:to:)`` on `channel`.
    func writes(on channel: ChannelID) -> [[UInt8]] {
        calls.compactMap { call in
            guard case .write(let to, let bytes) = call, to == channel else {
                return nil
            }
            return bytes
        }
    }

    /// Every record written on `channel`, by any of the three writes, parsed back.
    func records(on channel: ChannelID) -> [LinkRecord] {
        var reader = LinkRecordReader()
        for call in calls {
            switch call {
            case .write(let to, let bytes), .digest(let to, let bytes), .file(let to, let bytes):
                if to == channel {
                    reader.append(bytes)
                }
            default:
                break
            }
        }
        var records: [LinkRecord] = []
        while let record = try? reader.next() {
            records.append(record)
        }
        return records
    }

    private func record(_ call: Call) {
        state.withLock { $0.calls.append(call) }
    }

    func start() {
        // Nothing to start.
    }

    func stop() {
        // Nothing to stop.
    }

    func advertise(_ payload: AdvertPayload) {
        record(.advertise(payload))
    }

    func seekPeers(_ seeking: Bool) {
        record(.seek(seeking))
    }

    func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
        state.withLock { $0.dialed = dialing }
        return dialing
    }

    func write(_ bytes: [UInt8], to channel: ChannelID) {
        record(.write(channel, bytes))
    }

    func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        self.record(.digest(channel, record))
    }

    func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        self.record(.file(channel, record))
    }

    func close(_ channel: ChannelID) {
        record(.close(channel))
    }

    func ring(_ channel: ChannelID) {
        record(.ring(channel))
    }

    func heardHello(from node: NodeId, told _: NodeId?, announced _: NodeId?, on channel: ChannelID) {
        record(.heard(node, channel))
    }

    func linkUp(_ node: NodeId, on channel: ChannelID) {
        record(.up(node, channel))
    }
}
