import Foundation
import KnitMesh
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

// What is kept, and how it reads back (ADR 2026-11.adrq, P6): a list that does not read, lists a later or earlier build
// wrote, the consent nonce, a relay listed twice, and the stream's end. Apart from the suite's body only to keep it inside
// the lint's length.
extension InternetRelaysTests {
    private static let relayURL = "wss://lab.relay.example/spool/v1?k=kept"

    /// A list kept as `json`, with relay 3's address in the store.
    private static func kept(_ json: String) -> (MemoryPreferences, MemoryRelaySecrets) {
        let preferences = MemoryPreferences()
        preferences.relayBookData = Data(json.utf8)
        return (preferences, MemoryRelaySecrets([3: relayURL]))
    }

    // MARK: A list that does not read

    @Test func aListThatDoesNotReadIsLeftAsItIsAndNothingIsSweptSeededOrDialled() async {
        let preferences = MemoryPreferences()
        let garbage = Data("not a relay list".utf8)
        preferences.relayBookData = garbage
        let secrets = MemoryRelaySecrets([2: Self.relayURL])
        secrets.consent = "nonce"
        let target = RecordingTarget()
        let rig = RelayRig(target: target, preferences: preferences, secrets: secrets)
        rig.relays.load()
        rig.relays.becameActive()
        await rig.flush()
        #expect(!rig.relays.isLoaded && rig.relays.rows.isEmpty && !rig.relays.spoolEnabled)
        #expect(preferences.relayBookData == garbage, "the kept bytes are left as they are")
        #expect(secrets.sweeps == 0 && secrets.items[2] == Self.relayURL && secrets.consent == "nonce", "nothing swept")
        #expect(target.calls.isEmpty, "nothing dialled")
        #expect(rig.log.lines.count == 1, "logged once")
        #expect(rig.log.lines.allSatisfy { !$0.contains("not a relay list") && !$0.contains("lab.relay") }, "and by kind alone")
        rig.relays.offer(opened: RelayRig.invite(Self.relayURL))
        #expect(rig.relays.notice == .unavailable && rig.relays.sheet == nil)
        #expect(RelayBook.read(Data(#"{"entries":[{"seeded":true}]}"#.utf8)) == .unreadable, "an entry with no handle names no item")
    }

    @Test func aListWithNoSeededMarkOrNextHandleKeepsEveryHandle() throws {
        let (preferences, secrets) = Self.kept(#"{"entries":[{"handle":3,"is_private":true,"parked":false}],"pending_deletes":[5]}"#)
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        #expect(secrets.sweeps == 0 && secrets.items[3] == Self.relayURL)
        #expect(rig.relays.rows.map(\.handle) == [3], "a list that holds anything was seeded: the house relay stays removed")
        try rig.add("wss://another.example/spool/v1")
        #expect(rig.relays.rows.map(\.handle) == [3, 6], "past every handle listed or owed a delete")
    }

    @Test func anEntryMissingParkedReadsUnparked() throws {
        let (preferences, secrets) = Self.kept(
            #"{"seeded":true,"next_handle":4,"entries":[{"handle":3,"seeded":false}]}"#)
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        #expect(secrets.sweeps == 0 && rig.relays.rows.map(\.parked) == [false] && rig.relays.rows.map(\.isPrivate) == [false])
        #expect(rig.relays.rows.map(\.id) == [3])
        try rig.add("wss://another.example/spool/v1")
        #expect(rig.relays.rows.map(\.handle) == [3, 4])
    }

    @Test func anEntryWithAFieldThisBuildDoesNotKnowStillReads() throws {
        let json =
            #"{"seeded":true,"next_handle":4,"later":1,"entries":"#
            + #"[{"handle":3,"seeded":false,"is_private":false,"parked":true,"later":"x"}]}"#
        let (preferences, secrets) = Self.kept(json)
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        #expect(secrets.sweeps == 0 && rig.relays.rows.map(\.parked) == [true])
        try rig.add("wss://another.example/spool/v1")
        #expect(rig.relays.rows.map(\.handle) == [3, 4])
        #expect(
            RelayBook.read(Data(#"{"seeded":true,"consent":{"v":1}}"#.utf8)) == .stored(Self.seededBook),
            "a consent that does not read is none")
    }

    private static var seededBook: RelayBook {
        var book = RelayBook()
        book.seeded = true
        return book
    }

    // MARK: The consent nonce

    @Test func aConsentHoldsWhileTheNonceItWasGivenUnderIsKept() throws {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.turnOn()
        let nonce = try #require(secrets.consent)
        #expect(nonce.count == 32 && nonce.allSatisfy(\.isHexDigit) && preferences.keptBook?.consent?.nonce == nonce)
        let one = RelayBook.freshNonce()
        let two = RelayBook.freshNonce()
        #expect(one != two)
        let again = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        again.relays.load()
        #expect(again.relays.spoolEnabled)
        let bytes = try #require(preferences.relayBookData)
        #expect(String(bytes: bytes, encoding: .utf8)?.contains(nonce) == true, "the list keeps a copy of the nonce, and no more")
    }

    @Test func aNonceThatIsGoneOrDiffersVoidsTheConsent() throws {
        for kept in [nil, "another"] as [String?] {
            let preferences = MemoryPreferences()
            let secrets = MemoryRelaySecrets()
            let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
            first.relays.load()
            try first.turnOn()
            secrets.consent = kept
            let again = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
            again.relays.load()
            #expect(!again.relays.spoolEnabled)
            #expect(preferences.keptBook?.switchOn == false && preferences.keptBook?.consent == nil, "voided where it is kept")
        }
    }

    @Test func aNonceThatDoesNotReadDialsNothingUntilItDoes() async throws {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.turnOn()
        secrets.failures = [.consent]
        let target = RecordingTarget()
        let rig = RelayRig(target: target, preferences: preferences, secrets: secrets)
        rig.relays.load()
        await rig.flush()
        #expect(!rig.relays.spoolEnabled && target.carried.isEmpty, "fails closed")
        #expect(preferences.keptBook?.switchOn == true, "and voids nothing it could not read")
        #expect(rig.log.lines.count == 1)
        rig.relays.becameActive()
        #expect(!rig.relays.spoolEnabled, "still unread")
        secrets.failures = []
        rig.relays.becameActive()
        await rig.flush()
        #expect(rig.relays.spoolEnabled && target.carried == [1])
    }

    @Test func aConsentTheStoreWillNotKeepTurnsNothingOn() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        rig.secrets.failures = [.consent]
        try rig.turnOn()
        #expect(rig.relays.notice == .consentNotSaved && !rig.relays.spoolEnabled && rig.preferences.keptBook?.switchOn == false)
    }

    /// Replacing the identity removes the nonce (the app's `liveWithRelays`), and a removal that cannot be done says so.
    @Test func theNonceCanBeRemovedAndARemovalThatFailsSaysSo() throws {
        let secrets = MemoryRelaySecrets()
        secrets.consent = "nonce"
        try secrets.deleteConsent()
        #expect(secrets.consent == nil)
        secrets.failures = [.consent]
        #expect(secrets.failures == [.consent])
        #expect(throws: RelaySecretError()) { try secrets.deleteConsent() }
    }

    /// Replacing the identity voids the consent in the kept list before it deletes the nonce: with the delete failing, the
    /// nonce item stays and still reads, and the next launch, under the new identity, turns nothing on and dials nothing.
    @Test func aReplacedIdentityLeavesNoConsentEvenWhenTheNoncesDeleteFails() async throws {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let target = RecordingTarget()
        let first = RelayRig(target: target, preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.turnOn()
        let nonce = try #require(secrets.consent)
        secrets.failures = [.consent]
        first.relays.forgetConsent()
        await first.flush()
        #expect(secrets.consent == nonce, "the delete failed and the item stays")
        #expect(preferences.keptBook?.switchOn == false && preferences.keptBook?.consent == nil, "voided where it is kept")
        #expect(!first.relays.spoolEnabled && target.carried.isEmpty, "and this process's mesh carries nothing")

        secrets.failures = []
        let sockets = CountingSockets()
        let mesh = try pausedMesh(sockets)
        let next = RelayRig(target: mesh, preferences: preferences, secrets: secrets)
        next.relays.load()
        await mesh.start()
        next.phases.send(.scene(.active))
        await next.flush()
        #expect(!next.relays.spoolEnabled && sockets.opens == 0)
        await mesh.stop()
    }

    /// A list that never read is left as it is; the nonce's item is still deleted.
    @Test func forgettingAConsentBeforeTheListReadsLeavesTheBytesAndDeletesTheNonce() {
        let preferences = MemoryPreferences()
        let garbage = Data("not a relay list".utf8)
        preferences.relayBookData = garbage
        let secrets = MemoryRelaySecrets()
        secrets.consent = "nonce"
        let rig = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        rig.relays.load()
        rig.relays.forgetConsent()
        #expect(preferences.relayBookData == garbage && secrets.consent == nil)
    }

    @Test func aFreshInstallsSweepRemovesAnEarlierNonce() {
        let secrets = MemoryRelaySecrets()
        secrets.consent = "earlier"
        let rig = RelayRig(target: RecordingTarget(), secrets: secrets)
        rig.relays.load()
        #expect(secrets.consent == nil && secrets.sweeps == 1)
    }

    // MARK: A relay listed twice

    /// A relay added again while its first copy does not read is listed twice. Once the first copy reads, it is a duplicate:
    /// shown, undialled, refused as an invite, and removable; once the dialled copy goes, it is ready again.
    @Test func aRelayAddedAgainWhileItsFirstCopyDidNotReadIsADuplicate() async throws {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.add(Self.relayURL)
        try first.turnOn()
        secrets.failures = [.reads]
        let target = RecordingTarget()
        let rig = RelayRig(target: target, preferences: preferences, secrets: secrets)
        rig.relays.load()
        try rig.add(Self.relayURL)
        secrets.failures = []
        rig.relays.becameActive()
        await rig.flush()
        #expect(rig.relays.rows.map(\.status).dropFirst().first == .duplicate)
        #expect(rig.relays.rows.first { $0.handle == 2 }?.host?.host == "lab.relay.example")
        #expect(target.carried == [1, 3], "the duplicate is never dialled")
        rig.relays.offer(opened: RelayRig.invite(Self.relayURL))
        #expect(rig.relays.notice == .duplicate)
        rig.relays.remove(3)
        await rig.flush()
        #expect(target.carried == [1, 2], "ready again once the dialled copy goes")
        rig.relays.remove(2)
        #expect(rig.relays.rows.map(\.handle) == [1] && secrets.items.isEmpty)
    }

    // MARK: The stream's end

    /// A send after the stream ended runs its `done` at once, so a background task waiting on it is never held to its expiry.
    @Test func aSendAfterTheStreamEndedRunsItsDoneAtOnce() {
        let phases = MeshPhases(target: RecordingTarget())
        phases.finish()
        let done = Lock(false)
        phases.send(.scene(.background)) { done.withLock { $0 = true } }
        #expect(done.withLock { $0 })
    }
}
