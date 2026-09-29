public import KnitMesh

/// The status line over the chat list: how many peers are linked, or why none can be (MVP item 10). Each reason
/// the radio cannot run has its own line.
public enum ConnectionStatus: Sendable, Equatable {
    /// Running, with this many peers linked.
    case linked(Int)
    /// Running, before the radio has said anything.
    case starting
    /// Stopped in Settings.
    case stopped
    /// Bluetooth is switched off.
    case bluetoothOff
    /// Knit may not use Bluetooth.
    case notAllowed
    /// No Bluetooth LE here.
    case unsupported

    /// The status for a radio in `radio`, a mesh that `isRunning` or not, and `linked` peers. A radio that cannot
    /// run says why even while the mesh is stopped, since starting it would not help.
    public init(radio: RadioState?, isRunning: Bool, linked: Int) {
        switch radio {
        case .unsupported:
            self = .unsupported
        case .unauthorized:
            self = .notAllowed
        case .off:
            self = isRunning ? .bluetoothOff : .stopped
        case .on:
            self = isRunning ? .linked(linked) : .stopped
        case nil:
            self = isRunning ? .starting : .stopped
        }
    }

    /// The line to show.
    public var line: String {
        switch self {
        case .linked(let count):
            count == 0 ? Copy.Status.looking : Copy.Status.linked(count)
        case .starting:
            Copy.Status.starting
        case .stopped:
            Copy.Status.stopped
        case .bluetoothOff:
            Copy.Status.bluetoothOff
        case .notAllowed:
            Copy.Status.notAllowed
        case .unsupported:
            Copy.Status.unsupported
        }
    }

    /// Whether the line reports a problem rather than progress.
    public var isWarning: Bool {
        switch self {
        case .linked, .starting:
            false
        case .stopped, .bluetoothOff, .notAllowed, .unsupported:
            true
        }
    }

    /// Whether the line offers Start: only a stopped mesh whose radio could run.
    public var offersStart: Bool {
        self == .stopped
    }

    /// Whether the line offers Settings: only a refused permission, which nothing in the app can change.
    public var offersSettings: Bool {
        self == .notAllowed
    }

    /// The state the line's identifier names (``AccessibilityID/chatListStatus(_:)``), which the device tests wait on.
    public var accessibilityState: AccessibilityID.StatusState {
        switch self {
        case .linked(let count):
            count == 0 ? .looking : .linked
        case .starting:
            .starting
        case .stopped:
            .stopped
        case .bluetoothOff:
            .bluetoothOff
        case .notAllowed:
            .notAllowed
        case .unsupported:
            .unsupported
        }
    }
}
