import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertAliases`` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): resolve order, the expected-tag table and its window,
/// and a contact's key replaced mid-tag, ported case for case from `AdvertAliasesTest.kt` at `cad69c77b`. The claim rules
/// are in `AdvertAliasesClaimTests`. Both clocks are fields the test moves; keys come from a seeded generator.
@Suite struct AdvertAliasesTests {
    typealias Aliases = AdvertAliases<String>
    typealias ContactKey = Aliases.ContactKey

    let clocks = BlindClocks()
    var fixture = BlindFixture()
    let alice = BlindFixture.id("alice")
    let bob = BlindFixture.id("bob")
    let mallory = BlindFixture.id("mallory")
    let aliceKey: PresenceKey
    let bobKey: PresenceKey

    init() {
        aliceKey = fixture.key()
        bobKey = fixture.key()
    }

    /// `owner`'s tag under `key` for the slot `slotOffset` from the wall clock's, at `restart`.
    func tagUnder(_ key: PresenceKey, slotOffset: Int64 = 0, restart: Int = 0, owner: NodeId? = nil) -> NodeId {
        BlindFixture.tag(key, owner: owner ?? bob, slot: BlindTag.slotOf(wallMilliseconds: clocks.wall) + slotOffset, restart: restart)
    }

    func blinded(_ tag: NodeId) -> AdvertOrder.Form {
        BlindFixture.blinded(tag)
    }

    func aliases(_ configuration: Aliases.Configuration = Aliases.Configuration()) -> Aliases {
        clocks.aliases(String.self, configuration: configuration)
    }

    @Test func aClearAdvertIsItsOwnId() {
        #expect(aliases().resolve(.clear(alice)) == .resolved(alice, .clear))
    }

    /// Kotlin's second case, a form that is no 26-character string, cannot be a ``NodeId`` here.
    @Test func aBlindedFormWithoutThePrefixIsMalformed() {
        let aliases = aliases()
        aliases.setKeys([alice: ContactKey(current: aliceKey)])
        #expect(aliases.resolve(blinded(bob)) == .malformed)
        #expect(aliases.counters.malformed == 1)
    }

    @Test mutating func myOwnTagsAreOwn() {
        let aliases = aliases()
        let mine = fixture.key()
        let current = tagUnder(mine)
        let previous = tagUnder(mine, restart: 1)
        aliases.setKeys([alice: ContactKey(current: aliceKey)])
        aliases.setOwnTags(current: current, previous: previous)
        #expect(aliases.resolve(blinded(current)) == .own)
        #expect(aliases.resolve(blinded(previous)) == .own)
    }

    @Test mutating func aContactResolvesOnItsFirstSightingAndAFloodCostsNoHmacs() {
        let aliases = aliases()
        aliases.setKeys([alice: ContactKey(current: aliceKey), bob: ContactKey(current: bobKey)])
        let listed = 2 * BlindFixture.windowSlots * BlindTag.restarts
        #expect(aliases.counters.tableSize == listed)
        let built = aliases.counters.tableHmacs
        #expect(built == listed)
        for _ in 0..<10_000 {
            #expect(aliases.resolve(blinded(tagUnder(fixture.key()))) == .unresolved)
        }
        #expect(aliases.counters.tableHmacs == built, "a flood of unknown tags costs no HMAC")
        #expect(aliases.resolve(blinded(tagUnder(bobKey))) == .resolved(bob, .key), "first sighting")
    }

    @Test func aTagResolvesOnlyWhileItsSlotIsInTheWindow() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        #expect(aliases.resolve(blinded(tagUnder(bobKey, slotOffset: -32))) == .resolved(bob, .key), "8 hours back")
        #expect(aliases.resolve(blinded(tagUnder(bobKey, slotOffset: 2))) == .resolved(bob, .key), "half an hour ahead")
        #expect(aliases.resolve(blinded(tagUnder(bobKey, slotOffset: -33))) == .unresolved, "past the window")
        #expect(aliases.resolve(blinded(tagUnder(bobKey, slotOffset: 3))) == .unresolved, "more than 30 min ahead")
    }

    @Test func aSlotChangeListsTheNewSlotAndDropsTheOldest() {
        let aliases = aliases()
        aliases.setKeys([alice: ContactKey(current: aliceKey), bob: ContactKey(current: bobKey)])
        let oldest = tagUnder(bobKey, slotOffset: -32)
        let beyond = tagUnder(bobKey, slotOffset: 3)
        let before = aliases.counters
        clocks.wall += BlindTag.slotMilliseconds
        #expect(aliases.resolve(blinded(oldest)) == .unresolved, "the oldest slot left")
        #expect(aliases.resolve(blinded(beyond)) == .resolved(bob, .key), "the new ahead slot entered")
        let after = aliases.counters
        #expect(after.tableSize == before.tableSize)
        #expect(after.tableHmacs == before.tableHmacs + 2 * BlindTag.restarts, "one slot per key")
        #expect(after.tableSlotSteps == before.tableSlotSteps + 2)
        #expect(after.tableBuilds == before.tableBuilds, "no key rebuilt")
    }

    @Test func everyRestartIndexResolves() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        for restart in 0..<BlindTag.restarts {
            #expect(aliases.resolve(blinded(tagUnder(bobKey, restart: restart))) == .resolved(bob, .key))
        }
    }

    @Test func aContactSendingAnothersKeyGainsNothingOverHim() {
        let aliases = aliases()
        // Mallory sent Bob's presence key as her own: the tags it lists under her id are hers, and his stay his.
        aliases.setKeys([bob: ContactKey(current: bobKey), mallory: ContactKey(current: bobKey)])
        let bobs = tagUnder(bobKey)
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key))
        #expect(aliases.resolve(blinded(tagUnder(bobKey, owner: mallory))) == .resolved(mallory, .key))
        // Bob's own dial proves what the key says: nothing to record, and his proof is no replay.
        #expect(aliases.onDialed("l1", dialed: blinded(bobs), told: bobs, provenId: bob) == .redundant)
        clocks.wall += BlindTag.slotMilliseconds
        aliases.slide()
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key), "the window moved; still his key")
        #expect(aliases.resolve(blinded(tagUnder(bobKey, slotOffset: 2))) == .resolved(bob, .key), "a slot the window gained is his too")
        #expect(aliases.counters.keyProofMismatches == 0)
        #expect(aliases.counters.claimsDropped == 0)
        // Her claim to his tag is one his key contradicts.
        #expect(aliases.onTagNext("l2", provenId: mallory, tag: bobs) == .contradicted)
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key))
    }

    @Test mutating func aKeyChangeRebuildsOnlyThatContact() {
        let aliases = aliases()
        aliases.setKeys([alice: ContactKey(current: aliceKey), bob: ContactKey(current: bobKey)])
        let before = aliases.counters.tableHmacs
        let bobNext = fixture.key()
        aliases.setKeys([alice: ContactKey(current: aliceKey), bob: ContactKey(current: bobNext)])
        let oneKey = BlindFixture.windowSlots * BlindTag.restarts
        #expect(aliases.counters.tableHmacs == before + oneKey, "only bob's new key listed")
        #expect(aliases.counters.tableSize == 3 * oneKey, "his old key stays listed until a successor tag is heard")
        #expect(aliases.resolve(blinded(tagUnder(bobNext))) == .resolved(bob, .key))
        #expect(aliases.counters.tableSize == 2 * oneKey)
    }

    @Test mutating func aKeyThatArrivesMidTagKeepsTheTagOnAirResolvedUntilASuccessorTagIsHeard() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let airing = tagUnder(bobKey)
        let bobNext = fixture.key()
        // Bob's next generation lands while he still airs a tag minted under the old key, and an idle phone may keep that
        // tag for hours: only hearing a tag under the new key retires the old one.
        clocks.now += 5000
        aliases.setKeys([bob: ContactKey(current: bobNext)])
        #expect(aliases.resolve(blinded(airing)) == .resolved(bob, .key))
        clocks.now += 6 * 3_600_000
        aliases.setKeys([bob: ContactKey(current: bobNext)])
        #expect(aliases.resolve(blinded(airing)) == .resolved(bob, .key), "hours later, the same set again, the old key still answers")
        #expect(aliases.resolve(blinded(tagUnder(bobNext))) == .resolved(bob, .key))
        #expect(aliases.resolve(blinded(airing)) == .unresolved, "a successor tag heard: the old key is retired")
    }

    @Test mutating func aReplacedKeyNobodyRetiresLastsOneKeyGeneration() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let airing = tagUnder(bobKey)
        aliases.setKeys([bob: ContactKey(current: fixture.key())])
        clocks.now += Aliases.Configuration().previousKeyMaxMilliseconds - 1
        #expect(aliases.resolve(blinded(airing)) == .resolved(bob, .key))
        clocks.now += 1
        #expect(aliases.resolve(blinded(airing)) == .unresolved)
        #expect(Aliases.Configuration().previousKeyMaxMilliseconds == 7 * 24 * 3_600_000)
    }

    @Test mutating func anExplicitPreviousKeyIsTriedUntilItsExpiry() {
        let aliases = aliases()
        let bobNext = fixture.key()
        aliases.setKeys([bob: ContactKey(current: bobNext, previous: bobKey, previousUntilMilliseconds: clocks.now + 10_000)])
        let old = tagUnder(bobKey)
        #expect(aliases.resolve(blinded(old)) == .resolved(bob, .key))
        clocks.now += 10_000
        #expect(aliases.resolve(blinded(old)) == .unresolved)
    }

    @Test func aRemovedContactStopsResolvingAtOnce() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let tag = tagUnder(bobKey)
        #expect(aliases.resolve(blinded(tag)) == .resolved(bob, .key))
        aliases.setKeys([:])
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
    }

    @Test func aKeyOutranksAClaimAndContradictsIt() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let bobs = tagUnder(bobKey)
        #expect(
            aliases.onDialed("l1", dialed: blinded(bobs), told: bobs, provenId: mallory) == .contradicted,
            "a tag dial proving another id than the key's records nothing")
        #expect(aliases.onDialed("l2", dialed: blinded(bobs), told: bobs, provenId: bob) == .redundant)
        #expect(aliases.onAnswered("l3", told: bobs, provenId: mallory) == .contradicted, "a hint the key contradicts is not held")
        #expect(aliases.onTagNext("l3", provenId: mallory, tag: bobs) == .contradicted)
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key))
        #expect(aliases.counters.claimsDropped == 3)
    }

    @Test func aKeyThatArrivesLaterDropsTheClaimItContradicts() {
        let aliases = aliases()
        let bobs = tagUnder(bobKey)
        #expect(aliases.onDialed("l1", dialed: blinded(bobs), told: bobs, provenId: mallory) == .recorded)
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key), "the key outranks it")
        #expect(aliases.counters.claimsDropped == 1)
        aliases.setKeys([:])
        #expect(aliases.resolve(blinded(bobs)) == .unresolved, "the claim is gone, not shadowed")
    }

    @Test func aTagDialProvingAnotherIdThanTheKeyIsAReplay() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let bobs = tagUnder(bobKey)
        #expect(!aliases.onDialProved(blinded(bobs), provenId: mallory))
        #expect(aliases.counters.keyProofMismatches == 1)
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key), "nothing voided: the key still answers")
    }

    @Test mutating func thePerLinkTablesShowInTheCountersAndGoAtTheLinksEnd() {
        let aliases = aliases()
        #expect(aliases.counters.tableContacts == 0)
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        #expect(aliases.counters.tableContacts == 1)
        #expect(aliases.onAnswered("answered", told: tagUnder(fixture.key()), provenId: alice) == .hinted)
        #expect(aliases.onTagNext("announced", provenId: mallory, tag: tagUnder(fixture.key())) == .pending)
        let live = aliases.counters
        #expect(live.hints == 1)
        #expect(live.heldLinks == 2)
        #expect(live.lastTagNext == 1)
        aliases.onLinkEnded("answered")
        let half = aliases.counters
        #expect(half.hints == 0, "the hint went with its link")
        #expect(half.heldLinks == 1)
        #expect(half.lastTagNext == 1, "the other link's TAG_NEXT mark stands")
        aliases.onLinkEnded("announced")
        let ended = aliases.counters
        #expect(ended.hints == 0)
        #expect(ended.heldLinks == 0)
        #expect(ended.lastTagNext == 0)
        #expect(ended.pending == 1, "an announced tag outlives its link by a claim lifetime")
        #expect(ended.tableContacts == 1, "a contact is no link")
    }

    /// Kotlin's `countersAndSpotChecksNeverPrintAKeyOrATag`, less the spot check this port leaves out.
    @Test mutating func countersNeverPrintAKeyOrATag() {
        let aliases = aliases()
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        let tag = tagUnder(fixture.key())
        _ = aliases.resolve(blinded(tagUnder(bobKey)))
        aliases.onTagNext("l1", provenId: alice, tag: tag)
        _ = aliases.resolve(blinded(tag))
        let printed = String(describing: aliases.counters) + String(describing: ContactKey(current: bobKey))
        #expect(!printed.contains(tag.string))
        #expect(!printed.contains(tag.string.dropFirst(8)))
        #expect(!printed.contains(bobKey.bytes.map { String($0, radix: 16) }.joined()))
    }

    /// This port's hint answer carries the hint's own link, which the suppressor reads (ADR 2026-11.sv5t); Kotlin's carries
    /// none. Equality still ignores it.
    @Test mutating func aHintsAnswerCarriesItsLink() {
        let aliases = aliases()
        let tag = tagUnder(fixture.key())
        aliases.onAnswered("l1", told: tag, provenId: alice)
        let answer = aliases.resolve(blinded(tag)).answer
        #expect(answer?.source == .hint)
        #expect(answer?.claimant == "l1")
    }
}
