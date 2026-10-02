/// A Bluetooth device address, `AA:BB:CC:DD:EE:FF`, in the order BlueZ prints it.
public struct BluetoothAddress: Hashable, Sendable, CustomStringConvertible {
    private static let byteCount = 6
    private static let digitsPerByte = 2
    private static let hexRadix = 16

    /// The six bytes, most significant first, as printed.
    public let bytes: [UInt8]

    /// Parses six colon-separated hex bytes, either case.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { $0.utf8.count == Self.digitsPerByte ? UInt8($0, radix: Self.hexRadix) : nil }
        guard parts.count == Self.byteCount, parsed.count == Self.byteCount else {
            return nil
        }
        bytes = parsed
    }

    /// An address from its six bytes, most significant first.
    init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        self.bytes = bytes
    }

    /// The bytes in the kernel's `bdaddr_t` order, least significant first.
    public var littleEndian: [UInt8] {
        bytes.reversed()
    }

    /// The address in upper case, as BlueZ writes it.
    public var description: String {
        bytes.map { byte in
            let digits = String(byte, radix: Self.hexRadix, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }
        .joined(separator: ":")
    }
}

/// Which adapter the peer may use, and the address it must have. An adapter is chosen by its address, since its name is
/// only the order its driver bound it in: a reboot on 2026-10-01 made the ATS2851 `hci0` and the maintainer's adapter
/// `hci1` (ADR 2026-09.5ftc, amended 2026-10-01). The maintainer's adapter has live connections, so it is refused unless
/// the selection is shared, which the maintainer allows one session at a time (`.agents/rules/devices.md`).
public struct AdapterSelection: Equatable, Sendable {
    /// Why an adapter was refused.
    public enum Refusal: Error, Equatable, Sendable {
        /// Not an `hciN` name.
        case notAnAdapterName(String)
        /// The maintainer's adapter, which is used only when shared.
        case reservedAdapter
        /// Not a Bluetooth address.
        case notAnAddress(String)
        /// No adapter has the address, or the named one is gone.
        case absent(String)
        /// The adapter is there with another address.
        case wrongAddress(adapter: String, expected: BluetoothAddress, found: String)
    }

    /// The maintainer's own adapter, an Intel controller holding their speaker and keyboard.
    static let maintainersAdapter = "A0:00:00:00:00:01"

    /// The adapter's name this boot, `hci1`.
    public let name: String
    /// The address it must have.
    public let address: BluetoothAddress
    /// Whether other devices use the adapter too. The peer then leaves alone every link it did not make.
    public let shared: Bool

    /// Selects `name`, which must have `expectedAddress`. Refuses anything that is not `hciN`, and the maintainer's
    /// adapter unless `shared`.
    public init(name: String, expectedAddress: String, shared: Bool = false) throws(Refusal) {
        let digits = name.utf8.dropFirst("hci".utf8.count)
        guard name.hasPrefix("hci"), !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            throw .notAnAdapterName(name)
        }
        self.name = name
        address = try Self.admit(expectedAddress, shared: shared)
        self.shared = shared
    }

    /// Parses `text`, and refuses the maintainer's adapter unless `shared`.
    static func admit(_ text: String, shared: Bool) throws(Refusal) -> BluetoothAddress {
        guard let parsed = BluetoothAddress(text) else {
            throw .notAnAddress(text)
        }
        guard parsed.description != maintainersAdapter || shared else {
            throw .reservedAdapter
        }
        return parsed
    }

    /// Selects whichever adapter BlueZ lists with `address`, under the name the kernel gave it this boot, from the
    /// objects of a `GetManagedObjects` answer.
    static func find(
        _ address: String, shared: Bool, among objects: [(path: String, interfaces: [(name: String, properties: DBusValue)])]
    ) throws(Refusal) -> Self {
        let wanted = try admit(address, shared: shared)
        let root = "/org/bluez/"
        let match = objects.first { object in
            let adapter = object.interfaces.first { $0.name == BlueZ.adapterInterface }
            return object.path.hasPrefix(root) && adapter?.properties["Address"]?.text.flatMap(BluetoothAddress.init) == wanted
        }
        guard let match else {
            throw .absent(wanted.description)
        }
        return try Self(name: String(match.path.dropFirst(root.count)), expectedAddress: address, shared: shared)
    }

    /// The adapter's BlueZ object path, `/org/bluez/hci1`.
    public var path: String {
        "/org/bluez/" + name
    }

    /// Whether `objectPath` is the adapter or one of its devices. Everything else on the bus, another adapter's
    /// devices above all, is ignored.
    public func owns(_ objectPath: String) -> Bool {
        objectPath == path || objectPath.hasPrefix(path + "/")
    }

    /// Checks what BlueZ reported for the adapter: it must be present, with the expected address.
    public func check(reportedAddress: String?) throws(Refusal) {
        guard let reportedAddress else {
            throw .absent(name)
        }
        guard BluetoothAddress(reportedAddress) == address else {
            throw .wrongAddress(adapter: name, expected: address, found: reportedAddress)
        }
    }
}
