import Foundation
import KnitWire
import Testing

@testable import KnitAppCore

// Addresses the store cannot give, and each row's words, apart from the suite's body only to keep it inside the lint's length.
extension InternetRelaysTests {
    // MARK: Addresses the store cannot give

    @Test func aReadThatFailsLeavesTheRelayListedAndUndialledUntilTheFront() async throws {
        let target = RecordingTarget()
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.add(Self.privateURL)
        try first.turnOn()

        secrets.failures = [.reads]
        let rig = RelayRig(target: target, preferences: preferences, secrets: secrets)
        rig.relays.load()
        await rig.flush()
        let row = try #require(rig.relays.rows.last)
        #expect(row.status == .unreadable && row.host == nil && row.isPrivate)
        #expect(row.title == Copy.Relays.numbered(2))
        #expect(row.accessibilityLabel == "Relay 2, Access key in link, Can't read this relay right now")
        #expect(target.carried == [1], "the house relay goes, the unreadable one waits")
        rig.relays.becameActive()
        await rig.flush()
        #expect(target.carried == [1], "still unreadable")
        secrets.failures = []
        rig.relays.becameActive()
        await rig.flush()
        #expect(target.carried == [1, 2])
        #expect(target.calls.contains(.add(2, Self.privateURL)), "the address leaves the store only as what the factory took")
    }

    @Test func aMissingItemAsksForItsInviteAndARefusedTextIsKeptUnused() async throws {
        var book = RelayBook()
        book.seeded = true
        book.nextHandle = 4
        book.entries = [RelayEntry(handle: 2, seeded: false, isPrivate: true), RelayEntry(handle: 3, seeded: false, isPrivate: false)]
        let preferences = MemoryPreferences()
        preferences.keep(book)
        // A cleartext address, which no build's factory takes from the list.
        let secrets = MemoryRelaySecrets([3: "ws://127.0.0.1:9470/spool/v1"])
        let target = RecordingTarget()
        let rig = RelayRig(target: target, preferences: preferences, secrets: secrets)
        rig.relays.load()
        try rig.turnOn()
        await rig.flush()
        #expect(rig.relays.rows.map(\.status) == [.missing, .unusable])
        #expect(target.carried.isEmpty)
        #expect(secrets.items[3] != nil, "kept")
        rig.relays.remove(2)
        rig.relays.remove(3)
        #expect(rig.relays.rows.isEmpty && secrets.items.isEmpty, "remove works in both cases")
    }

    /// The list's bytes have their keys sorted, so a re-save of a list that did not change writes the same bytes.
    @Test func aKeptListIsWrittenWithItsKeysSorted() throws {
        var book = RelayBook()
        book.entries = [RelayEntry(handle: 2, seeded: false, isPrivate: true, parked: true)]
        book.nextHandle = 3
        book.seeded = true
        book.switchOn = true
        book.consent = RelayConsent(version: 1, nonce: "ab")
        book.pendingDeletes = [1]
        let bytes = try #require(book.encoded)
        let sorted =
            #"{"consent":{"nonce":"ab","version":1},"#
            + #""entries":[{"handle":2,"is_private":true,"parked":true,"seeded":false}],"#
            + #""next_handle":3,"pending_deletes":[1],"seeded":true,"switch_on":true}"#
        #expect(String(bytes: bytes, encoding: .utf8) == sorted)
        #expect(RelayBook.read(bytes) == .stored(book))
        #expect(book.encoded == bytes, "the same list, the same bytes")
    }

    @Test func aWriteThatFailsKeepsNothingAndSpendsTheHandle() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        rig.secrets.failures = [.writes]
        try rig.add(Self.privateURL)
        #expect(rig.relays.notice == .notSaved && rig.relays.rows.count == 1)
        #expect(rig.preferences.keptBook?.pendingDeletes == [2])
        rig.secrets.failures = []
        try rig.add(Self.privateURL)
        #expect(rig.relays.rows.map(\.handle) == [1, 3])
    }

    // MARK: Status

    @Test func eachRowSaysWhereItsRelayStands() async throws {
        let target = RecordingTarget()
        let rig = RelayRig(target: target)
        rig.relays.load()
        try rig.add(Self.privateURL)
        try rig.add(Self.tokenURL)
        try rig.add(Self.pathURL)
        #expect(rig.relays.rows.map(\.status) == [.off, .off, .off, .off])
        try rig.turnOn()
        #expect(rig.relays.rows.first?.status == .connecting, "before the mesh has said anything")
        target.status = RelayMeshStatus(paused: true, relays: [:])
        await rig.relays.refreshStatus()
        #expect(rig.relays.rows.first?.status == .paused)
        target.status = RelayMeshStatus(
            paused: false,
            relays: [1: .init(state: "open", failures: 0), 2: .init(state: "dialing", failures: 0), 3: .init(state: "idle", failures: 2)]
        )
        await rig.relays.refreshStatus()
        #expect(rig.relays.rows.map(\.status) == [.connected, .connecting, .waiting, .connecting])
        let label = try #require(rig.relays.rows.dropFirst().first).accessibilityLabel
        #expect(label == "lab.relay.example:8443, Not run by Knit, Access key in link, Connecting…")
        #expect(rig.relays.rows.first?.accessibilityLabel == "public-1.spool.getknit.app, Knit's relay, Connected")
        #expect(rig.relays.rows.dropFirst().first?.details == "Not run by Knit · Access key in link · Connecting…")
        #expect(rig.relays.rows.dropFirst().first?.host?.marks == "Not run by Knit, Access key in link")
        #expect(rig.relays.rows.first?.host?.marks == "Knit's relay")
    }

    @Test func everyStatusHasItsWordsAndEverySheetSaysWhatItAsks() throws {
        let words = RelayStatus.allCases.map(\.words)
        #expect(Set(words).count == RelayStatus.allCases.count && words.allSatisfy { !$0.isEmpty })
        let url = try #require(AcceptedSpoolURL(SpoolURL.house, allowCleartext: false))
        #expect(RelaySheet(id: 1, kind: .turnOn([])).isTurnOn && !RelaySheet(id: 2, kind: .add(url)).isTurnOn)
    }

    /// Every control is named by the relay's handle, never its host, and every refusal has words of its own.
    @Test func controlsAreNamedByHandleAndEveryNoticeHasItsWords() {
        #expect(AccessibilityID.relayRow(3) == "relay_row_3")
        #expect(AccessibilityID.relayPark(3) == "relay_park_3")
        #expect(AccessibilityID.relayRemove(3) == "relay_remove_3")
        let ids = [
            AccessibilityID.settingsInternetRelays, AccessibilityID.relaysPaste, AccessibilityID.relaysConsent,
            AccessibilityID.relaysConsentAccept, AccessibilityID.relaysConsentDecline,
        ]
        #expect(Set(ids).count == ids.count && ids.allSatisfy { !$0.contains(".") })
        let notices: [RelayNotice] = [
            .refused(.notAnInvite), .refused(.unusableRelay), .duplicate, .full, .unavailable, .notSaved, .consentNotSaved,
        ]
        #expect(Set(notices.map(\.id)).count == notices.count)
        #expect(notices.allSatisfy { !$0.message.isEmpty })
    }
}
