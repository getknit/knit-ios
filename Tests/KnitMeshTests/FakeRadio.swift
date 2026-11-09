import KnitCrypto
import KnitMesh
import KnitSync
import KnitWire

/// A radio that records what the link manager asks of it, reports whatever the test emits, and streams its own
/// activity so an async test can await a write rather than sleep for one.
///
/// Each channel's writes go through a real ``LinkOutbox``, drained whole at every call, so what ``writes(on:)`` holds is
/// what a radio would put on the air: the same bytes as handed over on a plain link, and `KEY_SHARE` then `SEALED` frames
/// on a sealed one, sealed by the outbox's own code. A write held for the sealer shows once the sealer comes.
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
        case wroteDigest(ChannelID, [UInt8])
        case wroteFileRecord(ChannelID, [UInt8])
        case wroteKeyShare(ChannelID, [UInt8], sealed: Bool)
        case sealed(ChannelID)
        case closed(ChannelID)
        case rang(ChannelID)
        case heardHello(NodeId, ChannelID)
        case linkUp(NodeId, ChannelID)
        case sought(Bool)
        case noReply(RadioAddress)
    }

    private struct State {
        var started = false
        var stopped = false
        var advertised: [AdvertPayload] = []
        var dials: [Dial] = []
        var writes: [ChannelID: [[UInt8]]] = [:]
        var outboxes: [ChannelID: LinkOutbox] = [:]
        var held: Set<ChannelID> = []
        var noReplies: [RadioAddress] = []
        var closed: [ChannelID] = []
        var rings: [ChannelID] = []
        var hellos: [HeardHello] = []
        var ups: [HeardHello] = []
        var seeks: [Bool] = []
        var levels: [ChannelID: OutboxLevel] = [:]
        var consumed: [Consumed] = []
        var nextChannel: UInt64 = 1
    }

    let advertisesServiceData: Bool
    let dialsGattPeers: Bool
    let servesDoorbell: Bool
    let reportsFileWrites: Bool
    let events: AsyncStream<RadioEvent>
    /// Everything asked of the radio, in order.
    let activity: AsyncStream<Activity>
    private let emitter: AsyncStream<RadioEvent>.Continuation
    private let recorder: AsyncStream<Activity>.Continuation
    private let state = Lock(State())

    init(advertisesServiceData: Bool, dialsGattPeers: Bool = true, servesDoorbell: Bool = false, reportsFileWrites: Bool = false) {
        self.advertisesServiceData = advertisesServiceData
        self.dialsGattPeers = dialsGattPeers
        self.servesDoorbell = servesDoorbell
        self.reportsFileWrites = reportsFileWrites
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
    /// Every ring, in order, by channel.
    var rings: [ChannelID] { state.withLock { $0.rings } }
    /// Every HELLO the link manager said it read, in order.
    var hellos: [HeardHello] { state.withLock { $0.hellos } }
    /// Every link the link manager said it registered (``Radio/linkUp(_:on:)``), in order.
    var linkUps: [HeardHello] { state.withLock { $0.ups } }
    /// Every change of seeking asked, in order.
    var seeks: [Bool] { state.withLock { $0.seeks } }
    /// Every address a plain dial got no reply from (``Radio/dialGotNoReply(at:)``), in order.
    var noReplies: [RadioAddress] { state.withLock { $0.noReplies } }

    /// Every delivery reported processed (``Radio/consumed(_:on:)``), in order.
    var consumed: [Consumed] { state.withLock { $0.consumed } }

    /// One delivery reported processed.
    struct Consumed: Equatable {
        var count: Int
        var channel: ChannelID
    }

    /// A HELLO the link manager reported (``Radio/heardHello(from:told:announced:on:)``), and its forms; a link up names none.
    struct HeardHello: Equatable {
        var node: NodeId
        var channel: ChannelID
        var told: NodeId?
        var announced: NodeId?

        init(node: NodeId, channel: ChannelID, told: NodeId? = nil, announced: NodeId? = nil) {
            self.node = node
            self.channel = channel
            self.told = told
            self.announced = announced
        }
    }

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
        queue(on: channel) { $0.append(bytes) }
        recorder.yield(.wrote(channel, bytes))
    }

    /// Records the digest as one write, the way it came, drained at once: the digest slot is tested on ``LinkOutbox`` itself.
    func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        queue(on: channel) { _ = $0.offerDigest(record) }
        recorder.yield(.wroteDigest(channel, record))
    }

    /// Records the FILE record as one write. A test that made the radio report writes reports each one out itself,
    /// with ``emit(_:)``.
    func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        queue(on: channel) { $0.appendFileRecord(record) }
        recorder.yield(.wroteFileRecord(channel, record))
    }

    func writeKeyShare(_ record: [UInt8], sealer: LinkSealer?, to channel: ChannelID) {
        queue(on: channel) { outbox in
            outbox.appendKeyShare(record)
            if let sealer {
                outbox.seal(with: sealer)
            }
        }
        recorder.yield(.wroteKeyShare(channel, record, sealed: sealer != nil))
    }

    func seal(_ channel: ChannelID, with sealer: LinkSealer) {
        queue(on: channel) { $0.seal(with: sealer) }
        recorder.yield(.sealed(channel))
    }

    func dialGotNoReply(at address: RadioAddress) {
        state.withLock { $0.noReplies.append(address) }
        recorder.yield(.noReply(address))
    }

    /// Holds what is written on `channel` in its outbox, as a socket with no room does, until ``release(_:)``: there a newer
    /// digest takes a waiting one's place.
    func hold(_ channel: ChannelID) {
        state.withLock { _ = $0.held.insert(channel) }
    }

    /// Writes what ``hold(_:)`` kept, as one write.
    func release(_ channel: ChannelID) {
        state.withLock { _ = $0.held.remove(channel) }
        queue(on: channel) { _ in
            // Nothing new: the drain is the point.
        }
    }

    /// Queues on `channel`'s outbox, then drains it whole as one write, if anything may leave and the channel is not held.
    private func queue(on channel: ChannelID, _ change: (inout LinkOutbox) -> Void) {
        state.withLock { state in
            var outbox = state.outboxes[channel] ?? LinkOutbox()
            change(&outbox)
            guard !state.held.contains(channel) else {
                state.outboxes[channel] = outbox
                return
            }
            let drained = outbox.drain().bytes
            state.outboxes[channel] = outbox
            if !drained.isEmpty {
                state.writes[channel, default: []].append(drained)
            }
        }
    }

    func close(_ channel: ChannelID) {
        state.withLock { $0.closed.append(channel) }
        recorder.yield(.closed(channel))
    }

    func ring(_ channel: ChannelID) {
        state.withLock { $0.rings.append(channel) }
        recorder.yield(.rang(channel))
    }

    func heardHello(from node: NodeId, told: NodeId?, announced: NodeId?, on channel: ChannelID) {
        state.withLock { $0.hellos.append(HeardHello(node: node, channel: channel, told: told, announced: announced)) }
        recorder.yield(.heardHello(node, channel))
    }

    func linkUp(_ node: NodeId, on channel: ChannelID) {
        state.withLock { $0.ups.append(HeardHello(node: node, channel: channel)) }
        recorder.yield(.linkUp(node, channel))
    }

    /// What a test said waits on `channel` and has left it; empty unless set (``setLevel(_:on:)``).
    func outboxLevel(on channel: ChannelID) -> OutboxLevel {
        state.withLock { $0.levels[channel] ?? OutboxLevel() }
    }

    /// Sets what ``outboxLevel(on:)`` answers for `channel`, as a real radio's queue would read.
    func setLevel(_ level: OutboxLevel, on channel: ChannelID) {
        state.withLock { $0.levels[channel] = level }
    }

    func consumed(_ count: Int, on channel: ChannelID) {
        state.withLock { $0.consumed.append(Consumed(count: count, channel: channel)) }
    }

    func seekPeers(_ seeking: Bool) {
        state.withLock { $0.seeks.append(seeking) }
        recorder.yield(.sought(seeking))
    }

    /// Every write on `channel`, in order, as the radio took it.
    func writes(on channel: ChannelID) -> [[UInt8]] {
        state.withLock { $0.writes[channel, default: []] }
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
