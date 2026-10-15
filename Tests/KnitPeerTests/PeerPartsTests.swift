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

    @Test func aNewIdentityStartsItsProfileClocksOverButKeepsTheNameAndPhoto() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        let photo = BlobHash(of: Array("a photo".utf8))
        state.profileStore().save(OwnProfile(name: "Peer", status: "x", openToChat: true, version: 9, publishedAt: 9, avatarHash: photo))
        try state.replaceIdentity(with: identity(5))
        #expect(try state.loadIdentity().keys.nodeId == identity(5).nodeId)
        #expect(state.profileStore().load() == OwnProfile(name: "Peer", avatarHash: photo), "the name and the photo stay")
    }

    @Test func thePrekeysLiveBesideTheIdentityAndTheProfileNamesTheOneItCarries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        let keys = try state.loadIdentity().keys
        var ring = try state.loadPrekeys(for: keys)
        #expect(ring.prekeys.isEmpty)
        try ring.rotate(now: 1)
        #expect(try state.loadPrekeys(for: keys).newest?.id == 1)
        #expect(try state.loadIdentity().keys.nodeId == keys.nodeId, "the grown file still loads the identity")
        state.profileStore().save(OwnProfile(name: "Peer", version: 5, publishedAt: 6, prekeyId: 1))
        #expect(PeerState(directory: directory).profileStore().load().prekeyId == 1)
        // A new identity starts with no prekeys, and its profile names none.
        try state.replaceIdentity(with: identity(5))
        #expect(try state.loadPrekeys(for: identity(5)).prekeys.isEmpty)
        #expect(state.profileStore().load().prekeyId == nil)
    }

    @Test func aProfileFileFromBeforePrekeysCarriesNone() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let older = #"{"name":"Peer","openToChat":false,"publishedAt":6,"status":"","version":5}"#
        try Data(older.utf8).write(to: URL(fileURLWithPath: directory + "/profile.json"))
        #expect(PeerState(directory: directory).profileStore().load() == OwnProfile(name: "Peer", version: 5, publishedAt: 6))
    }

    @Test func anUnreadableProfileIsAFreshOne() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: directory + "/profile.json"))
        let store = PeerState(directory: directory).profileStore()
        #expect(store.load() == OwnProfile())
        #expect(store.loadIfReadable() == OwnProfile(), "read once, as a fresh profile by design, so never unreadable later")
    }

    @Test func aUnitThatIsUndonePutsTheProfileAndItsFileBack() throws {
        // knit-peer's profile file joins the memory stores' unit (ADR 2026-10.5sk9).
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = PeerState(directory: directory).profileStore()
        let kept = OwnProfile(name: "Peer", version: 5, publishedAt: 6)
        store.save(kept)
        let checkpoint = store.checkpoint()
        store.save(OwnProfile(name: "Undone", version: 7, publishedAt: 8))
        checkpoint.restore()
        #expect(store.load() == kept)
        #expect(PeerState(directory: directory).profileStore().load() == kept, "the file holds it again")
        try FileManager.default.removeItem(atPath: directory + "/profile.json")
        checkpoint.restore()
        #expect(!FileManager.default.fileExists(atPath: directory + "/profile.json"), "a unit that left the profile alone writes nothing")
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
