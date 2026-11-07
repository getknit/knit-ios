import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertAliases``' claim rules (knit-next ADR 2026-11.xp6d, the design and security passes of 2026-11-02; ADR
/// 2026-11.sv5t), ported case for case from `AdvertAliasesTest.kt` at `cad69c77b` beside `AdvertAliasesTests`. Kotlin's
/// `aSpotCheckIsRateLimitedAndVoidsALiarsClaims` is left out with the spot check it tests, unwired on Android too.
@Suite struct AdvertAliasesClaimTests {
    typealias Aliases = AdvertAliases<String>

    let clocks = BlindClocks()
    var fixture = BlindFixture()
    let alice = BlindFixture.id("alice")
    let bob = BlindFixture.id("bob")
    let mallory = BlindFixture.id("mallory")
    func tagUnder(_ key: PresenceKey, slotOffset: Int64 = 0, owner: NodeId? = nil) -> NodeId {
        BlindFixture.tag(key, owner: owner ?? bob, slot: BlindTag.slotOf(wallMilliseconds: clocks.wall) + slotOffset)
    }

    mutating func freshTag() -> NodeId {
        tagUnder(fixture.key())
    }

    func blinded(_ tag: NodeId) -> AdvertOrder.Form {
        BlindFixture.blinded(tag)
    }

    func aliases(_ configuration: Aliases.Configuration = Aliases.Configuration()) -> Aliases {
        clocks.aliases(String.self, configuration: configuration)
    }

    /// Two tags, the smaller first.
    mutating func twoTags() -> (NodeId, NodeId) {
        let one = freshTag()
        let other = freshTag()
        return one < other ? (one, other) : (other, one)
    }

    @Test mutating func aDialerBelievesTheResponderOnlyWhenItToldTheTagDialed() {
        let aliases = aliases()
        let tag = freshTag()
        #expect(aliases.onDialed("l1", dialed: blinded(tag), told: nil, provenId: mallory) == .ignored)
        #expect(
            aliases.onDialed("l1", dialed: blinded(tag), told: mallory, provenId: mallory) == .ignored, "a clear responder's t is no tag")
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
        #expect(aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice) == .recorded)
        #expect(aliases.resolve(blinded(tag)) == .resolved(alice, .claim))
        #expect(aliases.counters.resolvedByClaim == 1)
    }

    @Test mutating func aDifferentTAfterATagDialIsARotationEdgeHeldPending() {
        let aliases = aliases()
        let dialed = freshTag()
        let rotated = freshTag()
        // Alice rotated between my sighting and my dial: her HELLO tells her new tag, not the one I dialed.
        #expect(aliases.onDialed("l1", dialed: blinded(dialed), told: rotated, provenId: alice) == .pending)
        #expect(aliases.resolve(blinded(dialed)) == .unresolved, "the dialed tag is not taken for hers")
        #expect(aliases.resolve(blinded(rotated)) == .resolved(alice, .claim), "the told tag becomes her claim once heard")
    }

    @Test mutating func aHeldLinksClaimNeverLapsesUnheardAndLapsesAfterItsEnd() {
        let aliases = aliases()
        let tag = freshTag()
        let next = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onTagNext("l2", provenId: bob, tag: next)
        let lifetime = Aliases.Configuration().claimLifetimeMilliseconds
        // Deep suspend: nothing heard for three lifetimes while both links stand.
        clocks.now += 3 * lifetime
        #expect(aliases.resolve(blinded(tag)) == .resolved(alice, .claim), "unheard but held: still hers")
        #expect(aliases.resolve(blinded(tag)).answer?.claimant == "l1", "a claim's answer carries its claimant")
        #expect(aliases.resolve(blinded(next)) == .resolved(bob, .claim), "an announced tag outlives the hold too")
        aliases.onLinkEnded("l1")
        clocks.now += lifetime - 1
        #expect(aliases.resolve(blinded(tag)) == .resolved(alice, .claim), "past its link it still names her")
        #expect(aliases.resolve(blinded(tag)).answer?.claimant == "l1", "the claimant stays the ended link")
        clocks.now += 1
        #expect(aliases.resolve(blinded(tag)) == .unresolved, "990 s after the link ended")
    }

    @Test mutating func aDialToAnAnnouncedTagTakesTheNewTag() {
        let aliases = aliases()
        let old = freshTag()
        let next = freshTag()
        #expect(aliases.onDialed("l1", dialed: blinded(old), told: old, provenId: alice) == .recorded)
        #expect(aliases.onTagNext("l1", provenId: alice, tag: next) == .pending)
        // The link drops; we redial the old tag while Alice has rotated: her HELLO tells the new one.
        #expect(aliases.onDialed("l2", dialed: blinded(old), told: next, provenId: alice) == .recorded)
        #expect(aliases.resolve(blinded(next)) == .resolved(alice, .claim))
        #expect(aliases.resolve(blinded(old)) == .unresolved, "one claim per id: the old tag is replaced")
    }

    @Test mutating func twoIdsClaimingOneTagVoidBothAndAThirdIsRefused() {
        let aliases = aliases()
        let tag = freshTag()
        #expect(aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice) == .recorded)
        #expect(aliases.onDialed("l2", dialed: blinded(tag), told: tag, provenId: mallory) == .contested)
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
        #expect(aliases.onDialed("l3", dialed: blinded(tag), told: tag, provenId: alice) == .contested)
        #expect(aliases.onTagNext("l4", provenId: bob, tag: tag) == .contested)
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
        #expect(aliases.counters.claimsVoided == 4)
        clocks.now += Aliases.Configuration().claimLifetimeMilliseconds
        #expect(
            aliases.onDialed("l5", dialed: blinded(tag), told: tag, provenId: alice) == .recorded, "the void lasts as long as the tag could"
        )
    }

    @Test mutating func aLinkAndAnIdEachHoldOneClaim() {
        let aliases = aliases()
        let tags = (0..<4).map { _ in freshTag() }
        aliases.onDialed("l1", dialed: blinded(tags[0]), told: tags[0], provenId: alice)
        aliases.onTagNext("l1", provenId: alice, tag: tags[1])
        #expect(aliases.resolve(blinded(tags[1])) == .resolved(alice, .claim))
        #expect(aliases.resolve(blinded(tags[0])) == .unresolved, "the new claim replaced the old one")
        // The link rule alone: the same link now proves another id, so only "one per link" can drop alice's claim.
        aliases.onDialed("l1", dialed: blinded(tags[3]), told: tags[3], provenId: bob)
        #expect(aliases.resolve(blinded(tags[1])) == .unresolved, "the link's new claim replaced its old one")
        #expect(aliases.resolve(blinded(tags[3])) == .resolved(bob, .claim))
        // The id rule alone: the same id on another link.
        aliases.onDialed("l2", dialed: blinded(tags[2]), told: tags[2], provenId: bob)
        #expect(aliases.resolve(blinded(tags[3])) == .unresolved, "the id's new claim replaced its old one")
        #expect(aliases.resolve(blinded(tags[2])) == .resolved(bob, .claim))
    }

    @Test mutating func aLinksNewAnnouncementReplacesItsPendingOneWhateverIdItNames() {
        let aliases = aliases()
        let first = freshTag()
        let second = freshTag()
        aliases.onTagNext("l1", provenId: alice, tag: first)
        clocks.now += Aliases.Configuration().tagNextMinIntervalMilliseconds
        aliases.onTagNext("l1", provenId: mallory, tag: second)
        #expect(aliases.resolve(blinded(first)) == .unresolved, "the link's earlier announcement is gone")
        #expect(aliases.resolve(blinded(second)) == .resolved(mallory, .claim))
    }

    @Test mutating func aClaimOutlivesItsLinkUntilTheTagWouldHaveExpired() {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onLinkEnded("l1")
        clocks.now += Aliases.Configuration().claimLifetimeMilliseconds - 1
        #expect(aliases.resolve(blinded(tag)) == .resolved(alice, .claim))
        clocks.now += 1
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
        #expect(Aliases.Configuration().claimLifetimeMilliseconds == 990_000)
    }

    @Test mutating func anHonestHintResolvesAndWantsNoDial() {
        let aliases = aliases()
        let (mine, alices) = twoTags()
        // Alice dialed me, so under the antisymmetric rule I would not have dialed her, clear or blinded.
        #expect(aliases.onAnswered("l1", told: alices, provenId: alice) == .hinted)
        #expect(aliases.resolve(blinded(alices)) == .resolved(alice, .hint))
        #expect(!AdvertOrder.iDial(.clear(bob), blinded(alices)))
        #expect(!AdvertOrder.iDial(blinded(mine), blinded(alices)))
        #expect(aliases.counters.resolvedByHint == 1)
        #expect(aliases.onAnswered("l2", told: bob, provenId: bob) == .ignored, "a clear dialer leaves no hint")
        aliases.onLinkEnded("l1")
        #expect(aliases.resolve(blinded(alices)) == .unresolved, "a link's end takes its hint")
    }

    @Test mutating func aRotationUnderAHintIsHealedByTheResendAsAClaim() {
        let aliases = aliases()
        let (dialers, mine) = twoTags()
        // Dialer D linked to me (R) on its tag; I then rotate to a tag that sorts above D's, so the order has me dial D.
        #expect(aliases.onAnswered("l1", told: dialers, provenId: alice) == .hinted)
        #expect(aliases.resolve(blinded(dialers)) == .resolved(alice, .hint))
        #expect(AdvertOrder.iDial(blinded(mine), blinded(dialers)), "a hint never suppresses this dial on Android")
        // D refuses that dial with no reply and resends its current tag over the held link.
        #expect(aliases.onTagNext("l1", provenId: alice, tag: dialers) == .pending)
        #expect(aliases.resolve(blinded(dialers)) == .resolved(alice, .claim), "heard again: now a claim")
    }

    @Test mutating func aForgedHintLeavesTheDialStandingAndItsProofVoidsTheLiar() {
        let aliases = aliases()
        let (alices, mine) = twoTags()
        let strangers = freshTag()
        // Mallory dials me and names Alice's tag; she also holds a claim from an earlier link.
        aliases.onDialed("l0", dialed: blinded(strangers), told: strangers, provenId: mallory)
        #expect(aliases.onAnswered("l1", told: alices, provenId: mallory) == .hinted)
        #expect(aliases.resolve(blinded(alices)) == .resolved(mallory, .hint))
        #expect(AdvertOrder.iDial(blinded(mine), blinded(alices)), "a hint never suppresses this dial on Android")
        // The dial reaches the device airing Alice's tag, which proves Alice.
        #expect(aliases.onDialed("l2", dialed: blinded(alices), told: alices, provenId: alice) == .recorded)
        #expect(aliases.resolve(blinded(alices)) == .resolved(alice, .claim))
        #expect(aliases.resolve(blinded(strangers)) == .unresolved, "the liar loses every claim")
        #expect(aliases.counters.proofMismatches == 1)
        #expect(aliases.counters.claimsVoided == 2)
        #expect(!aliases.onDialProved(.clear(alice), provenId: alice), "a clear dial proves nothing about a tag")
    }

    @Test mutating func twoDialsToOneTagProvingTwoIdsAreAContestNotALie() {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onAnswered("l9", told: tag, provenId: bob)
        #expect(aliases.onDialed("l2", dialed: blinded(tag), told: tag, provenId: mallory) == .contested)
        #expect(aliases.resolve(blinded(tag)) == .unresolved, "no hint resolves a void tag")
        #expect(aliases.counters.proofMismatches == 1, "the unproven hint was the lie")
    }

    @Test mutating func hintsThatDisagreeResolveNothing() {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onAnswered("l1", told: tag, provenId: alice)
        aliases.onAnswered("l2", told: tag, provenId: bob)
        #expect(aliases.resolve(blinded(tag)) == .unresolved)
    }

    @Test mutating func anAnnouncedTagResolvesOnlyOnceHeardThenReplacesTheLinksClaim() {
        let aliases = aliases()
        let old = freshTag()
        let next = freshTag()
        aliases.onDialed("l1", dialed: blinded(old), told: old, provenId: alice)
        #expect(aliases.onTagNext("l1", provenId: alice, tag: next) == .pending)
        #expect(aliases.resolve(blinded(old)) == .resolved(alice, .claim), "the old tag still resolves before the rotation")
        #expect(aliases.resolve(blinded(next)) == .resolved(alice, .claim), "first heard: it becomes the claim")
        #expect(aliases.resolve(blinded(old)) == .unresolved)
    }

    @Test mutating func myOwnTagIsNeverAClaim() {
        let aliases = aliases()
        let mine = freshTag()
        aliases.setOwnTags(current: mine, previous: nil)
        #expect(aliases.onDialed("l1", dialed: blinded(mine), told: mine, provenId: mallory) == .ignored)
        #expect(aliases.onTagNext("l1", provenId: mallory, tag: mine) == .ignored)
        #expect(aliases.resolve(blinded(mine)) == .own)
    }
}
