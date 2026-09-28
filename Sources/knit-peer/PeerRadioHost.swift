import KnitMesh
import KnitPeer

/// A platform's radio for the peer: BlueZ on Linux (``BlueZHost``), CoreBluetooth on a Mac (``CoreBluetoothHost``).
/// Each platform names its own `PeerHost`.
internal protocol PeerRadioHost: Sendable {
    /// The radio the mesh runs on.
    var radio: any Radio { get }
    /// The profile its advert and HELLO follow, as `status` reports it.
    var profile: String { get }

    /// The radio `options` ask for, or why it cannot start.
    init(_ options: RunOptions, log: any KnitLog) throws(PeerHostError)

    /// Withdraws the advert and closes every channel.
    func shutdown() async

    /// Lists the nodes in range for `knit-peer scan`, without linking to any.
    static func scan(_ options: ScanOptions) async
}

/// Why a peer's radio cannot start as asked.
internal enum PeerHostError: Error, CustomStringConvertible {
    /// The adapter is missing, is not the one named, or is `hci0` unshared.
    case adapter(any Error)
    /// An option this platform's radio cannot honour.
    case unsupported(String)

    var description: String {
        switch self {
        case .adapter(let error):
            "\(error)"
        case .unsupported(let why):
            why
        }
    }
}
