import Foundation
import KnitWire
import Testing

@testable import KnitAppCore
@testable import KnitMesh

/// The relay settings (ADR 2026-11.adrq, P6): the gate, the list and what is kept where, the switch and park, the consent
/// sheets, and invites, over a mesh stand-in that records what it was told.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct InternetRelaysTests {
    static let privateURL = "wss://lab.relay.example:8443/spool/v1?K=0123456789abcdef"
    static let tokenURL = "wss://other.relay.example/spool/v1?token=fedcba9876543210"
    static let pathURL = "wss://path.relay.example/spool/v1/members-only"

    // MARK: The gate

    @Test func theGateNeedsADebugBuildTheSwitchAndThisIdentitysConsent() async throws {
        let target = RecordingTarget()
        let preferences = MemoryPreferences()
        let rig = RelayRig(target: target, preferences: preferences)
        rig.relays.load()
        #expect(!rig.relays.spoolEnabled, "off until the person turns it on")
        try rig.turnOn()
        #expect(rig.relays.spoolEnabled)
        await rig.flush()
        #expect(target.calls == [.add(1, SpoolURL.house)], "the gate opens after the additions")

        // The same list in a build that is not a debug one: the gate stays shut, and nothing reaches the mesh.
        let release = RecordingTarget()
        let shut = RelayRig(target: release, preferences: preferences, debugBuild: false)
        shut.relays.load()
        #expect(!shut.relays.spoolEnabled)
        await shut.flush()
        #expect(release.carried.isEmpty)
    }

    /// A kept book reads back whole, and one missing every field reads as an empty one: a book that failed to read would
    /// seed afresh and sweep every relay's item.
    @Test func aKeptBookReadsBackAndMissingFieldsReadEmpty() throws {
        var book = RelayBook()
        book.entries = [
            RelayEntry(handle: 1, seeded: true, isPrivate: false), RelayEntry(handle: 4, seeded: false, isPrivate: true, parked: true),
        ]
        book.nextHandle = 5
        book.seeded = true
        book.switchOn = true
        book.consent = RelayConsent(version: 1, nonce: "n")
        book.pendingDeletes = [2]
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RelayBook.self, from: try JSONEncoder().encode(book)) == book)
        #expect(try decoder.decode(RelayBook.self, from: Data("{}".utf8)) == RelayBook())
        #expect(try decoder.decode(RelayBook.self, from: Data(#"{"seeded":true,"later":7}"#.utf8)).seeded)
    }

    // MARK: The list

    @Test func theHouseRelayIsSeededOnceAndARemovedOneStaysRemoved() throws {
        let preferences = MemoryPreferences()
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences)
        rig.relays.load()
        rig.relays.load()
        let row = try #require(rig.relays.rows.first)
        #expect(rig.relays.rows.count == 1)
        #expect(row.host?.host == "public-1.spool.getknit.app" && row.host?.isKnits == true && !row.isPrivate)
        #expect(rig.secrets.items.isEmpty, "the house relay's address is the constant, never an item")
        rig.relays.remove(row.handle)
        let again = RelayRig(target: RecordingTarget(), preferences: preferences)
        again.relays.load()
        #expect(again.relays.rows.isEmpty, "removed stays removed")
    }

    @Test func aFreshInstallSweepsEveryItemBeforeItSeeds() {
        let secrets = MemoryRelaySecrets([2: Self.privateURL, 9: Self.tokenURL])
        let rig = RelayRig(target: RecordingTarget(), secrets: secrets)
        rig.relays.load()
        #expect(secrets.items.isEmpty)
        #expect(rig.relays.rows.map(\.handle) == [1])
    }

    @Test func aSweepThatFailsSeedsNothingAndIsTriedAgainAtTheFront() {
        let secrets = MemoryRelaySecrets([2: Self.privateURL])
        secrets.failures = [.deletes]
        let preferences = MemoryPreferences()
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        #expect(!rig.relays.isLoaded && rig.relays.rows.isEmpty && preferences.relayBookData == nil, "nothing written")
        rig.relays.offer(opened: RelayRig.invite(Self.privateURL))
        #expect(rig.relays.notice == .unavailable && rig.relays.sheet == nil)
        rig.relays.setSwitch(true)
        #expect(rig.relays.sheet == nil, "no switch before the list is read")
        secrets.failures = []
        rig.relays.becameActive()
        #expect(rig.relays.isLoaded && secrets.items.isEmpty && rig.relays.rows.count == 1)
    }

    @Test func handlesAreStableAndNeverReused() throws {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        try rig.add(Self.privateURL)
        try rig.add(Self.tokenURL)
        rig.relays.remove(2)
        try rig.add(Self.pathURL)
        #expect(rig.relays.rows.map(\.handle) == [1, 3, 4])
        let again = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        again.relays.load()
        #expect(again.relays.rows.map(\.handle) == [1, 3, 4])
        #expect(again.relays.rows.map(\.title) == ["public-1.spool.getknit.app", "other.relay.example", "path.relay.example"])
    }

    /// No relay's address, its token, path or host, is ever in the preferences: only handles and flags are.
    @Test func noRelayAddressIsKeptInThePreferences() throws {
        let preferences = MemoryPreferences()
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences)
        rig.relays.load()
        for url in [Self.privateURL, Self.tokenURL, Self.pathURL] {
            try rig.add(url)
        }
        let bytes = try #require(preferences.relayBookData)
        let kept = try #require(String(bytes: bytes, encoding: .utf8))
        for part in ["relay.example", "0123456789abcdef", "fedcba9876543210", "members-only", "spool/v1", "wss", "getknit"] {
            #expect(!kept.contains(part), "the preferences hold \(part)")
        }
        #expect(rig.secrets.items.values.sorted() == [Self.privateURL, Self.tokenURL, Self.pathURL].sorted(), "each in its own item")
        #expect(rig.relays.rows.map(\.isPrivate) == [false, true, false, false], "a k= in either case is the private mark")
    }

    @Test func removingARelayDeletesItsItemAndAFailedDeleteIsTriedAgainAtTheFront() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        try rig.add(Self.privateURL)
        try rig.add(Self.tokenURL)
        rig.relays.remove(2)
        #expect(rig.secrets.items[2] == nil)
        rig.secrets.failures = [.deletes]
        rig.relays.remove(3)
        #expect(rig.preferences.keptBook?.pendingDeletes == [3] && rig.secrets.items[3] != nil)
        rig.relays.becameActive()
        #expect(rig.preferences.keptBook?.pendingDeletes == [3], "still owed while deletes fail")
        rig.secrets.failures = []
        rig.relays.becameActive()
        #expect(rig.preferences.keptBook?.pendingDeletes.isEmpty == true && rig.secrets.items.isEmpty)
        rig.relays.remove(99)
        rig.relays.setParked(99, true)
        #expect(rig.relays.rows.map(\.handle) == [1], "an unknown handle changes nothing")
    }

    @Test func theListHoldsAsManyRelaysAsTheMeshCarries() throws {
        #expect(RelayBook.maxRelays == SpoolPlane.maxRelays)
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        for index in 1..<RelayBook.maxRelays {
            try rig.add("wss://relay\(index).example/spool/v1")
        }
        #expect(rig.relays.rows.count == RelayBook.maxRelays)
        rig.relays.offer(pasted: RelayRig.invite("wss://one-more.example/spool/v1"))
        #expect(rig.relays.notice == .full && rig.relays.sheet == nil)
        #expect(rig.relays.notice?.message.contains("\(RelayBook.maxRelays)") == true)
    }

    // MARK: The switch and park

    @Test func turningTheSwitchOffRemovesEveryRelayAndOnAddsTheUnparkedOnesBack() async throws {
        let target = RecordingTarget()
        let rig = RelayRig(target: target)
        rig.relays.load()
        try rig.add(Self.privateURL)
        try rig.add(Self.tokenURL)
        await rig.flush()
        #expect(target.calls.isEmpty, "nothing reaches the mesh with the switch off")
        try rig.turnOn()
        await rig.flush()
        #expect(target.carried == [1, 2, 3])
        rig.relays.setParked(2, true)
        await rig.flush()
        #expect(target.carried == [1, 3] && rig.relays.rows.first { $0.handle == 2 }?.status == .parked)
        rig.relays.setSwitch(false)
        await rig.flush()
        #expect(target.carried.isEmpty && rig.relays.rows.count == 3, "off drops every relay from the mesh and keeps the list")
        #expect(rig.relays.rows.allSatisfy { $0.status == .off || $0.status == .parked })
        try rig.turnOn()
        await rig.flush()
        #expect(target.carried == [1, 3], "on adds back the unparked ones")
        rig.relays.setParked(2, false)
        await rig.flush()
        #expect(target.carried == [1, 3, 2])
        rig.relays.setSwitch(true)
        #expect(rig.relays.sheet == nil, "a switch already on asks nothing")
    }

    @Test func aSheetDeclinedChangesNothing() async throws {
        let target = RecordingTarget()
        let rig = RelayRig(target: target)
        rig.relays.load()
        rig.relays.setSwitch(true)
        let sheet = try #require(rig.relays.sheet)
        rig.relays.dismiss(sheet)
        await rig.flush()
        #expect(rig.relays.sheet == nil && !rig.relays.spoolEnabled && target.calls.isEmpty)
    }
}
