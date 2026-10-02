public import KnitCrypto
public import KnitWire

/// What `knit-peer` was asked to do, from its arguments.
///
/// ```text
/// knit-peer [run] [--adapter-address AA:BB:CC:DD:EE:FF] [--shared-adapter]
///           [--radio-profile android|ios] [--instance NAME | --state DIR] [--name NAME]
///           [--log debug|info|warning|off] [--rssi-floor DBM] [--never-sight NODE_ID[,NODE_ID…]]
///           [--no-gatt-payload] [--no-gatt-reads]
/// knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
/// knit-peer scan [--adapter-address ADDRESS] [--shared-adapter] [--seconds 20]
///                [--advertise android|ios] [--instance NAME | --state DIR]
/// knit-peer help
/// ```
public enum PeerCommand: Equatable, Sendable {
    /// Run the node.
    case run(RunOptions)
    /// Make an identity whose node id sorts above or below another, and keep it.
    case keygen(KeygenOptions)
    /// List the Knit nodes in range for a while, without linking to any.
    case scan(ScanOptions)
    /// Print the usage.
    case help

    /// The Actions ATS2851 dongle on the maintainer's machine, whatever `hciN` it is (`.agents/context/linux-peer.md`).
    public static let defaultAdapterAddress = "F0:0D:00:00:00:02"

    /// The usage text.
    public static let usage = """
        usage:
            knit-peer [run] [--adapter-address ADDRESS] [--shared-adapter]
                [--radio-profile android|ios] [--instance NAME | --state DIR] [--name NAME]
                [--log debug|info|warning|off] [--rssi-floor DBM] [--receive-mtu BYTES] [--send-mtu BYTES]
                [--never-sight NODE_ID[,NODE_ID...]] [--no-gatt-payload] [--no-gatt-reads]
            knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
            knit-peer scan [--adapter-address ADDRESS] [--shared-adapter] [--seconds 20]
                [--advertise android|ios] [--log debug|info|warning] [--instance NAME | --state DIR]

        A headless Knit node on a Bluetooth adapter of its own, found by its address (the ATS2851's unless
        --adapter-address names another), whatever hciN the kernel made it. Commands arrive as JSON lines on standard
        input, and replies and events leave as JSON lines on standard output. The maintainer's adapter is refused
        unless --shared-adapter says other devices use it too; the peer then leaves every link it did not make alone.
        """

    /// Parses the arguments after the program name. `environment` supplies `HOME` and `XDG_STATE_HOME` for the
    /// default state directory.
    public static func parse(_ arguments: [String], environment: [String: String]) throws(UsageError) -> Self {
        var rest = ArraySlice(arguments)
        let verb = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if verb != nil {
            rest.removeFirst()
        }
        var flags = try Flags(parsing: rest, switches: ["--shared-adapter", "--no-gatt-payload", "--no-gatt-reads"])
        switch verb {
        case nil, "run":
            let options = try RunOptions(flags: &flags, environment: environment)
            try flags.finish()
            return .run(options)
        case "keygen":
            let options = try KeygenOptions(flags: &flags, environment: environment)
            try flags.finish()
            return .keygen(options)
        case "scan":
            let options = try ScanOptions(flags: &flags, environment: environment)
            try flags.finish()
            return .scan(options)
        case "help":
            try flags.finish()
            return .help
        case let verb?:
            throw .unknownCommand(verb)
        }
    }
}

/// How to run the node.
public struct RunOptions: Equatable, Sendable {
    /// The address of the adapter to run on.
    public var adapterAddress = PeerCommand.defaultAdapterAddress
    /// Whether other devices use the adapter too, which the maintainer's needs (`AdapterSelection.shared`).
    public var sharedAdapter = false
    /// `android` or `ios`, or `nil` for the radio's own: `android` on BlueZ, and `ios` on a Mac, whose CoreBluetooth
    /// advertises as an iPhone does.
    public var radioProfile: String?
    /// Where the identity and profile live.
    public var stateDirectory: String
    /// A profile name to publish at start, when it differs from the stored one.
    public var name: String?
    /// The lowest level logged to standard error, or `nil` for none.
    public var logLevel: String? = "info"
    /// A promotion floor below Android's −90 dBm, for development only: a quiet phone the peer hears near the
    /// floor then still gets dialed. Nothing may depend on it; the app keeps Android's floor.
    public var rssiFloor: Int?

    /// The loosest floor accepted, the weakest reading a controller reports.
    static let weakestFloor = -127
    /// The receive MTU each L2CAP channel offers, for diagnosing a link; `nil` keeps the radio's default.
    public var receiveMTU: Int?
    /// The largest SDU each L2CAP channel writes, below what the peer offers; `nil` keeps the radio's 247 bytes.
    public var sendMTU: Int?
    /// An LE channel's MTU range.
    static let mtuRange = 23...65_535
    /// Nodes the radio never reports as sighted, a test switch (`--never-sight`): the peer never dials them, and
    /// admits their dials as it admits a dialer it never sighted. An interop run uses it to hold the peer's own dials
    /// to a phone while the phone's dial to the peer is under test. Without it, a peer that sights a phone above it
    /// with `FLAG_DIALS_GATT_PEERS` clear dials the phone, and refuses the phone's dial as one it makes itself.
    public var neverSighted: Set<NodeId> = []
    /// Whether the `ios` profile serves its payload over GATT. `--no-gatt-payload` leaves the doorbell alone in the
    /// `0xFE30` service, so a phone that reads payloads files the peer as a stranger and never sights it: a test
    /// switch for A1's paths, which need a dialer the phone never sighted.
    public var servesGattPayload = true
    /// Whether the `ios` profile reads the GATT payloads of UUID-only peers, as an iPhone does. `--no-gatt-reads`
    /// turns the reader off, and with it the advert's `FLAG_DIALS_GATT_PEERS`: a test switch for a peer an iPhone must
    /// read without the peer connecting to the iPhone at the same moment, which on 2026-09-29 made the iPhone file
    /// the peer as a stranger for ten minutes.
    public var readsGattPayloads = true

    static let profiles = ["android", "ios"]
    static let logLevels = ["debug", "info", "warning", "off"]

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        stateDirectory = try StateDirectory.resolve(flags: &flags, environment: environment)
        adapterAddress = flags.take("--adapter-address") ?? adapterAddress
        sharedAdapter = flags.take(switch: "--shared-adapter")
        radioProfile = try flags.take("--radio-profile", oneOf: Self.profiles)
        name = flags.take("--name")
        let level = try flags.take("--log", oneOf: Self.logLevels) ?? "info"
        logLevel = level == "off" ? nil : level
        if let text = flags.take("--rssi-floor") {
            guard let floor = Int(text), (Self.weakestFloor...0).contains(floor) else {
                throw .invalid(flag: "--rssi-floor", value: text)
            }
            rssiFloor = floor
        }
        receiveMTU = try Self.mtu(flags.take("--receive-mtu"), flag: "--receive-mtu")
        sendMTU = try Self.mtu(flags.take("--send-mtu"), flag: "--send-mtu")
        if let text = flags.take("--never-sight") {
            let nodes = text.split(separator: ",", omittingEmptySubsequences: false).map { NodeId(String($0)) }
            guard !nodes.isEmpty, nodes.allSatisfy({ $0 != nil }) else {
                throw .invalid(flag: "--never-sight", value: text)
            }
            neverSighted = Set(nodes.compactMap(\.self))
        }
        servesGattPayload = !flags.take(switch: "--no-gatt-payload")
        readsGattPayloads = !flags.take(switch: "--no-gatt-reads")
    }

    private static func mtu(_ text: String?, flag: String) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let mtu = Int(text), Self.mtuRange.contains(mtu) else {
            throw .invalid(flag: flag, value: text)
        }
        return mtu
    }

    /// Options as given, for tests and callers that build them.
    public init(stateDirectory: String) {
        self.stateDirectory = stateDirectory
    }
}

/// How long to list the nodes in range, and whether to advertise meanwhile.
///
/// The scan never dials, and a node dials only a peer whose id sorts below its own, so advertising from an identity
/// above every phone in range (`keygen --above`) checks the advert without linking to anyone. A node that advertises
/// only the `0xFE30` UUID, as an iPhone does, is linked just long enough to read its payload over GATT.
public struct ScanOptions: Equatable, Sendable {
    /// The address of the adapter to scan on.
    public var adapterAddress = PeerCommand.defaultAdapterAddress
    /// Whether other devices use the adapter too, which the maintainer's needs (`AdapterSelection.shared`).
    public var sharedAdapter = false
    /// How long to listen.
    public var seconds = 20
    /// The profile to advertise under, or `nil` to stay silent.
    public var advertise: String?
    /// Whose identity to advertise.
    public var stateDirectory: String
    /// The lowest level logged to standard error.
    public var logLevel = "info"

    static let longest = 3600

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        stateDirectory = try StateDirectory.resolve(flags: &flags, environment: environment)
        logLevel = try flags.take("--log", oneOf: ["debug", "info", "warning"]) ?? logLevel
        adapterAddress = flags.take("--adapter-address") ?? adapterAddress
        sharedAdapter = flags.take(switch: "--shared-adapter")
        advertise = try flags.take("--advertise", oneOf: RunOptions.profiles)
        if let text = flags.take("--seconds") {
            guard let parsed = Int(text), (1...Self.longest).contains(parsed) else {
                throw .invalid(flag: "--seconds", value: text)
            }
            seconds = parsed
        }
    }
}

/// Where a new identity's node id must land.
public struct KeygenOptions: Equatable, Sendable {
    /// Where to keep the identity.
    public var stateDirectory: String
    /// The window its node id must sort in.
    public var window: KeyGen.Window

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        stateDirectory = try StateDirectory.resolve(flags: &flags, environment: environment)
        window = KeyGen.Window(
            above: try Self.nodeId(flags.take("--above"), "--above"), below: try Self.nodeId(flags.take("--below"), "--below"))
        guard window.above != nil || window.below != nil else {
            throw .missing("--above, --below or both")
        }
        if let above = window.above, let below = window.below, above >= below {
            throw .invalid(flag: "--below", value: "must sort above --above")
        }
    }

    private static func nodeId(_ text: String?, _ flag: String) throws(UsageError) -> NodeId? {
        guard let text else {
            return nil
        }
        guard let parsed = NodeId(text) else {
            throw .invalid(flag: flag, value: text)
        }
        return parsed
    }
}

/// Why the arguments did not parse.
public enum UsageError: Error, Equatable, Sendable {
    /// Not `run`, `keygen` or `help`.
    case unknownCommand(String)
    /// A flag this command does not take.
    case unknownFlag(String)
    /// A flag with no value after it.
    case missingValue(String)
    /// A value a flag does not accept.
    case invalid(flag: String, value: String)
    /// A flag given twice.
    case repeated(String)
    /// Something required that was not given.
    case missing(String)
}

/// The `--flag value` pairs and the valueless `switches`, taken one by one so that whatever is left over is an error.
internal struct Flags {
    private var values: [String: String] = [:]

    init(parsing arguments: ArraySlice<String>, switches: Set<String>) throws(UsageError) {
        var rest = arguments
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--") else {
                throw .unknownFlag(flag)
            }
            var value = ""
            if !switches.contains(flag) {
                guard let next = rest.popFirst(), !next.hasPrefix("--") else {
                    throw .missingValue(flag)
                }
                value = next
            }
            guard values.updateValue(value, forKey: flag) == nil else {
                throw .repeated(flag)
            }
        }
    }

    mutating func take(_ flag: String) -> String? {
        values.removeValue(forKey: flag)
    }

    /// Whether the switch `flag` was given.
    mutating func take(switch flag: String) -> Bool {
        values.removeValue(forKey: flag) != nil
    }

    mutating func take(_ flag: String, oneOf allowed: [String]) throws(UsageError) -> String? {
        guard let value = values.removeValue(forKey: flag) else {
            return nil
        }
        guard allowed.contains(value) else {
            throw .invalid(flag: flag, value: value)
        }
        return value
    }

    func finish() throws(UsageError) {
        if let flag = values.keys.min() {
            throw .unknownFlag(flag)
        }
    }
}

/// Where a peer keeps its state: `--state`, or `--instance` under `$XDG_STATE_HOME/knit-peer`
/// (`~/.local/state/knit-peer` by default), so that two peers on one machine keep two identities.
internal enum StateDirectory {
    static func resolve(flags: inout Flags, environment: [String: String]) throws(UsageError) -> String {
        let explicit = flags.take("--state")
        let instance = flags.take("--instance")
        if let explicit {
            guard instance == nil else {
                throw .invalid(flag: "--instance", value: "cannot go with --state")
            }
            return explicit
        }
        let name = instance ?? "default"
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw .invalid(flag: "--instance", value: name)
        }
        if let state = environment["XDG_STATE_HOME"], state.hasPrefix("/") {
            return state + "/knit-peer/" + name
        }
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            throw .missing("HOME, or --state")
        }
        return home + "/.local/state/knit-peer/" + name
    }
}
