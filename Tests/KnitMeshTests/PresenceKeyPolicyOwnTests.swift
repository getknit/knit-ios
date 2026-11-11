import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The own-key half of ``PresenceKeyPolicy`` (ADR 2026-11.prsp): `PresenceKeyPolicyTest`'s send cases ported case for case
/// (`PresenceKeyPolicyTest.kt:48-147`, `:220-258` at knit-next `cad69c77b`), every branch of `due` in the brief's order, the
/// generation arithmetic, what a linked contact is owed, the departed and who hears `TAG_NEXT`. The restore clamp is the
/// identity item's (`PrekeyRingPresenceGenerationTests`), and `linkReset` is not ported.
@Suite struct PresenceKeyPolicyOwnTests {
    private let now: Int64 = 1_793_577_600_000
    private let day = PresenceKeyPolicy.dayMilliseconds
    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)
    private let stranger = fixtureNodeId(9)

    private func key(_ seed: Int) -> PresenceKey {
        PresenceKey(bytes: (0..<32).map { UInt8(truncatingIfNeeded: $0 + seed) }) ?? .generate()
    }

    private typealias Due = PresenceKeyPolicy.Due

    private func own(_ generation: Int64, _ activatedAt: Int64?, _ audience: Set<NodeId>, markSlot: Int64? = nil) -> OwnPresenceKeyRecord {
        OwnPresenceKeyRecord(
            generation: generation,
            key: key(Int(generation)),
            mintedAt: activatedAt ?? now,
            activatedAt: activatedAt,
            audience: audience,
            mark: markSlot.map { PresenceMark(slot: $0, restart: 0) }
        )
    }

    private func due(_ rows: [OwnPresenceKeyRecord], _ direct: Set<NodeId>, at: Int64? = nil, allowed: Bool = true) -> Due {
        PresenceKeyPolicy.due(rows: rows, direct: direct, now: at ?? now, clockAdvanceAllowed: allowed)
    }

    @Test func noCurrentKeyMintsBoth() {
        #expect(due([], [alice]) == .mint)
        // A next key alone (a crash between two writes) is no current key.
        #expect(due([own(2, nil, [alice])], [alice]) == .mint)
    }

    @Test func anAudienceThatHoldsSomeoneWhoLeftIsFreshWhateverElseIsDue() {
        let current = own(1, now - 2 * day, [alice, bob])
        let next = own(2, nil, [alice, bob])
        #expect(due([current, next], [alice]) == .fresh)
        // Only the next key's audience shrank: still fresh.
        #expect(due([own(1, now - 2 * day, [alice]), next], [alice]) == .fresh)
        // Ahead of the weekly turnover and of the clock rule, and never rate-limited.
        #expect(due([own(1, now - 8 * day, [alice, bob]), next], [alice], allowed: false) == .fresh)
    }

    @Test func aWeekAdvancesAndADayLessDoesNot() {
        let next = own(2, nil, [alice])
        #expect(due([own(1, now - PresenceKeyPolicy.weekMilliseconds, [alice]), next], [alice]) == .advance(.weekly))
        #expect(due([own(1, now - PresenceKeyPolicy.weekMilliseconds + 1, [alice]), next], [alice]) == .nothing)
    }

    @Test func aCorrectedClockAdvancesOnceThenIsQuiet() {
        // Activated while the clock ran two days ahead; the clock is now corrected.
        let rows = [own(1, now + 2 * day, [alice]), own(2, nil, [alice])]
        #expect(due(rows, [alice]) == .advance(.clock))
        // Inside the daily floor the clock rule is skipped: nothing else is due.
        #expect(due(rows, [alice], allowed: false) == .nothing)
        // The advance stamps the corrected clock: the next key is current, then a next key is minted, then nothing.
        let advanced = [own(1, now + 2 * day, [alice]), own(2, now, [alice])]
        #expect(due(advanced, [alice]) == .mintNext)
        #expect(due(advanced + [own(3, nil, [alice])], [alice]) == .nothing)
        // A minute of correction is inside the slack and never rotates.
        #expect(due([own(1, now + 60_000, [alice]), own(2, nil, [alice])], [alice]) == .nothing)
    }

    @Test func aStaleAdvertiserMarkAdvancesUnderTheSameDailyFloor() {
        let slot = BlindTag.slotOf(wallMilliseconds: now)
        let atEdge = [own(1, now - day, [alice], markSlot: slot + BlindTag.windowAheadSlots), own(2, nil, [alice])]
        #expect(due(atEdge, [alice]) == .nothing)
        let stale = [own(1, now - day, [alice], markSlot: slot + BlindTag.windowAheadSlots + 1), own(2, nil, [alice])]
        #expect(due(stale, [alice]) == .advance(.mark))
        #expect(due(stale, [alice], allowed: false) == .nothing)
    }

    @Test func noNextKeyMintsOne() {
        #expect(due([own(1, now, [alice])], [alice]) == .mintNext)
    }

    @Test func aNewContactGrowsIntoTheNextKeyAndIntoTheCurrentOnlyWithinADayOfItsActivation() {
        let young = [own(1, now - day + 1, [alice]), own(2, nil, [alice])]
        #expect(due(young, [alice, bob]) == .grow(toNext: [bob], toCurrent: [bob]))
        // Aired for a day: a contact accepted now never gets the key whose tags went out before it (security N3).
        let aired = [own(1, now - day, [alice]), own(2, nil, [alice])]
        #expect(due(aired, [alice, bob]) == .grow(toNext: [bob], toCurrent: []))
        // A clock set back far past the activation is no young key either.
        let behind = [own(1, now + 2 * day, [alice]), own(2, nil, [alice])]
        #expect(due(behind, [alice, bob], allowed: false) == .grow(toNext: [bob], toCurrent: []))
        // Already in next: nothing to grow, whatever the current key's audience says.
        #expect(due([own(1, now - 3 * day, [alice]), own(2, nil, [alice, bob])], [alice, bob]) == .nothing)
    }

    @Test func aGenerationIsTheLargerOfTheNextNumberAndTheClockAndNeverOverflows() {
        #expect(PresenceKeyPolicy.nextGeneration(last: 0, now: now) == now)
        #expect(PresenceKeyPolicy.nextGeneration(last: now + 5, now: now) == now + 6)
        #expect(PresenceKeyPolicy.nextGeneration(last: 0, now: -5) == 1)
        #expect(PresenceKeyPolicy.nextGeneration(last: .max, now: now) == nil)
    }

    @Test func aPeerIsOwedOnlyTheKeysWhoseAudienceHoldsIt() {
        let keys = PresenceKeyPolicy.keysOf([own(1, now - 3 * day, [alice]), own(2, now - day, [alice]), own(3, nil, [alice, bob])])
        #expect(PresenceKeyPolicy.owed(alice, keys: keys).map(\.generation) == [2, 3])
        #expect(PresenceKeyPolicy.owed(bob, keys: keys).map(\.generation) == [3], "joined after the current key aired: next only")
        #expect(PresenceKeyPolicy.owed(stranger, keys: keys).isEmpty)
        #expect(keys.previous?.generation == 1, "the previous key is never owed")
    }

    /// Of two keys never activated, a crash between two writes' leftover, the newer is the next one (`keysOf`'s `maxByOrNull`).
    @Test func theNewestUnactivatedKeyIsTheNextOne() {
        let keys = PresenceKeyPolicy.keysOf([own(3, nil, [alice]), own(1, now, [alice]), own(4, nil, [alice]), own(2, nil, [alice])])
        #expect(keys.next?.generation == 4 && keys.current?.generation == 1 && keys.previous == nil)
    }

    @Test func theDepartedAreThoseAKeptKeyNamesWhoAreNoLongerDirectContacts() {
        let previous = own(1, now - day, [alice, bob, carol])
        let current = own(2, now, [alice, carol])
        let next = own(3, nil, [alice, carol])
        #expect(PresenceKeyPolicy.departed(rows: [previous, current, next], direct: [alice, carol]) == [bob])
        #expect(
            PresenceKeyPolicy.departed(rows: [previous, current, next], direct: [alice, bob, carol]).isEmpty, "bob is a contact again")
        var promoted = next
        promoted.activatedAt = now + 7 * day
        let advanced = [current, promoted, own(4, nil, [alice, carol])]
        #expect(PresenceKeyPolicy.departed(rows: advanced, direct: [alice, carol]).isEmpty, "the generation bob left under went")
        #expect(PresenceKeyPolicy.departed(rows: [], direct: [alice]).isEmpty)
    }

    @Test func tagNextGoesToNoOneBlockedOrDepartedAndToNoOneBeforeBothAreRead() {
        let mallory = fixtureNodeId(7)
        #expect(PresenceKeyPolicy.hearsTagNext(stranger, blocked: [mallory], departed: [bob]), "a stranger still hears it")
        #expect(!PresenceKeyPolicy.hearsTagNext(mallory, blocked: [mallory], departed: [bob]), "blocked")
        #expect(!PresenceKeyPolicy.hearsTagNext(bob, blocked: [mallory], departed: [bob]), "departed")
        #expect(!PresenceKeyPolicy.hearsTagNext(stranger, blocked: nil, departed: []), "the block list not read yet")
        #expect(!PresenceKeyPolicy.hearsTagNext(stranger, blocked: [], departed: nil), "the first pass not run yet")
    }

    /// Nothing an own key row prints shows its key or its audience (knit-next ADR 2026-11.xp6d, "Logging").
    @Test func anOwnKeyPrintsItsGenerationRoleAndAudienceSizeOnly() {
        let row = own(42, now, [alice, bob])
        let published = OwnPresenceKey(generation: 42, key: row.key)
        let printed = "\(row) \(published) \(String(reflecting: published)) \([published])"
        #expect(printed.contains("g=42") && printed.contains("audience=2"))
        #expect(!printed.contains(alice.string) && !printed.contains(", 43, 44"), "\(printed)")
    }
}
