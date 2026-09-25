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
}

/// The radio under ``LinkManager``: it advertises, scans, dials, accepts and moves bytes, and decides nothing.
/// KnitBLE (CoreBluetooth) and KnitBlueZ implement it; everything about who links to whom is the link manager's.
public protocol Radio: AnyObject, Sendable {
    /// Whether this radio's advert carries the `0xFE30` service data every Knit build reads. An iPhone's cannot:
    /// iOS advertises only a name and service UUIDs, so an iPhone is found through its GATT payload, which Android
    /// 2.7 never reads.
    var advertisesServiceData: Bool { get }

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

    /// Closes a channel.
    func close(_ channel: ChannelID)
}
