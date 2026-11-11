import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertAliases``' own-tag step, which sv5t left out and ADR 2026-11.prsp brings back (`AdvertAliasesTest.kt`'s
/// `myOwnTagsAreOwn` and `myOwnTagIsNeverAClaim` at knit-next `cad69c77b`), and what the writer reads of an announced tag.
@Suite struct AdvertAliasesOwnTagTests {
    typealias Aliases = AdvertAliases<String>
    typealias ContactKey = Aliases.ContactKey

    let clocks = BlindClocks()
    var fixture = BlindFixture()
    let alice = BlindFixture.id("alice")
    let bob = BlindFixture.id("bob")
    let mallory = BlindFixture.id("mallory")
    let aliceKey: PresenceKey

    init() {
        aliceKey = fixture.key()
    }

    /// `owner`'s tag under `key` for the slot `slotOffset` from the wall clock's, at `restart`.
    func tagUnder(_ key: PresenceKey, slotOffset: Int64 = 0, restart: Int = 0, owner: NodeId? = nil) -> NodeId {
        BlindFixture.tag(key, owner: owner ?? bob, slot: BlindTag.slotOf(wallMilliseconds: clocks.wall) + slotOffset, restart: restart)
    }

    func blinded(_ tag: NodeId) -> AdvertOrder.Form {
        BlindFixture.blinded(tag)
    }

    func aliases() -> Aliases {
        clocks.aliases(String.self, configuration: Aliases.Configuration())
    }

    @Test mutating func myOwnTagsAreOwn() {
        let resolver = aliases()
        let mine = fixture.key()
        let current = tagUnder(mine)
        let previous = tagUnder(mine, restart: 1)
        resolver.setKeys([alice: required(ContactKey(keys: [aliceKey]))])
        resolver.setOwnTags(current: current, previous: previous)
        #expect(resolver.resolve(blinded(current)) == .own)
        #expect(resolver.resolve(blinded(previous)) == .own)
        resolver.setOwnTags(current: nil, previous: nil)
        #expect(resolver.resolve(blinded(current)) == .unresolved, "no longer mine once I air my id")
    }

    @Test mutating func myOwnTagIsNeverAClaimAHintOrAnAnnouncement() {
        let resolver = aliases()
        let mine = tagUnder(fixture.key())
        resolver.setOwnTags(current: mine, previous: nil)
        #expect(resolver.onDialed("l1", dialed: blinded(mine), told: mine, provenId: mallory) == .ignored)
        #expect(resolver.onTagNext("l1", provenId: mallory, tag: mine) == .ignored)
        #expect(resolver.onAnswered("l2", told: mine, provenId: mallory) == .ignored)
        #expect(resolver.resolve(blinded(mine)) == .own)
        #expect(resolver.announced(by: mallory) == nil)
    }

    @Test mutating func anAnnouncedTagStandsForItsLinkUntilAnotherTakesIt() {
        let resolver = aliases()
        let next = tagUnder(fixture.key(), slotOffset: 1)
        #expect(resolver.onTagNext("l1", provenId: alice, tag: next) == .pending)
        #expect(resolver.announced(by: alice) == next)
        #expect(resolver.stillAnnounced("l1", provenId: alice, tag: next))
        #expect(!resolver.stillAnnounced("l2", provenId: alice, tag: next), "another link's")
        #expect(resolver.resolve(blinded(next)) == .resolved(alice, .claim), "heard: it becomes the claim")
        #expect(resolver.stillAnnounced("l1", provenId: alice, tag: next), "claimed by the link since")
        resolver.setKeys([alice: required(ContactKey(keys: [aliceKey]))])
        let keyed = tagUnder(aliceKey, owner: alice)
        #expect(resolver.stillAnnounced("l3", provenId: alice, tag: keyed), "what a contact's key already says")
    }
}
