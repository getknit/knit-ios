import KnitMesh
import KnitWire
import Synchronization

/// A radio that records what the link manager asks of it, reports whatever the test emits, and streams its own
/// activity so an async test can await a write rather than sleep for one.
final class FakeRadio: Radio {
    struct Dial: Equatable {
        var address: RadioAddress
        var psm: UInt16
        var channel: ChannelID
    }

    /// One thing the link manager asked of the radio.
    enum Activity: Equatable {
        case advertised(AdvertPayload)
        case dialed(Dial)
        case wrote(ChannelID, [UInt8])
        case closed(ChannelID)
    }

    private struct State {
        var started = false
        var stopped = false
        var advertised: [AdvertPayload] = []
        var dials: [Dial] = []
        var writes: [ChannelID: [[UInt8]]] = [:]
        var closed: [ChannelID] = []
        var nextChannel: UInt64 = 1
    }

    let advertisesServiceData: Bool
    let dialsGattPeers: Bool
    let events: AsyncStream<RadioEvent>
    /// Everything asked of the radio, in order.
    let activity: AsyncStream<Activity>
    private let emitter: AsyncStream<RadioEvent>.Continuation
    private let recorder: AsyncStream<Activity>.Continuation
    private let state = Mutex(State())

    init(advertisesServiceData: Bool, dialsGattPeers: Bool = true) {
        self.advertisesServiceData = advertisesServiceData
        self.dialsGattPeers = dialsGattPeers
        (events, emitter) = AsyncStream<RadioEvent>.makeStream()
        (activity, recorder) = AsyncStream<Activity>.makeStream()
    }

    deinit {
        emitter.finish()
        recorder.finish()
    }

    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var advertised: [AdvertPayload] { state.withLock { $0.advertised } }
    var dials: [Dial] { state.withLock { $0.dials } }
    var closed: [ChannelID] { state.withLock { $0.closed } }

    /// Reports `event`, as the radio would.
    func emit(_ event: RadioEvent) {
        emitter.yield(event)
    }

    func start() {
        state.withLock { $0.started = true }
    }

    func stop() {
        state.withLock { $0.stopped = true }
    }

    func advertise(_ payload: AdvertPayload) {
        state.withLock { $0.advertised.append(payload) }
        recorder.yield(.advertised(payload))
    }

    func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
        let dial = state.withLock { state in
            let dial = Dial(address: address, psm: psm, channel: ChannelID(state.nextChannel))
            state.nextChannel += 1
            state.dials.append(dial)
            return dial
        }
        recorder.yield(.dialed(dial))
        return dial.channel
    }

    func write(_ bytes: [UInt8], to channel: ChannelID) {
        state.withLock { $0.writes[channel, default: []].append(bytes) }
        recorder.yield(.wrote(channel, bytes))
    }

    func close(_ channel: ChannelID) {
        state.withLock { $0.closed.append(channel) }
        recorder.yield(.closed(channel))
    }

    /// The size of each write on `channel`.
    func writeSizes(on channel: ChannelID) -> [Int] {
        state.withLock { $0.writes[channel, default: []].map(\.count) }
    }

    /// Everything written on `channel`, parsed back into records.
    func records(on channel: ChannelID) -> [LinkRecord] {
        var reader = LinkRecordReader()
        reader.append(state.withLock { $0.writes[channel, default: []].flatMap(\.self) })
        var records: [LinkRecord] = []
        while let record = try? reader.next() {
            records.append(record)
        }
        return records
    }

    /// The frames written on `channel`.
    func frames(on channel: ChannelID) -> [WireEnvelope] {
        records(on: channel).filter { $0.tag == .frame }.compactMap { try? WireEnvelope(decoding: $0.payload) }
    }
}
