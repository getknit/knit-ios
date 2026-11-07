import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``ExpectedTagTable`` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t), ported case for case from `ExpectedTagTableTest.kt`
/// at `cad69c77b`: the window moves with the wall clock exactly as far as the clock moved, either way, and a key two
/// contacts list leaves each its own tags.
@Suite struct ExpectedTagTableTests {
    private typealias ContactKey = ExpectedTagTable.ContactKey

    private static let week: Int64 = 7 * 24 * 3_600_000
    private let now = BlindFixture.now
    private let wall = BlindFixture.wall
    private let slot = BlindTag.slotOf(wallMilliseconds: BlindFixture.wall)
    private let bob = BlindFixture.id("bob")
    private let carol = BlindFixture.id("carol")
    private let mallory = BlindFixture.id("mallory")
    private var fixture = BlindFixture()
    private let bobKey: PresenceKey
    private let carolKey: PresenceKey

    init() {
        bobKey = fixture.key()
        carolKey = fixture.key()
    }

    private func form(_ key: PresenceKey, _ atSlot: Int64, restart: Int = 0, owner: NodeId? = nil) -> NodeId {
        BlindFixture.tag(key, owner: owner ?? bob, slot: atSlot, restart: restart)
    }

    private func table() -> ExpectedTagTable {
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        table.setKeys([bob: ContactKey(current: bobKey), carol: ContactKey(current: carolKey)], now: now, wall: wall)
        return table
    }

    private static func list(_ keys: [PresenceKey]) -> ContactKey {
        required(ContactKey(keys: keys))
    }

    @Test func aMultiSlotJumpForwardListsAndDropsExactlyWhatMoved() {
        let table = table()
        let size = table.count
        let hmacs = table.tagsComputed
        table.slide(wall: wall + 5 * BlindTag.slotMilliseconds)
        #expect(table.tagsComputed == hmacs + 2 * 5 * BlindTag.restarts, "five slots per key, each all restarts")
        #expect(table.slotSteps == 2 * 5)
        #expect(table.count == size)
        for gone in (slot - 32)...(slot - 28) {
            #expect(table.lookup(form(bobKey, gone), now: now) == nil, "slot \(gone) left")
        }
        #expect(table.lookup(form(bobKey, slot - 27), now: now)?.nodeId == bob)
        for entered in (slot + 3)...(slot + 7) {
            #expect(table.lookup(form(bobKey, entered, restart: 3), now: now)?.nodeId == bob, "slot \(entered) entered")
        }
        #expect(table.lookup(form(bobKey, slot + 8), now: now) == nil)
    }

    @Test func aBackwardJumpListsTheOlderSlotsAndDropsTheAheadOnes() {
        let table = table()
        let hmacs = table.tagsComputed
        table.slide(wall: wall - 3 * BlindTag.slotMilliseconds)
        #expect(table.tagsComputed == hmacs + 2 * 3 * BlindTag.restarts)
        for back in (slot - 35)...(slot - 33) {
            #expect(table.lookup(form(carolKey, back, owner: carol), now: now)?.nodeId == carol, "slot \(back) came back")
        }
        for ahead in slot...(slot + 2) {
            #expect(table.lookup(form(carolKey, ahead, owner: carol), now: now) == nil, "slot \(ahead) now ahead of the window")
        }
        #expect(table.lookup(form(carolKey, slot - 1, owner: carol), now: now)?.nodeId == carol)
    }

    @Test func aJumpPastTheWholeWindowRelistsItOnce() {
        let table = table()
        let size = table.count
        let hmacs = table.tagsComputed
        table.slide(wall: wall + 100 * BlindTag.slotMilliseconds)
        #expect(table.tagsComputed == hmacs + size)
        #expect(table.count == size)
        #expect(table.lookup(form(bobKey, slot), now: now) == nil)
        #expect(table.lookup(form(bobKey, slot + 100), now: now)?.nodeId == bob)
        table.slide(wall: wall + 100 * BlindTag.slotMilliseconds)
        #expect(table.tagsComputed == hmacs + size, "the same slot again lists nothing")
    }

    @Test mutating func aKeyAnotherContactListsLeavesEachFormItsOwnerWhateverTheOrder() {
        // Mallory sent Bob's presence key as her own: as her current key, or as the previous one behind a key of hers.
        let theirs = [ContactKey(current: bobKey), ContactKey(current: fixture.key(), previous: bobKey, previousUntilMilliseconds: nil)]
        for mallorys in theirs {
            for (first, second) in [(bob, mallory), (mallory, bob)] {
                let listing = [bob: ContactKey(current: bobKey), mallory: mallorys]
                let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
                table.setKeys([first: required(listing[first])], now: now, wall: wall)
                table.setKeys([second: required(listing[second]), first: required(listing[first])], now: now, wall: wall)
                #expect(table.lookup(form(bobKey, slot), now: now)?.nodeId == bob)
                #expect(table.lookup(form(bobKey, slot, owner: mallory), now: now)?.nodeId == mallory)
                table.slide(wall: wall + BlindTag.slotMilliseconds)
                #expect(table.lookup(form(bobKey, slot + 3), now: now)?.nodeId == bob, "a slot the window gained")
                #expect(table.lookup(form(bobKey, slot + 3, owner: mallory), now: now)?.nodeId == mallory)
                // Unlisting the copier leaves Bob's tags mapped to him.
                table.setKeys([bob: ContactKey(current: bobKey)], now: now, wall: wall + BlindTag.slotMilliseconds)
                #expect(table.lookup(form(bobKey, slot), now: now)?.nodeId == bob)
                #expect(table.lookup(form(bobKey, slot + 3), now: now)?.nodeId == bob)
                #expect(table.lookup(form(bobKey, slot, owner: mallory), now: now) == nil)
            }
        }
    }

    @Test mutating func oneKeyUnderTwoGenerationsOfAContactStaysResolvedThroughLaterListings() {
        // A fork: the key policy compares bytes only within one generation, so the store holds Bob's key twice.
        let other = fixture.key()
        let forked = [bob: Self.list([bobKey, other, bobKey]), carol: ContactKey(current: carolKey)]
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        table.setKeys(forked, now: now, wall: wall)
        let current = form(bobKey, slot)
        let oldest = form(bobKey, slot - 32, restart: 2)
        let (at, owner) = (now, bob)
        let resolved = {
            #expect(table.lookup(current, now: at)?.nodeId == owner)
            #expect(table.lookup(oldest, now: at)?.nodeId == owner)
        }
        resolved()
        let hmacs = table.tagsComputed
        table.setKeys(forked, now: now, wall: wall)
        resolved()
        // Another contact's change, then Bob's own listing without the fork.
        var changed = forked
        changed[carol] = ContactKey(current: fixture.key())
        table.setKeys(changed, now: now, wall: wall)
        resolved()
        changed[bob] = Self.list([bobKey, other])
        table.setKeys(changed, now: now, wall: wall)
        resolved()
        #expect(table.lookup(form(bobKey, slot), now: now)?.current == true, "it stands at its newest place")
        #expect(table.builds == 4, "Bob's two keys and Carol's two, each built once")
        #expect(table.tagsComputed == hmacs + BlindFixture.windowSlots * BlindTag.restarts, "only Carol's new key listed")
    }

    @Test mutating func everyKeyOfTheStoresListIsListedAndAHitLapsesOnlyTheOlderOnesAfterTheCap() {
        // The store's three keys, newest first: a next key gone ahead, the current one, the previous one.
        let next = fixture.key()
        let previous = fixture.key()
        let one = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        one.setKeys([bob: ContactKey(current: bobKey)], now: now, wall: wall)
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        table.setKeys([bob: Self.list([next, bobKey, previous])], now: now, wall: wall)
        #expect(table.count == 3 * one.count, "all three listed")
        // A tag under the current key caps the previous one, never the next one.
        #expect(table.lookup(form(bobKey, slot), now: now)?.nodeId == bob)
        #expect(table.lookup(form(previous, slot), now: now)?.nodeId == bob, "capped, not gone")
        table.lapse(now: now + Self.week)
        #expect(table.lookup(form(previous, slot), now: now + Self.week) == nil, "older than the one heard, past its cap")
        #expect(table.lookup(form(next, slot), now: now + Self.week)?.nodeId == bob, "newer than the one heard")
        // The same listing again keeps the lapsed key out, and costs no HMAC.
        let hmacs = table.tagsComputed
        table.setKeys([bob: Self.list([next, bobKey, previous])], now: now + Self.week + 1, wall: wall)
        #expect(table.lookup(form(previous, slot), now: now + Self.week + 1) == nil)
        #expect(table.tagsComputed == hmacs)
    }

    @Test mutating func aHitUnderTheNextKeyAloneLeavesTheCurrentKeyResolving() {
        // Another contact of Bob holds his next key and can air one tag under it.
        let next = fixture.key()
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        table.setKeys([bob: Self.list([next, bobKey])], now: now, wall: wall)
        #expect(table.lookup(form(next, slot), now: now)?.nodeId == bob)
        #expect(table.lookup(form(bobKey, slot), now: now + 1)?.nodeId == bob, "Bob's own tag still resolves")
        table.lapse(now: now + Self.week - 1)
        #expect(table.lookup(form(bobKey, slot), now: now + Self.week - 1)?.nodeId == bob, "until a key generation has passed")
        // A second hit under the next key does not push the cap back.
        _ = table.lookup(form(next, slot), now: now + Self.week - 1)
        table.lapse(now: now + Self.week)
        #expect(table.lookup(form(bobKey, slot), now: now + Self.week) == nil)
    }

    @Test mutating func aKeyTheStoresListDropsIsUnlistedAtOnceAndTheListIsNeverCappedByTime() {
        let next = fixture.key()
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: 1000)
        table.setKeys([bob: Self.list([next, bobKey])], now: now, wall: wall)
        table.lapse(now: now + 10_000)
        #expect(table.lookup(form(bobKey, slot), now: now)?.nodeId == bob, "the store's list is bounded by the store, not the cap")
        table.setKeys([bob: Self.list([next])], now: now + 20_000, wall: wall)
        #expect(table.lookup(form(bobKey, slot), now: now) == nil, "dropped by the store: unlisted at once")
    }

    /// A lapse reaches only the contact whose older key's cap has passed: another contact's keys, under no cap, stand.
    @Test mutating func aLapseDropsOnlyTheKeyWhoseCapPassedAndLeavesOtherContactsListed() {
        let previous = fixture.key()
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        table.setKeys([bob: Self.list([bobKey, previous]), carol: ContactKey(current: carolKey)], now: now, wall: wall)
        #expect(table.lookup(form(bobKey, slot), now: now)?.current == true, "a hit under Bob's newest caps his previous")
        table.lapse(now: now + Self.week)
        #expect(table.lookup(form(previous, slot), now: now + Self.week) == nil)
        #expect(table.lookup(form(carolKey, slot, owner: carol), now: now + Self.week)?.nodeId == carol, "Carol's key stands")
        #expect(table.contactCount == 2)
        #expect(table.count == 2 * BlindFixture.windowSlots * BlindTag.restarts)
    }

    /// Kotlin's `ContactKey` requires a key (`require(keys.isNotEmpty())`, `AdvertAliases.kt:139-159`): the store's list
    /// with none makes no contact, so a listing that names a contact with no keys lists nothing for it.
    @Test func aContactWithNoKeysIsNotListed() {
        #expect(ContactKey(keys: []) == nil)
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: Self.week)
        let listing: [NodeId: [PresenceKey]] = [bob: [], carol: [carolKey]]
        table.setKeys(listing.compactMapValues(ContactKey.init(keys:)), now: now, wall: wall)
        #expect(table.contactCount == 1)
        #expect(table.lookup(form(carolKey, slot, owner: carol), now: now)?.nodeId == carol)
    }
}
