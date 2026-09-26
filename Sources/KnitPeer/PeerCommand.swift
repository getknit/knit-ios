import KnitWire

/// What `knit-peer` was asked to do, from its arguments.
///
/// ```text
/// knit-peer [run] [--adapter hci1] [--adapter-address AA:BB:CC:DD:EE:FF] [--radio-profile android|ios]
///           [--instance NAME | --state DIR] [--name NAME] [--log debug|info|warning|off] [--rssi-floor DBM]
/// knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
/// knit-peer scan [--adapter hci1] [--adapter-address ADDRESS] [--seconds 20] [--advertise android|ios]
///                [--instance NAME | --state DIR]
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

    /// The Edimax BT-8500 on the maintainer's machine, `hci1` (`.agents/context/linux-peer.md`).
    public static let defaultAdapterAddress = "0A:BC:DE:00:00:A1"

    /// The usage text.
    public static let usage = """
        usage:
            knit-peer [run] [--adapter hci1] [--adapter-address ADDRESS] [--radio-profile android|ios]
                [--instance NAME | --state DIR] [--name NAME] [--log debug|info|warning|off] [--rssi-floor DBM]
                [--receive-mtu BYTES] [--send-mtu BYTES]
            knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
            knit-peer scan [--adapter hci1] [--adapter-address ADDRESS] [--seconds 20] [--advertise android|ios]
                [--log debug|info|warning] [--instance NAME | --state DIR]

        A headless Knit node on a Bluetooth adapter that is never hci0. Commands arrive as JSON lines on standard
        input, and replies and events leave as JSON lines on standard output.
        """

    /// Parses the arguments after the program name. `environment` supplies `HOME` and `XDG_STATE_HOME` for the
    /// default state directory.
    public static func parse(_ arguments: [String], environment: [String: String]) throws(UsageError) -> Self {
        var rest = ArraySlice(arguments)
        let verb = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if verb != nil {
            rest.removeFirst()
        }
        var flags = try Flags(parsing: rest)
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
    /// The adapter's name.
    public var adapter = "hci1"
    /// The address the adapter must have.
    public var adapterAddress = PeerCommand.defaultAdapterAddress
    /// `android` or `ios`.
    public var radioProfile = "android"
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

    static let profiles = ["android", "ios"]
    static let logLevels = ["debug", "info", "warning", "off"]

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        stateDirectory = try StateDirectory.resolve(flags: &flags, environment: environment)
        adapter = flags.take("--adapter") ?? adapter
        adapterAddress = flags.take("--adapter-address") ?? adapterAddress
        radioProfile = try flags.take("--radio-profile", oneOf: Self.profiles) ?? radioProfile
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
/// above every phone in range (`keygen --above`) checks the advert without linking to anyone.
public struct ScanOptions: Equatable, Sendable {
    /// The adapter's name.
    public var adapter = "hci1"
    /// The address the adapter must have.
    public var adapterAddress = PeerCommand.defaultAdapterAddress
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
        adapter = flags.take("--adapter") ?? adapter
        adapterAddress = flags.take("--adapter-address") ?? adapterAddress
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

/// The `--flag value` pairs, taken one by one so that whatever is left over is an error.
internal struct Flags {
    private var values: [String: String] = [:]

    init(parsing arguments: ArraySlice<String>) throws(UsageError) {
        var rest = arguments
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--") else {
                throw .unknownFlag(flag)
            }
            guard let value = rest.popFirst(), !value.hasPrefix("--") else {
                throw .missingValue(flag)
            }
            guard values.updateValue(value, forKey: flag) == nil else {
                throw .repeated(flag)
            }
        }
    }

    mutating func take(_ flag: String) -> String? {
        values.removeValue(forKey: flag)
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
