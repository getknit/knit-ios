/// Where an L2CAP dial goes: a device address, and whether it is random. Android dials and advertises from a
/// resolvable private address, which is random.
public struct DialTarget: Equatable, Sendable {
    /// The device's address.
    public var address: BluetoothAddress
    /// Whether the address is random rather than public.
    public var isRandom: Bool

    /// Makes a target.
    public init(address: BluetoothAddress, isRandom: Bool) {
        self.address = address
        self.isRandom = isRandom
    }
}

/// A listening socket, and the PSM the kernel gave it.
public struct ListeningSocket: Equatable, Sendable {
    /// The socket, non-blocking.
    public let descriptor: Int32
    /// The PSM to advertise.
    public let psm: UInt16

    /// Wraps a listener.
    public init(descriptor: Int32, psm: UInt16) {
        self.descriptor = descriptor
        self.psm = psm
    }
}

/// A socket call that failed, with its `errno`.
public struct SocketError: Error, Equatable, Sendable {
    /// The call, `bind` or `connect`.
    public let call: String
    /// The `errno` it set.
    public let code: Int32

    /// Records a failure.
    public init(call: String, code: Int32) {
        self.call = call
        self.code = code
    }
}

/// Where the radio's channels come from: LE credit-based L2CAP sockets on the adapter, or, in the tests, Unix
/// sequenced-packet sockets that keep the same message boundaries.
///
/// Every descriptor is non-blocking. The radio owns what it is given, and closes it.
public protocol SocketProvider: Sendable {
    /// Opens the listener peers dial.
    func listen() throws(SocketError) -> ListeningSocket

    /// Starts a dial to `target`'s listener on `psm`. The descriptor turns writable when the dial completes, and
    /// `SO_ERROR` then says whether it opened.
    func dial(_ target: DialTarget, psm: UInt16) throws(SocketError) -> Int32

    /// The largest single write an open channel takes.
    func sendLimit(of descriptor: Int32) -> Int
}
