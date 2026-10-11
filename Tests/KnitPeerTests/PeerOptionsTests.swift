import KnitCrypto
import KnitPeer
import KnitTestSupport
import KnitWire
import Testing

/// `knit-peer`'s arguments.
@Suite struct PeerOptionsTests {
    private let home = ["HOME": "/home/tester"]

    private func run(_ arguments: [String], environment: [String: String]? = nil) throws -> RunOptions {
        guard case .run(let options) = try PeerCommand.parse(arguments, environment: environment ?? home) else {
            throw UsageError.missing("run")
        }
        return options
    }

    @Test func runIsTheDefaultWithTheRadiosOwnProfile() throws {
        let options = try run([])
        #expect(options.adapterAddress == nil, "no address of the lab's in the code")
        #expect(options.reservedAdapters.isEmpty)
        #expect(options.radioProfile == nil, "the radio's own")
        #expect(options.stateDirectory == "/home/tester/.local/state/knit-peer/default")
        #expect(options.name == nil)
        #expect(options.logLevel == "info")
        #expect(options.rssiFloor == nil, "Android's floor unless asked")
        #expect(!options.sharedAdapter)
        #expect(try run(["run"]) == options)
    }

    /// The lab's adapters come from the environment (`.private/lab.env`), and a flag still wins.
    @Test func theEnvironmentNamesTheDefaultAndReservedAdapters() throws {
        let lab = home.merging([
            PeerCommand.adapterVariable: "C0:FF:EE:00:00:0A", PeerCommand.reservedVariable: "A0:00:00:00:00:01, A0:00:00:00:00:02,",
        ]) { $1 }
        let options = try run([], environment: lab)
        #expect(options.adapterAddress == "C0:FF:EE:00:00:0A", "by address, whatever hciN it is")
        #expect(options.reservedAdapters == ["A0:00:00:00:00:01", "A0:00:00:00:00:02"])
        #expect(try run(["--adapter-address", "00:11:22:33:44:55"], environment: lab).adapterAddress == "00:11:22:33:44:55")
        guard case .scan(let scan) = try PeerCommand.parse(["scan"], environment: lab) else {
            Issue.record("not a scan")
            return
        }
        #expect(scan.adapterAddress == "C0:FF:EE:00:00:0A")
        #expect(scan.reservedAdapters == options.reservedAdapters)
        #expect(try run([], environment: home.merging([PeerCommand.adapterVariable: ""]) { $1 }).adapterAddress == nil)
    }

    /// An index names whichever adapter the kernel bound in that place this boot, so no flag takes one.
    @Test func noFlagNamesAnAdapterByItsIndex() {
        #expect(throws: UsageError.unknownFlag("--adapter")) { try run(["--adapter", "hci1"]) }
        #expect(throws: UsageError.unknownFlag("--adapter")) { try PeerCommand.parse(["scan", "--adapter", "hci1"], environment: home) }
    }

    @Test func aSharedAdapterIsASwitchForRunAndScanOnly() throws {
        let options = try run(["--shared-adapter", "--adapter-address", "A0:00:00:00:00:01"])
        #expect(options.sharedAdapter)
        guard case .scan(let scan) = try PeerCommand.parse(["scan", "--shared-adapter", "--seconds", "5"], environment: home) else {
            Issue.record("not a scan")
            return
        }
        #expect(scan.sharedAdapter)
        #expect(scan.seconds == 5)
        #expect(throws: UsageError.unknownFlag("--shared-adapter")) {
            try PeerCommand.parse(["keygen", "--above", "cswad43wmlont27jr4tyvu63i4", "--shared-adapter"], environment: home)
        }
        #expect(throws: UsageError.repeated("--shared-adapter")) {
            try PeerCommand.parse(["--shared-adapter", "--shared-adapter"], environment: home)
        }
    }

    @Test func everyRunFlagIsRead() throws {
        let options = try run([
            "run", "--adapter-address", "00:11:22:33:44:55", "--radio-profile", "ios", "--instance", "b",
            "--name", "Peer B", "--log", "off", "--rssi-floor", "-100", "--receive-mtu", "247", "--send-mtu", "512",
        ])
        #expect(options.adapterAddress == "00:11:22:33:44:55")
        #expect(options.radioProfile == "ios")
        #expect(options.stateDirectory == "/home/tester/.local/state/knit-peer/b")
        #expect(options.name == "Peer B")
        #expect(options.logLevel == nil)
        #expect(options.rssiFloor == -100)
        #expect(options.receiveMTU == 247)
        #expect(options.sendMTU == 512)
    }

    @Test func theTestSwitchesAreOffUnlessAsked() throws {
        let options = try run([])
        #expect(options.neverSighted.isEmpty)
        #expect(options.servesGattPayload)
        #expect(options.gattReads == .asProfile, "the profile's own")
        #expect(try run(["--no-gatt-reads"]).gattReads == .off)
        #expect(try run(["--gatt-reads", "--radio-profile", "android"]).gattReads == .on)
        #expect(throws: UsageError.invalid(flag: "--gatt-reads", value: "--no-gatt-reads")) {
            try run(["--gatt-reads", "--no-gatt-reads"])
        }
        #expect(options.feedWindow, "a file is clocked by its receiver's reports unless asked")
        #expect(try !run(["--feed", "pace"]).feedWindow)
        #expect(try run(["--feed", "window"]).feedWindow)
        #expect(throws: UsageError.self) { try run(["--feed", "fast"]) }
        let low = fixtureNodeId(8)
        let high = fixtureNodeId(9)
        let asked = try run(["--never-sight", "\(low.string),\(high.string)", "--no-gatt-payload", "--radio-profile", "ios"])
        #expect(asked.neverSighted == [low, high])
        #expect(!asked.servesGattPayload)
        #expect(try run(["--never-sight", low.string]).neverSighted == [low])
    }

    // MARK: stranger

    private func stranger(_ arguments: [String]) throws -> StrangerOptions {
        guard case .stranger(let options) = try PeerCommand.parse(["stranger"] + arguments, environment: home) else {
            throw UsageError.missing("stranger")
        }
        return options
    }

    @Test func aStrangerServesNoPayloadAndRotatesEveryTwentySecondsUnlessAsked() throws {
        let options = try stranger([])
        #expect(options.payload == .withheld)
        #expect(options.rotateSeconds == 20, "about every 20 s, as knit-ios #3 asks")
        #expect(options.seconds == 1800, "knit-next #154's 30-minute cell")
        #expect(options.logLevel == "info")
        #expect(options.adapterAddress == nil)
        let asked = try stranger(["--payload", "forged", "--rotate", "5", "--seconds", "60", "--adapter-address", "00:11:22:33:44:55"])
        #expect(asked.payload == .forged)
        #expect(asked.rotateSeconds == 5)
        #expect(asked.seconds == 60)
        #expect(asked.adapterAddress == "00:11:22:33:44:55")
    }

    @Test func aStrangerRefusesWhatItCannotDo() {
        #expect(throws: UsageError.invalid(flag: "--payload", value: "real")) { try stranger(["--payload", "real"]) }
        for bad in ["0", "7201", "soon"] {
            #expect(throws: UsageError.invalid(flag: "--rotate", value: bad)) { try stranger(["--rotate", bad]) }
            #expect(throws: UsageError.invalid(flag: "--seconds", value: bad)) { try stranger(["--seconds", bad]) }
        }
        #expect(throws: UsageError.unknownFlag("--radio-profile")) { try stranger(["--radio-profile", "ios"]) }
        #expect(throws: UsageError.unknownFlag("--instance")) { try stranger(["--instance", "x"]) }
    }

    /// The forged payload must name a node no phone dials: one that sorts above every real id. Ids sort as ASCII text,
    /// so the top is not the `0xFF…` bytes.
    @Test func theForgedNodeSortsAboveEveryId() throws {
        let forged = try #require(NodeId(StrangerOptions.forgedNodeText), "canonical")
        #expect(NodeId(bytes: forged.bytes) == forged)
        let allOnes = try #require(NodeId(bytes: Array(repeating: 0xFF, count: NodeId.byteCount)))
        #expect(allOnes < forged, "0xFF… spells 777…")
        for seed in 0..<256 {
            #expect(fixtureNodeId(seed) < forged)
        }
        let below = try #require(NodeId("zzzzzzzzzzzzzzzzzzzzzzzzzu"))
        #expect(below < forged, "the last character can rise no higher than y")
        #expect(NodeId("zzzzzzzzzzzzzzzzzzzzzzzzzz") == nil, "z is not canonical there")
    }

    @Test func aNodeNeverSightedMustBeANodeId() {
        for bad in ["phone", "\(fixtureNodeId(8).string),", ",", "\(fixtureNodeId(8).string),x"] {
            #expect(throws: UsageError.invalid(flag: "--never-sight", value: bad)) {
                try PeerCommand.parse(["--never-sight", bad], environment: home)
            }
        }
        #expect(throws: UsageError.unknownFlag("--no-gatt-payload")) {
            try PeerCommand.parse(["scan", "--no-gatt-payload"], environment: home)
        }
    }

    @Test func anMTUMustFitAnLEChannel() {
        for flag in ["--receive-mtu", "--send-mtu"] {
            for bad in ["22", "65536", "big"] {
                #expect(throws: UsageError.invalid(flag: flag, value: bad)) {
                    try PeerCommand.parse([flag, bad], environment: home)
                }
            }
        }
    }

    @Test func aFloorMustBeAReading() {
        for bad in ["loud", "5", "-128", "-90.5"] {
            #expect(throws: UsageError.invalid(flag: "--rssi-floor", value: bad)) {
                try PeerCommand.parse(["--rssi-floor", bad], environment: home)
            }
        }
    }

    @Test func theStateDirectoryFollowsXDGOrAnExplicitPath() throws {
        #expect(try run([], environment: ["XDG_STATE_HOME": "/state", "HOME": "/h"]).stateDirectory == "/state/knit-peer/default")
        #expect(
            try run([], environment: ["XDG_STATE_HOME": "relative", "HOME": "/h"]).stateDirectory == "/h/.local/state/knit-peer/default")
        #expect(try run(["--state", "/tmp/peer"]).stateDirectory == "/tmp/peer")
        #expect(throws: UsageError.missing("HOME, or --state")) { try run([], environment: [:]) }
        #expect(throws: UsageError.invalid(flag: "--instance", value: "cannot go with --state")) {
            try run(["--state", "/tmp/x", "--instance", "a"])
        }
        for bad in ["", "a/b", ".", ".."] {
            #expect(throws: UsageError.invalid(flag: "--instance", value: bad)) { try run(["--instance", bad]) }
        }
    }

    @Test func badArgumentsSayWhat() {
        #expect(throws: UsageError.unknownCommand("fly")) { try PeerCommand.parse(["fly"], environment: home) }
        #expect(throws: UsageError.unknownFlag("--color")) { try PeerCommand.parse(["--color", "red"], environment: home) }
        #expect(throws: UsageError.unknownFlag("stray")) { try PeerCommand.parse(["run", "stray"], environment: home) }
        #expect(throws: UsageError.missingValue("--name")) { try PeerCommand.parse(["--name"], environment: home) }
        #expect(throws: UsageError.missingValue("--name")) { try PeerCommand.parse(["--name", "--log", "info"], environment: home) }
        #expect(throws: UsageError.repeated("--name")) { try PeerCommand.parse(["--name", "a", "--name", "b"], environment: home) }
        #expect(throws: UsageError.invalid(flag: "--radio-profile", value: "lora")) {
            try PeerCommand.parse(["--radio-profile", "lora"], environment: home)
        }
        #expect(throws: UsageError.invalid(flag: "--log", value: "loud")) { try PeerCommand.parse(["--log", "loud"], environment: home) }
    }

    @Test func keygenTakesAWindowOpenOnEitherSide() throws {
        let low = min(fixtureNodeId(8), fixtureNodeId(9))
        let high = max(fixtureNodeId(8), fixtureNodeId(9))
        guard case .keygen(let above) = try PeerCommand.parse(["keygen", "--above", low.string], environment: home) else {
            Issue.record("not keygen")
            return
        }
        #expect(above.window == KeyGen.Window(above: low))
        guard
            case .keygen(let between) = try PeerCommand.parse(
                ["keygen", "--above", low.string, "--below", high.string, "--instance", "b"],
                environment: home
            )
        else {
            Issue.record("not keygen")
            return
        }
        #expect(between.window == KeyGen.Window(above: low, below: high))
        #expect(between.stateDirectory.hasSuffix("/knit-peer/b"))
    }

    @Test func keygenRefusesAnEmptyOrMalformedWindow() {
        let low = min(fixtureNodeId(8), fixtureNodeId(9))
        let high = max(fixtureNodeId(8), fixtureNodeId(9))
        #expect(throws: UsageError.missing("--above, --below or both")) { try PeerCommand.parse(["keygen"], environment: home) }
        #expect(throws: UsageError.invalid(flag: "--below", value: "must sort above --above")) {
            try PeerCommand.parse(["keygen", "--above", high.string, "--below", low.string], environment: home)
        }
        #expect(throws: UsageError.invalid(flag: "--above", value: "NOPE")) {
            try PeerCommand.parse(["keygen", "--above", "NOPE"], environment: home)
        }
        #expect(throws: UsageError.invalid(flag: "--below", value: "x")) {
            try PeerCommand.parse(["keygen", "--below", "x"], environment: home)
        }
        #expect(throws: UsageError.unknownFlag("--name")) {
            try PeerCommand.parse(["keygen", "--above", low.string, "--name", "x"], environment: home)
        }
    }

    @Test func scanListensQuietlyUnlessAskedToAdvertise() throws {
        guard case .scan(let quiet) = try PeerCommand.parse(["scan"], environment: home) else {
            Issue.record("not scan")
            return
        }
        #expect(quiet.seconds == 20)
        #expect(quiet.advertise == nil)
        #expect(quiet.adapterAddress == nil)
        guard
            case .scan(let loud) = try PeerCommand.parse(
                ["scan", "--seconds", "5", "--advertise", "ios", "--adapter-address", "0A:BC:DE:00:00:A1"], environment: home)
        else {
            Issue.record("not scan")
            return
        }
        #expect(loud.seconds == 5)
        #expect(loud.advertise == "ios")
        #expect(loud.adapterAddress == "0A:BC:DE:00:00:A1")
        for bad in ["0", "3601", "soon"] {
            #expect(throws: UsageError.invalid(flag: "--seconds", value: bad)) {
                try PeerCommand.parse(["scan", "--seconds", bad], environment: home)
            }
        }
    }

    @Test func helpIsHelp() throws {
        #expect(try PeerCommand.parse(["help"], environment: home) == .help)
        #expect(throws: UsageError.unknownFlag("--x")) { try PeerCommand.parse(["help", "--x", "y"], environment: home) }
        #expect(PeerCommand.usage.contains("keygen"))
    }

    @Test func optionsCanBeBuiltDirectly() {
        #expect(RunOptions(stateDirectory: "/s").stateDirectory == "/s")
    }
}
