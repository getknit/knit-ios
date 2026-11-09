public import KnitCrypto
public import KnitWire

/// An L2CAP channel on the radio, dialed or accepted. The radio assigns ids and never reuses one.
public struct ChannelID: Hashable, Sendable, CustomStringConvertible {
    /// The id.
    public let rawValue: UInt64

    /// Wraps an id.
    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// `ch` and the id, for logs.
    public var description: String { "ch\(rawValue)" }
}

/// Whatever a radio needs to dial a sighted peer again: a peripheral's identifier, a BlueZ device path. Opaque
/// above the radio, and never an identity: that is always the advertised node id.
public struct RadioAddress: Hashable, Sendable {
    /// The radio's own handle.
    public let rawValue: String

    /// Wraps a handle.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One scan hit: the peer's `0xFE30` payload, from its advert's service data or its GATT characteristic.
public struct RadioSighting: Sendable, Equatable {
    /// Where to dial it.
    public var address: RadioAddress
    /// What it advertised.
    public var advert: AdvertPayload
    /// The received signal strength, in dBm.
    public var rssi: Int

    /// Makes a sighting.
    public init(address: RadioAddress, advert: AdvertPayload, rssi: Int) {
        self.address = address
        self.advert = advert
        self.rssi = rssi
    }
}

/// Whether the radio can run.
public enum RadioState: Sendable, Equatable {
    /// On and permitted.
    case on
    /// Switched off.
    case off
    /// The user has not allowed Bluetooth.
    case unauthorized
    /// No Bluetooth LE here.
    case unsupported
}

/// What a radio reports, in order.
public enum RadioEvent: Sendable, Equatable {
    /// The radio's state changed.
    case state(RadioState)
    /// The L2CAP listener is open on `psm`, which goes in the advert.
    case listening(psm: UInt16)
    /// A peer was sighted.
    case sighted(RadioSighting)
    /// A dial opened.
    case connected(ChannelID)
    /// A dial did not open.
    case dialFailed(ChannelID)
    /// A peer dialed us.
    case accepted(ChannelID)
    /// Bytes arrived on a channel, in order, chunked however the radio read them.
    case received(ChannelID, [UInt8])
    /// A channel closed: end of stream, a reset, or our own close completing.
    case closed(ChannelID)
    /// A peer rang this node's doorbell, which woke the app if iOS had suspended it.
    case rung
    /// The last byte of the oldest FILE record still queued on a channel left the radio's queue
    /// (``Radio/writeFileRecord(_:to:)``).
    case wroteFileRecord(ChannelID)
}

/// The radio under ``LinkManager``: it advertises, scans, dials, accepts and moves bytes, and decides nothing.
/// KnitBLE (CoreBluetooth) and KnitBlueZ implement it; everything about who links to whom is the link manager's.
public protocol Radio: AnyObject, Sendable {
    /// Whether this radio's advert carries the `0xFE30` service data every Knit build reads. An iPhone's cannot:
    /// iOS advertises only a name and service UUIDs, so an iPhone is found through its GATT payload, which Android
    /// 2.7 never reads.
    var advertisesServiceData: Bool { get }

    /// Whether this radio reads the GATT payload of a peer whose advert carries only the `0xFE30` UUID, and so can
    /// find an iPhone. The advert sets `FLAG_DIALS_GATT_PEERS` only when it does: a peer that trusts the flag
    /// waits to be dialed, and a node that set it without reading GATT would never link that peer.
    var dialsGattPeers: Bool { get }

    /// Whether this radio serves the GATT doorbell, so a peer should ring it after the frames it sends. The HELLO
    /// adds `CAP_DOORBELL` only when it does: a peer that trusts the bit opens a GATT client on the link to find
    /// the doorbell, and a node that set it without serving one would cost that peer a lookup on every link.
    var servesDoorbell: Bool { get }

    /// Whether this radio reports each FILE record's last byte leaving its queue
    /// (``RadioEvent/wroteFileRecord(_:)``). The link manager then holds a file's next chunk until the last one is out,
    /// so a file never fills the queue ahead of the frames written after it. A radio that does not report is fed at the
    /// pace alone.
    var reportsFileWrites: Bool { get }

    /// What the radio reports.
    var events: AsyncStream<RadioEvent> { get }

    /// Powers the plane up: opens the listener, starts scanning.
    func start()

    /// Stops advertising and scanning and closes every channel.
    func stop()

    /// Publishes `payload`, replacing what was advertised.
    func advertise(_ payload: AdvertPayload)

    /// Dials a sighted peer's listener. The outcome arrives as ``RadioEvent/connected(_:)`` or
    /// ``RadioEvent/dialFailed(_:)``.
    func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID

    /// Writes bytes on an open channel, after everything written before.
    func write(_ bytes: [UInt8], to channel: ChannelID)

    /// Writes a whole encoded DIGEST record on an open channel, after everything written before, or in the place of
    /// a digest that still waits there unwritten (knit-next ADR 2026-09.tjfb). A radio queues it in its
    /// ``LinkOutbox`` with ``LinkOutbox/offerDigest(_:)``, and cuts it into writes of its own size.
    func writeDigest(_ record: [UInt8], to channel: ChannelID)

    /// Writes a whole encoded FILE record on an open channel, after everything written before. A radio that
    /// ``reportsFileWrites`` queues it in its ``LinkOutbox`` with ``LinkOutbox/appendFileRecord(_:)``, cuts it into
    /// writes of its own size, and reports ``RadioEvent/wroteFileRecord(_:)`` once its last byte is out.
    func writeFileRecord(_ record: [UInt8], to channel: ChannelID)

    /// Writes our whole `KEY_SHARE` record on an open channel, after everything written before, and holds whatever is
    /// written after it until `sealer`, or a later ``seal(_:with:)``, is there to seal it (the `link-seal` contract, §4):
    /// no byte after our `KEY_SHARE` leaves in the clear. A responder hands its sealer over with the record, in one call; a
    /// dialer, which has no keys until the responder's `KEY_SHARE` comes back, passes `nil` and hands it over then. A radio
    /// queues it in its ``LinkOutbox`` with ``LinkOutbox/appendKeyShare(_:)``, in order with its writes. No default: a radio
    /// that took it as a plain write would leak every record behind it.
    func writeKeyShare(_ record: [UInt8], sealer: LinkSealer?, to channel: ChannelID)

    /// From now on everything written on `channel` after our `KEY_SHARE` leaves in `SEALED` frames under `sealer`, sealed
    /// as each frame leaves the channel's queue (``LinkOutbox/seal(with:frameBytes:)``), in order with the writes before
    /// it. Any seal that fails closes the channel; nothing is ever written plain after the `KEY_SHARE`. No default, as
    /// ``writeKeyShare(_:sealer:to:)`` has none.
    func seal(_ channel: ChannelID, with sealer: LinkSealer)

    /// Closes a channel.
    func close(_ channel: ChannelID)

    /// How full `channel`'s queue is: bytes handed over and not yet written, and every byte written so far. Answered at
    /// once from any thread, never through the radio's own queue, since the link manager polls it to close a link whose
    /// writes have stalled (``WriteStallWatch``) and the engine reads it to hold a reply round (ADR 2026-10.f5zs). A radio
    /// counts at its entry points, in an ``OutboxLevels``.
    func outboxLevel(on channel: ChannelID) -> OutboxLevel

    /// The consumer processed `count` bytes the radio delivered on `channel` as ``RadioEvent/received(_:_:)``. `Mesh`
    /// reports every delivery once the link manager has taken it, running or stopped, so a channel is never left
    /// waiting. A radio stops reading a channel while 256 KiB it delivered wait unprocessed, and reads it again below
    /// half, counting in an ``InboxCredits``; answered at once from any thread (ADR 2026-10.f5zs, rule 6).
    func consumed(_ count: Int, on channel: ChannelID)

    /// Rings the doorbell of the peer on `channel`, which wakes its app if iOS has suspended it: data arriving on
    /// an open link does not, and a write to the doorbell does (ADR router: `.agents/memory/decisions.md`). A radio
    /// that cannot ring, or a peer without a doorbell, does nothing.
    func ring(_ channel: ChannelID)

    /// The HELLO on `channel` named `node` and told `told` (its `t`, the form that node airs, `nil` without one); `announced`
    /// is the tag that node announced to us and we hold, if any. The dialer's on a channel we accepted, or the reply on one
    /// we dialed. A radio that read a GATT payload for the address at the channel's other end forgets it when it names
    /// another node, or, blinded, a tag that is neither `told` nor `announced` (``GattPayloads/helloNamed(_:told:announced:at:)``;
    /// ADR 2026-11.prsp). A refusal carries no HELLO, so it never comes here. Called for every HELLO that parses on a dial to
    /// an id or from a dialer, whatever becomes of the link: a claim refused and a proof that fails included. A tag dial's
    /// reply comes here only once its proof verified. ``linkUp(_:on:)`` says when the link is the peer's.
    func heardHello(from node: NodeId, told: NodeId?, announced: NodeId?, on channel: ChannelID)

    /// Our plain dial to `address`, whose HELLO carried ``Capabilities/linkSeal``, ended with no reply: the far end closed
    /// or said nothing within the HELLO's deadline. A radio that read the address's GATT payload forgets it, once, when
    /// it lacks the advert's `FLAG_LINK_SEAL`, since a peer that upgraded since the read refuses a plain dial from a
    /// sealing build before it replies, and the next dial must read the payload afresh to open sealed
    /// (``GattPayloads/noReply(at:)``; the `link-seal` contract, §7, revision 1). Keyed by the address dialed, not the
    /// channel: the radio has forgotten a channel it reported closed.
    func dialGotNoReply(at address: RadioAddress)

    /// The link on `channel` registered to `node`: its HELLO checked out and, when both HELLOs carry
    /// ``Capabilities/linkProof``, its PROOF verified (the `link-hello-proof` contract, §5). From here the link manager
    /// writes frames on it. Called once per link, before the engine hears of it.
    func linkUp(_ node: NodeId, on channel: ChannelID)

    /// Whether to seek peers while the app is in the background, where iOS may suspend it: scan for the `0xFE30` UUID
    /// alone, which iOS keeps running there and which resumes the app at each match, instead of a scan for every advert,
    /// which iOS silences there. The link manager asks while it holds no link and has wakes left to spend
    /// (ADR 2026-10.mueg). A radio whose app is never suspended does nothing.
    func seekPeers(_ seeking: Bool)
}

extension Radio {
    /// Reports nothing: a radio with no queue of its own, fed at the pace alone.
    public var reportsFileWrites: Bool { false }

    /// Writes the digest like any record: a radio that holds no queue of its own has none to replace it in.
    public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        write(record, to: channel)
    }

    /// Writes the FILE record like any record, and reports nothing.
    public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        write(record, to: channel)
    }

    /// Nothing queued and nothing written: a radio with no queue of its own takes each write at once, so its links never
    /// stall and never hold a round back.
    public func outboxLevel(on _: ChannelID) -> OutboxLevel {
        OutboxLevel()
    }

    /// Keeps no count: a radio that holds nothing it delivered, and never stops reading.
    public func consumed(_: Int, on _: ChannelID) {
        // KnitBLE and KnitBlueZ bound what they deliver; the test radios and the demo hand every event over at once.
    }

    /// Rings nothing: a radio that cannot reach a doorbell.
    public func ring(_: ChannelID) {
        // A radio that can ring implements this; the rest leave the peer to wake at its next foreground.
    }

    /// Keeps nothing: a radio that reads no GATT payloads has none to forget.
    public func heardHello(from _: NodeId, told _: NodeId?, announced _: NodeId?, on _: ChannelID) {
        // A radio that reads GATT payloads implements this.
    }

    /// Keeps nothing: a radio that reads no GATT payloads has none to forget.
    public func dialGotNoReply(at _: RadioAddress) {
        // A radio that reads GATT payloads implements this.
    }

    /// Does nothing: a radio moves bytes, and which node a link belongs to is the link manager's (payload rule 3 holds on a
    /// channel). knit-peer's wrappers write on a link from here.
    public func linkUp(_: NodeId, on _: ChannelID) {
        // KnitBLE and KnitBlueZ need nothing here.
    }

    /// Seeks nothing: a radio whose app iOS never suspends hears every advert anyway.
    public func seekPeers(_: Bool) {
        // KnitBLE implements this; BlueZ and the test radios run in processes nothing suspends.
    }
}
