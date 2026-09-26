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

/// Which adapter the peer may use, and the address it must have. `hci0` is the maintainer's own adapter, with live
/// connections, so it is refused by name, and the chosen adapter must have the address it was expected to have, in
/// case the dongles were enumerated in another order (`.agents/rules/devices.md`).
public struct AdapterSelection: Equatable, Sendable {
    /// Why an adapter was refused.
    public enum Refusal: Error, Equatable, Sendable {
        /// Not an `hciN` name.
        case notAnAdapterName(String)
        /// `hci0`, which is never used.
        case reservedAdapter
        /// Not a Bluetooth address.
        case notAnAddress(String)
        /// The adapter is not there.
        case absent(String)
        /// The adapter is there with another address.
        case wrongAddress(adapter: String, expected: BluetoothAddress, found: String)
    }

    /// The adapter's name, `hci1`.
    public let name: String
    /// The address it must have.
    public let address: BluetoothAddress

    /// Selects `name`, which must have `expectedAddress`. Refuses `hci0` and anything that is not `hciN`.
    public init(name: String, expectedAddress: String) throws(Refusal) {
        let digits = name.utf8.dropFirst("hci".utf8.count)
        guard name.hasPrefix("hci"), !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            throw .notAnAdapterName(name)
        }
        guard name != "hci0" else {
            throw .reservedAdapter
        }
        guard let parsed = BluetoothAddress(expectedAddress) else {
            throw .notAnAddress(expectedAddress)
        }
        self.name = name
        address = parsed
    }

    /// The adapter's BlueZ object path, `/org/bluez/hci1`.
    public var path: String {
        "/org/bluez/" + name
    }

    /// Whether `objectPath` is the adapter or one of its devices. Everything else on the bus, `hci0`'s devices
    /// above all, is ignored.
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
