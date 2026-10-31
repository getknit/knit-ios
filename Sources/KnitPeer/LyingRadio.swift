public import KnitMesh
import KnitSync
public import KnitWire

/// knit-peer's `--lying` radio, a trial's switch: the peer's radio, which rewrites some of what the link manager writes
/// and writes a few records of its own, as a holder that lies about a photo would (`door-cap-lying-peers`, ADR 2026-10.r88m).
///
/// - **`blobhas`** (``setBlobHasLie(_:size:)``): every FRAME record goes through ``BlobHasLie``, so our answer to a holder
///   query claims the hash at the size set.
/// - **FILE header** (``setJunkHeader(_:declare:)``): an `ATTACHMENT` header for a junk hash has its `size` set to the
///   declared size, or removed when none is declared. Its `offset` stays, so with one the declared size is the tail's,
///   which is what a header's `size` always counts (`LinkJSON.fileHeaderPayload`). An `AVATAR` header for the photo our
///   profile advertises in place of our own is counted (``Counts/advertisedPhotoPushed``), a canary: the blob store
///   withholds that photo, so it should stay at 0.
/// - **Injection**: the padded profile (``setPaddedProfile(_:)``) is written once on each ready channel, and the one-shot
///   ask (``askBlob(_:of:)``) once on the named peer's, each between two of the link manager's records, then rung.
///
/// A channel is ready once our own HELLO has been written on it and ``heardHello(from:on:)`` has named its peer, whichever
/// comes second: the dialer writes first and the responder answers, and an end that reads anything but a HELLO first
/// drops the link (`LinkManager.handleHello`, `LinkManager+Admission.swift:181-201`; knit-next `LinkHandshake.readHello`,
/// `LinkHandshake.kt:45-49` at the pin `e63f15f4`). Nothing is injected before our HELLO, on a link the peer dialed or
/// one it accepted.
///
/// The link manager cuts a FRAME record into slices of up to 8 KiB, and hands DIGEST and FILE records over whole. The
/// radio tracks where each record ends, as ``FloodRadio`` does. While a rewrite could apply, it holds a FRAME's slices
/// until the record is whole, rewrites it, and writes the result in slices no larger than the first one it held. A record
/// nothing could rewrite, and everything while no switch is set, passes through as it came, byte for byte and slice for
/// slice. Every entry point takes the one lock, so nothing it writes lands inside another record. Every event passes
/// through, and a channel is forgotten when it closes or its dial fails. Outermost over ``FloodRadio`` when both are on.
public final class LyingRadio: Radio {
    /// The largest slice an injected record is written in: the link manager's own (``LinkManager/Configuration/maxWriteBytes``).
    public static let sliceBytes = LinkManager.Configuration().maxWriteBytes
    /// The `pull` of a plain ask for our own want: `BlobExchange.pullBudget`, which a want of our own mints and
    /// `MeshEngine.blobRequest` sends.
    public static let plainAskPull = 3

    public let events: AsyncStream<RadioEvent>
    let inner: any Radio
    let localId: NodeId
    let profile: ForgingOwnProfileStore?
    let log: any KnitLog
    let state: Lock<State>
    private let forwarding: Task<Void, Never>

    /// `inner`, honest until a switch is set. `localId` signs nothing: it is the sender an ask names. `profile` says which
    /// photo our profile advertises in place of our own, for the canary; `random` draws an ask's id.
    public init(
        wrapping inner: any Radio,
        localId: NodeId,
        profile: ForgingOwnProfileStore?,
        random: some RandomNumberGenerator & Sendable,
        log: any KnitLog = SilentLog()
    ) {
        let (stream, continuation) = AsyncStream<RadioEvent>.makeStream()
        let shared = Lock(State(random: random))
        self.inner = inner
        self.localId = localId
        self.profile = profile
        self.log = log
        state = shared
        events = stream
        forwarding = Task { [events = inner.events] in
            for await event in events {
                switch event {
                case .closed(let channel), .dialFailed(let channel):
                    shared.withLock { state in
                        state.links[channel] = nil
                        state.closed.insert(channel)
                    }
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

    // MARK: Radio

    public var advertisesServiceData: Bool { inner.advertisesServiceData }
    public var dialsGattPeers: Bool { inner.dialsGattPeers }
    public var servesDoorbell: Bool { inner.servesDoorbell }
    public var reportsFileWrites: Bool { inner.reportsFileWrites }

    public func start() {
        inner.start()
    }

    /// Forgets every channel, keeping the switches and the counts.
    public func stop() {
        state.withLock { $0.links = [:] }
        inner.stop()
    }

    public func advertise(_ payload: AdvertPayload) {
        inner.advertise(payload)
    }

    public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
        inner.dial(address, psm: psm)
    }

    /// Passes the slice on, or holds it while its record could be rewritten, and keeps track of where the record ends.
    public func write(_ bytes: [UInt8], to channel: ChannelID) {
        let advertised = profile?.advertisedPhoto
        let effects = state.withLock { state -> Effects in
            var effects = Effects()
            guard !state.closed.contains(channel) else {
                inner.write(bytes, to: channel)
                return effects
            }
            var link = state.links[channel, default: Link()]
            if link.heldLeft > 0 {
                link.held.append(bytes)
                link.heldLeft = max(0, link.heldLeft - bytes.count)
            } else if link.unfinished > 0 {
                link.unfinished = max(0, link.unfinished - bytes.count)
                inner.write(bytes, to: channel)
            } else {
                begin(bytes, of: &link, on: channel) { state.holds($0, advertised: advertised) }
            }
            if !link.held.isEmpty, link.heldLeft == 0 {
                writeHeld(&link, on: channel, in: &state, advertised: advertised, effects: &effects)
            }
            state.links[channel] = link
            catchUp(channel, in: &state, effects: &effects)
            return effects
        }
        apply(effects)
    }

    public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        let effects = state.withLock { state -> Effects in
            inner.writeDigest(record, to: channel)
            var effects = Effects()
            catchUp(channel, in: &state, effects: &effects)
            return effects
        }
        apply(effects)
    }

    /// Passes a whole FILE record on, an `ATTACHMENT` header for a junk hash rewritten, as a FILE record still, so the
    /// radio reports it written as the link manager counts on.
    public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        let advertised = profile?.advertisedPhoto
        let effects = state.withLock { state -> Effects in
            var effects = Effects()
            var written = record
            if LyingRecords.header(of: record)?.tag == .fileHeader, let parsed = LyingRecords.whole(record) {
                written = rewrittenHeader(parsed, on: channel, in: &state, advertised: advertised, effects: &effects)?.encoded ?? record
            }
            inner.writeFileRecord(written, to: channel)
            catchUp(channel, in: &state, effects: &effects)
            return effects
        }
        apply(effects)
    }

    public func close(_ channel: ChannelID) {
        state.withLock { state in
            state.links[channel] = nil
            state.closed.insert(channel)
        }
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

    /// The peer named itself: once our HELLO is out too, the channel is ready, and what waits is injected.
    public func heardHello(from node: NodeId, on channel: ChannelID) {
        inner.heardHello(from: node, on: channel)
        let effects = state.withLock { state -> Effects in
            var effects = Effects()
            guard !state.closed.contains(channel) else {
                return effects
            }
            state.links[channel, default: Link()].peer = node
            catchUp(channel, in: &state, effects: &effects)
            return effects
        }
        apply(effects)
    }

    public func seekPeers(_ seeking: Bool) {
        inner.seekPeers(seeking)
    }
}
