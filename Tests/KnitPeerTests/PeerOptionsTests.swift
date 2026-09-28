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

    @Test func runIsTheDefaultOnHci1WithTheRadiosOwnProfile() throws {
        let options = try run([])
        #expect(options.adapter == "hci1")
        #expect(options.adapterAddress == "0A:BC:DE:00:00:A1")
        #expect(options.radioProfile == nil, "the radio's own")
        #expect(options.stateDirectory == "/home/tester/.local/state/knit-peer/default")
        #expect(options.name == nil)
        #expect(options.logLevel == "info")
        #expect(options.rssiFloor == nil, "Android's floor unless asked")
        #expect(!options.sharedAdapter)
        #expect(try run(["run"]) == options)
    }

    @Test func aSharedAdapterIsASwitchForRunAndScanOnly() throws {
        let options = try run(["--adapter", "hci0", "--shared-adapter", "--adapter-address", "A0:00:00:00:00:01"])
        #expect(options.sharedAdapter)
        #expect(options.adapter == "hci0")
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
            "run", "--adapter", "hci2", "--adapter-address", "00:11:22:33:44:55", "--radio-profile", "ios", "--instance", "b",
            "--name", "Peer B", "--log", "off", "--rssi-floor", "-100", "--receive-mtu", "247", "--send-mtu", "512",
        ])
        #expect(options.adapter == "hci2")
        #expect(options.adapterAddress == "00:11:22:33:44:55")
        #expect(options.radioProfile == "ios")
        #expect(options.stateDirectory == "/home/tester/.local/state/knit-peer/b")
        #expect(options.name == "Peer B")
        #expect(options.logLevel == nil)
        #expect(options.rssiFloor == -100)
        #expect(options.receiveMTU == 247)
        #expect(options.sendMTU == 512)
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
        #expect(quiet.adapter == "hci1")
        guard
            case .scan(let loud) = try PeerCommand.parse(
                ["scan", "--seconds", "5", "--advertise", "ios", "--adapter", "hci3"], environment: home)
        else {
            Issue.record("not scan")
            return
        }
        #expect(loud.seconds == 5)
        #expect(loud.advertise == "ios")
        #expect(loud.adapter == "hci3")
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
