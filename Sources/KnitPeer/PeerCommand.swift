public import KnitCrypto
public import KnitWire

/// What `knit-peer` was asked to do, from its arguments.
///
/// ```text
/// knit-peer [run] [--adapter-address AA:BB:CC:DD:EE:FF] [--shared-adapter]
///           [--radio-profile android|ios] [--instance NAME | --state DIR] [--name NAME]
///           [--log debug|info|warning|off] [--rssi-floor DBM] [--never-sight NODE_ID[,NODE_ID…]]
///           [--no-gatt-payload] [--gatt-reads | --no-gatt-reads] [--feed window|pace] [--ratchet]
/// knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
/// knit-peer scan [--adapter-address ADDRESS] [--shared-adapter] [--seconds 20]
///                [--advertise android|ios] [--instance NAME | --state DIR]
/// knit-peer stranger [--adapter-address ADDRESS] [--shared-adapter] [--payload none|forged]
///                    [--rotate SECONDS] [--seconds 1800] [--log debug|info|warning]
/// knit-peer help
/// ```
public enum PeerCommand: Equatable, Sendable {
    /// Run the node.
    case run(RunOptions)
    /// Make an identity whose node id sorts above or below another, and keep it.
    case keygen(KeygenOptions)
    /// List the Knit nodes in range for a while, without linking to any.
    case scan(ScanOptions)
    /// Advertise the `0xFE30` UUID as a device that is not a Knit node, a test stimulus.
    case stranger(StrangerOptions)
    /// Print the usage.
    case help

    /// The variable naming the default adapter's address, the lab's dongle A, whatever `hciN` it is. The lab's addresses
    /// stay out of the repository: `.private/lab.env` holds them, and the scripts export them (ADR 2026-10.ab6k).
    public static let adapterVariable = "KNIT_ADAPTER_A"
    /// The variable listing, comma-separated, the adapters refused unless shared: ones with live connections of their
    /// own (`AdapterSelection.shared`).
    public static let reservedVariable = "KNIT_ADAPTER_RESERVED"

    /// The usage text.
    public static let usage = """
        usage:
            knit-peer [run] [--adapter-address ADDRESS] [--shared-adapter]
                [--radio-profile android|ios] [--instance NAME | --state DIR] [--name NAME]
                [--log debug|info|warning|off] [--rssi-floor DBM] [--receive-mtu BYTES] [--send-mtu BYTES]
                [--never-sight NODE_ID[,NODE_ID...]] [--no-gatt-payload] [--gatt-reads | --no-gatt-reads]
                [--feed window|pace] [--ratchet]
            knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
            knit-peer scan [--adapter-address ADDRESS] [--shared-adapter] [--seconds 20]
                [--advertise android|ios] [--log debug|info|warning] [--instance NAME | --state DIR]
            knit-peer stranger [--adapter-address ADDRESS] [--shared-adapter] [--payload none|forged]
                [--rotate SECONDS] [--seconds 1800] [--log debug|info|warning]

        A headless Knit node on a Bluetooth adapter of its own, found by its address (--adapter-address, or
        $KNIT_ADAPTER_A), whatever hciN the kernel made it. Commands arrive as JSON lines on standard input, and
        replies and events leave as JSON lines on standard output. The adapters in $KNIT_ADAPTER_RESERVED are
        refused unless --shared-adapter says other devices use them too; the peer then leaves every link it did not
        make alone. --ratchet turns on the forward-secrecy ratchet, still dark in the app, and keeps the peer's
        prekeys beside its identity. `stranger` is a test stimulus that never links: it advertises the 0xFE30
        UUID as a device that is not Knit's, registering its advert afresh every --rotate seconds.
        """

    /// Parses the arguments after the program name. `environment` supplies `HOME` and `XDG_STATE_HOME` for the
    /// default state directory, and the default and reserved adapters (`adapterVariable`, `reservedVariable`).
    public static func parse(_ arguments: [String], environment: [String: String]) throws(UsageError) -> Self {
        var rest = ArraySlice(arguments)
        let verb = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if verb != nil {
            rest.removeFirst()
        }
        var flags = try Flags(
            parsing: rest, switches: ["--shared-adapter", "--no-gatt-payload", "--gatt-reads", "--no-gatt-reads", "--ratchet"])
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
        case "stranger":
            let options = try StrangerOptions(flags: &flags, environment: environment)
            try flags.finish()
            return .stranger(options)
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
    /// The address of the adapter to run on, or `nil` when neither the flag nor the environment names one. Only a
    /// BlueZ radio needs it.
    public var adapterAddress: String?
    /// Whether other devices use the adapter too, which a reserved one needs (`AdapterSelection.shared`).
    public var sharedAdapter = false
    /// The adapters refused unless shared, from `PeerCommand.reservedVariable`.
    public var reservedAdapters: [String] = []
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
    /// Whether the peer reads the GATT payloads of UUID-only peers, with the advert's `FLAG_DIALS_GATT_PEERS` beside it.
    /// By default it does as its profile does: the `ios` profile reads, as an iPhone does, and the `android` profile does
    /// not.
    /// `--no-gatt-reads` turns the reader off, a test switch for a peer an iPhone must read without the peer connecting
    /// to the iPhone at the same moment, which on 2026-09-29 made the iPhone file the peer as a stranger for ten
    /// minutes. `--gatt-reads` turns it on, so the `android` profile advertises as a release Android does: service
    /// data, the flag set, and no doorbell (interop-audit finding IOS-9). With `--never-sight`, it is a gapped Android
    /// that never dials the iPhone.
    public var gattReads = GattReads.asProfile
    /// Whether a file to a peer that reports is clocked by its reports, and a file streaming in is reported at the
    /// window's cadence (``LinkManager/Configuration/feedWindow``, ADR 2026-10.xwjc). `--feed pace` turns both off, the
    /// A/B switch Android's `…debug.LINKTUNE --es feed` is.
    public var feedWindow = true
    /// Whether the forward-secrecy ratchet's switch is on (`MeshConfiguration.ratchet`, ADR 2026-10.5sk9): `--ratchet`,
    /// with which the peer keeps its prekeys beside its identity, publishes one with the ratchet's bits in its profile,
    /// and seals and opens DMs with the ratchet. Off, the peer is what it was before the ratchet.
    public var ratchet = false

    static let profiles = ["android", "ios"]
    static let feeds = ["window", "pace"]
    static let logLevels = ["debug", "info", "warning", "off"]

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        stateDirectory = try StateDirectory.resolve(flags: &flags, environment: environment)
        adapterAddress = flags.take("--adapter-address") ?? AdapterEnvironment.address(environment)
        sharedAdapter = flags.take(switch: "--shared-adapter")
        reservedAdapters = AdapterEnvironment.reserved(environment)
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
        let reads = flags.take(switch: "--gatt-reads")
        let readsNone = flags.take(switch: "--no-gatt-reads")
        guard !(reads && readsNone) else {
            throw .invalid(flag: "--gatt-reads", value: "--no-gatt-reads")
        }
        gattReads = reads ? .on : readsNone ? .off : .asProfile
        feedWindow = try flags.take("--feed", oneOf: Self.feeds).map { $0 == "window" } ?? feedWindow
        ratchet = flags.take(switch: "--ratchet")
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
    /// The address of the adapter to scan on, or `nil` when neither the flag nor the environment names one.
    public var adapterAddress: String?
    /// Whether other devices use the adapter too, which a reserved one needs (`AdapterSelection.shared`).
    public var sharedAdapter = false
    /// The adapters refused unless shared, from `PeerCommand.reservedVariable`.
    public var reservedAdapters: [String] = []
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
        adapterAddress = flags.take("--adapter-address") ?? AdapterEnvironment.address(environment)
        sharedAdapter = flags.take(switch: "--shared-adapter")
        reservedAdapters = AdapterEnvironment.reserved(environment)
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

/// Whether knit-peer reads GATT payloads, and so sets `FLAG_DIALS_GATT_PEERS` (`--gatt-reads`, `--no-gatt-reads`).
public enum GattReads: Equatable, Sendable {
    /// As the radio profile does: the `ios` profile reads, and the `android` profile does not.
    case asProfile
    /// Reads, whatever the profile.
    case on
    /// Reads nothing, whatever the profile.
    case off
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

/// The adapters the environment names (`PeerCommand.adapterVariable`, `PeerCommand.reservedVariable`).
internal enum AdapterEnvironment {
    static func address(_ environment: [String: String]) -> String? {
        environment[PeerCommand.adapterVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func reserved(_ environment: [String: String]) -> [String] {
        (environment[PeerCommand.reservedVariable] ?? "").split(separator: ",").map { String($0.filter { $0 != " " }) }
            .filter { !$0.isEmpty }
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
