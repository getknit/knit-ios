import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Synchronization
import Testing

/// The state directory, the log and the scan report.
@Suite struct PeerPartsTests {
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
