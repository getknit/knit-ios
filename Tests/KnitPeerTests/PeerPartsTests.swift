import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Synchronization
import Testing

/// The control lines, the JSON they come back as, the state directory, the log and the scan report.
@Suite struct PeerPartsTests {
    // MARK: Control lines

    @Test func everyCommandParses() throws {
        let peer = fixtureNodeId(4)
        let cases: [(String, ControlCommand)] = [
            (#"{"cmd":"status"}"#, .status),
            (#"{"cmd":"peers"}"#, .peers),
            (#"{"cmd":"links"}"#, .links),
            (#"{"cmd":"digest"}"#, .digest),
            (#"{"cmd":"quit"}"#, .quit),
            (#"{"cmd":"room","text":"hi"}"#, .room("hi")),
            (#"{"cmd":"dm","to":"\#(peer)","text":"psst"}"#, .directMessage(to: peer, text: "psst")),
            (#"{"cmd":"accept","conv":"\#(peer)"}"#, .accept(peer.string)),
            (#"{"cmd":"accept","peer":"\#(peer)"}"#, .accept(peer.string)),
            (#"{"cmd":"name","name":"B"}"#, .name("B", status: nil, openToChat: nil)),
            (#"{"cmd":"name","status":"s","openToChat":true}"#, .name(nil, status: "s", openToChat: true)),
            (#"{"cmd":"deny-link","peer":"\#(peer)"}"#, .denyLink(peer)),
            (#"{"cmd":"allow-link","peer":"\#(peer)"}"#, .allowLink(peer)),
            (#"{"cmd":"messages","conv":"nearby"}"#, .messages("nearby", limit: 20)),
            (#"{"cmd":"messages","conv":"nearby","limit":0}"#, .messages("nearby", limit: 1)),
        ]
        for (line, command) in cases {
            #expect(try ControlRequest.parse(line).get() == ControlRequest(command: command, tag: nil), "\(line)")
        }
        #expect(try ControlRequest.parse(#"{"cmd":"status","tag":"t1"}"#).get().tag == "t1")
    }

    @Test func badLinesSayWhy() {
        let cases: [(String, ControlError)] = [
            ("not json", .notJSON),
            (#"{"text":"no cmd"}"#, .notJSON),
            (#"{"cmd":"fly"}"#, .unknownCommand("fly")),
            (#"{"cmd":"room"}"#, .missing("text")),
            (#"{"cmd":"dm","text":"x"}"#, .missing("to")),
            (#"{"cmd":"dm","to":"NOPE","text":"x"}"#, .invalidNodeId("NOPE")),
            (#"{"cmd":"accept"}"#, .missing("conv")),
            (#"{"cmd":"deny-link"}"#, .missing("peer")),
            (#"{"cmd":"messages"}"#, .missing("conv")),
        ]
        for (line, error) in cases {
            #expect(throws: error) { try ControlRequest.parse(line).get() }
        }
        #expect(ControlError.refused("because").message == "because")
        #expect(ControlError.notJSON.message.contains("JSON"))
        #expect(ControlError.unknownCommand("fly").message == "unknown command fly")
        #expect(ControlError.missing("text").message == "missing text")
        #expect(ControlError.invalidNodeId("x").message == "not a node id: x")
    }

    @Test func everyCommandHasTheNameItWasSentAs() {
        let peer = fixtureNodeId(4)
        let names = [
            ControlCommand.status, .peers, .links, .room(""), .directMessage(to: peer, text: ""), .accept(""),
            .name(nil, status: nil, openToChat: nil),
            .denyLink(peer), .allowLink(peer), .digest, .messages("", limit: 1), .quit,
        ]
        .map(\.name)
        #expect(
            names == ["status", "peers", "links", "room", "dm", "accept", "name", "deny-link", "allow-link", "digest", "messages", "quit"])
    }

    // MARK: JSON

    @Test func aLineIsCompactWithSortedKeys() {
        let value: JSONValue = ["b": 1, "a": ["x", true, .null], "c": ["n": -2], "path": "/org/bluez"]
        #expect(value.line == #"{"a":["x",true,null],"b":1,"c":{"n":-2},"path":"/org/bluez"}"#)
        #expect(JSONValue.text(nil) == .null)
        #expect(JSONValue.text("x") == .string("x"))
    }

    // MARK: State

    private func temporaryDirectory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("knit-peer-\(UInt64.random(in: 0...UInt64.max))").path
    }

    @Test func anIdentityIsMadeOnceThenKept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        let made = try state.loadIdentity()
        #expect(made.origin == .created)
        let loaded = try state.loadIdentity()
        #expect(loaded.origin == .stored)
        #expect(loaded.keys.nodeId == made.keys.nodeId)
        let mode = try FileManager.default.attributesOfItem(atPath: directory + "/identity")[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func theProfileAndItsClocksSurviveARestart() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = PeerState(directory: directory).profileStore()
        #expect(first.load() == OwnProfile())
        first.save(OwnProfile(name: "Peer", status: "here", openToChat: true, version: 5, publishedAt: 6))
        #expect(first.lastError == nil)
        let again = PeerState(directory: directory).profileStore().load()
        #expect(again == OwnProfile(name: "Peer", status: "here", openToChat: true, version: 5, publishedAt: 6))
    }

    @Test func aNewIdentityStartsItsProfileClocksOverButKeepsTheName() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        state.profileStore().save(OwnProfile(name: "Peer", status: "x", openToChat: true, version: 9, publishedAt: 9))
        try state.replaceIdentity(with: identity(5))
        #expect(try state.loadIdentity().keys.nodeId == identity(5).nodeId)
        #expect(state.profileStore().load() == OwnProfile(name: "Peer"))
    }

    @Test func anUnreadableProfileIsAFreshOne() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: directory + "/profile.json"))
        #expect(PeerState(directory: directory).profileStore().load() == OwnProfile())
    }

    @Test func aProfileThatCannotBeWrittenSaysWhy() {
        let store = FileOwnProfileStore(path: "/proc/knit-peer/profile.json")
        store.save(OwnProfile(name: "x"))
        #expect(store.load().name == "x", "kept in memory all the same")
        #expect(store.lastError?.contains("cannot write") == true)
    }

    // MARK: The log

    @Test func theLogKeepsItsThresholdAndUp() {
        let lines = LineCollector()
        let log = JSONLinesLog(threshold: .info, write: lines.write)
        log.log(.debug, "quiet")
        log.log(.info, "said")
        log.log(.warning, "loud")
        #expect(lines.all == [#"{"log":"info","message":"said"}"#, #"{"log":"warning","message":"loud"}"#])
        #expect(JSONLinesLog.level(named: "debug") == .debug)
        #expect(JSONLinesLog.level(named: "info") == .info)
        #expect(JSONLinesLog.level(named: "warning") == .warning)
        #expect(JSONLinesLog.level(named: "off") == nil)
        JSONLinesLog(threshold: .debug, write: lines.write).log(.debug, "now")
        #expect(lines.all.last == #"{"log":"debug","message":"now"}"#)
        JSONLinesLog(threshold: .debug, clock: StillClock(), write: lines.write).log(.info, "stamped")
        #expect(lines.all.last == #"{"log":"info","message":"stamped","ms":\#(StillClock.wall)}"#)
    }

    // MARK: The scan report

    @Test func aScanReportsEachNodeOnceAndSumsUpAtTheEnd() throws {
        let own = fixtureNodeId(1)
        let other = fixtureNodeId(2)
        var report = ScanReport(own: own)
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: other, digestCue: 0, psm: 0x80, flags: 1)
        let taken = report.take(RadioSighting(address: RadioAddress("/dev_a"), advert: advert, rssi: -80))
        let first = try #require(taken)
        #expect(first.contains(#""event":"sighted""#))
        #expect(first.contains(#""rssi":-80"#))
        let again = report.take(RadioSighting(address: RadioAddress("/dev_b"), advert: advert, rssi: -60))
        let weaker = report.take(RadioSighting(address: RadioAddress("/dev_b"), advert: advert, rssi: -70))
        let ours = AdvertPayload(capabilities: .local, nodeId: own, digestCue: 0, psm: 0x80)
        let ourOwn = report.take(RadioSighting(address: RadioAddress("/dev_c"), advert: ours, rssi: -30))
        #expect(again == nil)
        #expect(weaker == nil)
        #expect(ourOwn == nil)
        let summary = report.summary
        #expect(summary.contains(#""adverts":3"#))
        #expect(summary.contains(#""rssi":-60"#), "the strongest")
        #expect(summary.contains(#""address":"/dev_b""#), "the newest address")
        #expect(summary.contains(#""capabilities":"ff""#))
        #expect(!summary.contains(own.string))
    }
}
