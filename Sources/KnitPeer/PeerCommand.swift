public import KnitCrypto
public import KnitWire

/// What `knit-peer` was asked to do, from its arguments.
///
/// ```text
/// knit-peer [run] [--adapter-address AA:BB:CC:DD:EE:FF] [--shared-adapter]
///           [--radio-profile android|ios] [--instance NAME | --state DIR] [--name NAME]
///           [--log debug|info|warning|off] [--rssi-floor DBM] [--never-sight NODE_ID[,NODE_ID…]]
///           [--only-link NODE_ID[,NODE_ID…]]
///           [--no-gatt-payload] [--gatt-reads | --no-gatt-reads] [--feed window|pace] [--ratchet | --no-ratchet]
///           [--no-presence-keys] [--blind] [--stop-reading-after SECONDS] [--flood BYTES_PER_SECOND] [--lying]
///           [--seal on|off|downgrade|plain-reply] [--flip-sealed-bit] [--psm PSM]
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
                [--never-sight NODE_ID[,NODE_ID...]] [--only-link NODE_ID[,NODE_ID...]]
                [--no-gatt-payload] [--gatt-reads | --no-gatt-reads]
                [--feed window|pace] [--ratchet | --no-ratchet] [--no-presence-keys] [--blind]
                [--stop-reading-after SECONDS] [--flood BYTES_PER_SECOND] [--lying]
                [--seal on|off|downgrade|plain-reply] [--flip-sealed-bit] [--psm PSM]
            knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME | --state DIR]
            knit-peer scan [--adapter-address ADDRESS] [--shared-adapter] [--seconds 20]
                [--advertise android|ios] [--log debug|info|warning] [--instance NAME | --state DIR]
            knit-peer stranger [--adapter-address ADDRESS] [--shared-adapter] [--payload none|forged]
                [--rotate SECONDS] [--seconds 1800] [--log debug|info|warning]

        A headless Knit node on a Bluetooth adapter of its own, found by its address (--adapter-address, or
        $KNIT_ADAPTER_A), whatever hciN the kernel made it. Commands arrive as JSON lines on standard input, and
        replies and events leave as JSON lines on standard output. The adapters in $KNIT_ADAPTER_RESERVED are
        refused unless --shared-adapter says other devices use them too; the peer then leaves every link it did not
        make alone. The forward-secrecy ratchet is on, as in the app, and keeps the peer's prekeys beside its
        identity; --no-ratchet runs the peer as a build from before it, and --ratchet, the default, is still taken.
        The peer mints its own presence keys and hands them to its linked contacts under the ratchet, as the app does;
        --no-presence-keys mints and sends none.
        --blind airs a rotating tag in place of the node id, as a debug iPhone with its switch on does: the ios profile in
        its GATT payload, the android profile in its service data. The advert and advert-rotate commands turn the switch
        and force a rotation while the peer runs.
        --stop-reading-after is for trials: that many seconds after it starts, the peer stops reading its channels.
        --flood is for trials too: while linked, the peer writes that many bytes a second of undecodable frames to
        every link, as a neighbour flooding it would, holding back while its own queue to that link is full.
        --lying is for trials too: only with it do lie-blobhas, junk, advertise-photo, pad-profile and ask-blob take.
        --only-link is for trials too: the peer links with the named nodes alone, both ways, and refuses every other
        node's dial at its HELLO. It never dials a blinded advert until a presence key, a claim or a hint names a
        listed node, so it first meets a blinding phone by that phone's dial, or once linked before.
        --seal is for trials too: off seals nothing, as Android v2.11.0; downgrade strips the advert's flag and keeps the
        HELLO's bit; plain-reply answers a sealed dial with a plain HELLO. --flip-sealed-bit flips one bit in each link's
        first sealed frame after it comes up. --psm listens on that LE PSM (128 to 255) instead of the kernel's: give a
        fresh one each time --seal changes, so a phone holding the old GATT payload fails its dial and reads it again.
        `stranger` is a test stimulus that never links: it advertises the 0xFE30
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
            parsing: rest,
            switches: [
                "--shared-adapter", "--no-gatt-payload", "--gatt-reads", "--no-gatt-reads", "--ratchet", "--no-ratchet",
                "--no-presence-keys", "--blind",
                "--lying",
                "--flip-sealed-bit",
            ])
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
    /// The only nodes the peer links with, a trial's switch (`--only-link`, knit-ios #58), or `nil` for any: every other
    /// node's dial is refused at its HELLO and never registered, so a flood or a lie reaches none of them, and a blinded
    /// advert no key, claim or hint resolves to a listed node is never dialed (``LinkManager/Configuration/onlyLinks``).
    public var onlyLinks: Set<NodeId>?
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
    /// Whether the forward-secrecy ratchet's switch is on (`MeshConfiguration.ratchet`, ADR 2026-10.5sk9): by default, as
    /// in the app, and with `--ratchet`, which an interop run still passes. On, the peer keeps its prekeys beside its
    /// identity, publishes one with the ratchet's bits in its profile, and seals and opens DMs with the ratchet.
    /// `--no-ratchet` turns it off, and the peer is what it was before the ratchet.
    public var ratchet = true
    /// Whether the peer mints, rotates and sends its own presence keys (`MeshConfiguration.sendsOwnPresenceKeys`, ADR
    /// 2026-11.prsp): by default, as in the app; `--no-presence-keys` turns it off. They are sealed by the ratchet, so with
    /// `--no-ratchet`, which keeps no prekeys and so no generation, none is minted either.
    public var presenceKeys = true
    /// Whether the peer starts airing a rotating tag in place of its node id (`--blind`: the runtime switch,
    /// ``LinkManager/Configuration/blindSwitchOn``, behind a gate knit-peer always opens; ADR 2026-11.prsp): the `ios` profile
    /// serves it as a blinding iPhone's GATT payload, with the advert's `FLAG_BLINDED`, and the `android` profile airs it as
    /// service data. Off by default, unlike a debug build's app since A11, so a run that judges ids gets them unasked;
    /// `advert` turns it while the peer runs.
    public var blind = false
    /// Seconds after start the radio stops reading its channels, a trial's switch (`--stop-reading-after`); `nil` never stops.
    public var stopReadingAfterSeconds: Int?
    /// Bytes a second of undecodable FRAME records written to every live link, a trial's switch (`--flood`); `nil`
    /// writes none (ADR 2026-10.f5zs, rule 6).
    public var floodBytesPerSecond: Int?
    /// Whether the lying commands take, a trial's switch (`--lying`, `door-cap-lying-peers`); every lie starts unset.
    public var lying = false
    /// The link manager's seal switch, a trial's (`--seal`; the `link-seal` contract's T5 and T6): `on` unless told.
    public var sealSwitch = "on"
    /// Whether the radio flips a bit in each link's first sealed frame after link-up, a trial's switch
    /// (`--flip-sealed-bit`, BlueZ only).
    public var flipsSealedBit = false
    /// The LE PSM to listen on, or `nil` for the kernel's (`--psm`, BlueZ only).
    public var listenPSM: Int?
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
        neverSighted = try Self.nodes(flags.take("--never-sight"), flag: "--never-sight") ?? []
        onlyLinks = try Self.nodes(flags.take("--only-link"), flag: "--only-link")
        servesGattPayload = !flags.take(switch: "--no-gatt-payload")
        let reads = flags.take(switch: "--gatt-reads")
        let readsNone = flags.take(switch: "--no-gatt-reads")
        guard !(reads && readsNone) else {
            throw .invalid(flag: "--gatt-reads", value: "--no-gatt-reads")
        }
        gattReads = reads ? .on : readsNone ? .off : .asProfile
        feedWindow = try flags.take("--feed", oneOf: Self.feeds).map { $0 == "window" } ?? feedWindow
        let ratchetOn = flags.take(switch: "--ratchet")
        let ratchetOff = flags.take(switch: "--no-ratchet")
        guard !(ratchetOn && ratchetOff) else {
            throw .invalid(flag: "--ratchet", value: "--no-ratchet")
        }
        ratchet = !ratchetOff
        presenceKeys = !flags.take(switch: "--no-presence-keys")
        blind = flags.take(switch: "--blind")
        stopReadingAfterSeconds = try Self.stopReadingAfter(flags.take("--stop-reading-after"))
        floodBytesPerSecond = try Self.flood(flags.take("--flood"))
        lying = flags.take(switch: "--lying")
        sealSwitch = try flags.take("--seal", oneOf: Self.sealSwitches) ?? sealSwitch
        flipsSealedBit = flags.take(switch: "--flip-sealed-bit")
        listenPSM = try Self.psm(flags.take("--psm"))
    }

    /// The node ids a comma-separated `text` names, or `nil` when the flag was not given; an empty list or a bad id is
    /// refused.
    private static func nodes(_ text: String?, flag: String) throws(UsageError) -> Set<NodeId>? {
        guard let text else {
            return nil
        }
        let nodes = text.split(separator: ",", omittingEmptySubsequences: false).map { NodeId(String($0)) }
        guard nodes.allSatisfy({ $0 != nil }) else {
            throw .invalid(flag: flag, value: text)
        }
        return Set(nodes.compactMap(\.self))
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
