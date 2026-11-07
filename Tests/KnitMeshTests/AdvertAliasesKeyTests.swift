import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertAliases``' key rules beside `AdvertAliasesTests` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): what a contact's
/// key, listed after an announcement, a hint or a claim, outranks, and what an answer is equal to, from `AdvertAliasesTest.kt`
/// at `cad69c77b` and the `AdvertAliases.kt` rows it leaves untested.
@Suite struct AdvertAliasesKeyTests {
    typealias Aliases = AdvertAliases<String>
    typealias ContactKey = Aliases.ContactKey

    let clocks = BlindClocks()
    var fixture = BlindFixture()
    let alice = BlindFixture.id("alice")
    let bob = BlindFixture.id("bob")
    let mallory = BlindFixture.id("mallory")
    let bobKey: PresenceKey

    init() {
        bobKey = fixture.key()
    }

    func tagUnder(_ key: PresenceKey, restart: Int = 0, owner: NodeId? = nil) -> NodeId {
        BlindFixture.tag(key, owner: owner ?? bob, slot: BlindTag.slotOf(wallMilliseconds: clocks.wall), restart: restart)
    }

    func blinded(_ tag: NodeId) -> AdvertOrder.Form {
        BlindFixture.blinded(tag)
    }

    func aliases() -> Aliases {
        clocks.aliases(String.self)
    }

    /// Kotlin's `aKeyThatArrivesLaterDropsTheClaimItContradicts`, for the other entries a key outranks (`dropContradicted`,
    /// `AdvertAliases.kt:578-895`): an announcement and a hint naming another id for the tag go at its first resolve once
    /// the key is listed, counted.
    @Test mutating func aKeyThatArrivesLaterDropsTheAnnouncementAndTheHintItContradicts() {
        let aliases = aliases()
        let bobs = tagUnder(bobKey)
        let alices = tagUnder(fixture.key(), owner: alice)
        #expect(aliases.onTagNext("l1", provenId: mallory, tag: bobs) == .pending)
        #expect(aliases.onAnswered("l2", told: alices, provenId: alice) == .hinted)
        #expect(aliases.onAnswered("l3", told: bobs, provenId: mallory) == .hinted)
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .key))
        #expect(aliases.counters.claimsDropped == 2, "mallory's announcement and her hint")
        #expect(aliases.counters.pending == 0)
        #expect(aliases.counters.hints == 1, "a hint for another tag stands until its own tag resolves")
        aliases.setKeys([:])
        #expect(aliases.resolve(blinded(bobs)) == .unresolved, "gone, not shadowed")
        #expect(aliases.resolve(blinded(alices)) == .resolved(alice, .hint))
    }

    /// A key listed for a tag a link announced outranks the dial that later takes it (`onDialed`, then `record`): nothing is
    /// recorded, the announcement is settled, and a key naming another id counts the claim dropped.
    @Test(arguments: [false, true])
    mutating func aKeyListedForAnAnnouncedTagLeavesTheDialThatTakesItNothingToRecord(liar: Bool) {
        let aliases = aliases()
        let old = tagUnder(fixture.key())
        let next = tagUnder(bobKey)
        let claimant = liar ? mallory : bob
        #expect(aliases.onDialed("l1", dialed: blinded(old), told: old, provenId: claimant) == .recorded)
        #expect(aliases.onTagNext("l1", provenId: claimant, tag: next) == .pending)
        aliases.setKeys([bob: ContactKey(current: bobKey)])
        // We redial the old tag after the rotation: the HELLO tells the announced one.
        #expect(aliases.onDialed("l2", dialed: blinded(old), told: next, provenId: claimant) == (liar ? .contradicted : .redundant))
        #expect(aliases.counters.pending == 0, "the announcement is settled")
        #expect(aliases.counters.claimsDropped == (liar ? 1 : 0))
        #expect(aliases.resolve(blinded(next)) == .resolved(bob, .key))
    }

    /// Kotlin's `Resolved` compares the id and the source only (`:176-184`): two answers that differ in their claimant alone
    /// are one answer, hashed alike, and only a resolved form carries one.
    @Test func answersNamingOneIdFromOneSourceAreOneWhateverTheirClaimant() {
        let answers: Set = [
            Aliases.Answer(nodeId: alice, source: .hint, claimant: "l1"), Aliases.Answer(nodeId: alice, source: .hint, claimant: "l2"),
            Aliases.Answer(nodeId: alice, source: .claim, claimant: "l1"), Aliases.Answer(nodeId: bob, source: .hint, claimant: "l1"),
        ]
        #expect(answers.count == 3)
        let keyed = Aliases.Answer(nodeId: alice, source: .key, claimant: "l1")
        #expect(Set<Aliases.Resolution>([.resolved(alice, .key), .resolved(keyed)]).count == 1)
        for unanswered: Aliases.Resolution in [.unresolved, .malformed] {
            #expect(unanswered.answer == nil)
        }
    }
}
