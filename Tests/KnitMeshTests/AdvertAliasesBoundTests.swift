import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertAliases``' bounds (knit-next ADR 2026-11.xp6d, the design and security passes of 2026-11-02; ADR
/// 2026-11.sv5t), ported case for case from `AdvertAliasesTest.kt` at `cad69c77b` beside `AdvertAliasesClaimTests`: the
/// tables' caps, and what a Sybil cycling links or announcements costs.
@Suite struct AdvertAliasesBoundTests {
    typealias Aliases = AdvertAliases<String>

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

    @Test mutating func anEndedLinksAnnouncementGoesBeforeAHeldOnesAtTheCap() {
        let aliases = aliases(Aliases.Configuration(maxClaims: 1))
        let held = freshTag()
        let ended = freshTag()
        let late = freshTag()
        aliases.onTagNext("h", provenId: alice, tag: held)
        clocks.now += 1
        aliases.onTagNext("e", provenId: bob, tag: ended)
        aliases.onLinkEnded("e")
        clocks.now += 1
        aliases.onTagNext("l", provenId: mallory, tag: late)
        #expect(aliases.counters.pending == 2)
        #expect(aliases.resolve(blinded(held)) == .resolved(alice, .claim), "the held link's announcement stays, though older")
        #expect(aliases.resolve(blinded(ended)) == .unresolved, "the ended link's went")
    }

    @Test mutating func aVoidOurDialsMadeOutlastsUnprovenOnesAtTheCap() {
        let aliases = aliases(Aliases.Configuration(maxClaims: 1, tagNextMinIntervalMilliseconds: 0))
        let proven = freshTag()
        let first = freshTag()
        let second = freshTag()
        let eve = BlindFixture.id("eve")
        // Two of our dials to one tag prove two ids: a void that stands against a dial.
        aliases.onDialed("d1", dialed: blinded(proven), told: proven, provenId: alice)
        aliases.onDialed("d2", dialed: blinded(proven), told: proven, provenId: bob)
        clocks.now += 1
        aliases.onTagNext("u1", provenId: mallory, tag: first)
        aliases.onTagNext("u2", provenId: eve, tag: first)
        clocks.now += 1
        aliases.onTagNext("u3", provenId: mallory, tag: second)
        aliases.onTagNext("u4", provenId: eve, tag: second)
        #expect(aliases.counters.voided == 2)
        #expect(aliases.onTagNext("u5", provenId: bob, tag: first) == .pending, "the unproven void went, though younger")
        #expect(aliases.onDialed("d3", dialed: blinded(proven), told: proven, provenId: alice) == .contested, "ours stands")
    }

    @Test mutating func aFullTableEvictsTheSoonestEndedClaimAndNeverRefusesAHeldLink() {
        let aliases = aliases(Aliases.Configuration(maxClaims: 2))
        let tags = (0..<5).map { _ in freshTag() }
        let carol = BlindFixture.id("carol")
        let eve = BlindFixture.id("eve")
        aliases.onDialed("l0", dialed: blinded(tags[0]), told: tags[0], provenId: alice)
        aliases.onLinkEnded("l0")
        clocks.now += 1
        aliases.onDialed("l1", dialed: blinded(tags[1]), told: tags[1], provenId: bob)
        aliases.onLinkEnded("l1")
        clocks.now += 1
        #expect(
            aliases.onDialed("l2", dialed: blinded(tags[2]), told: tags[2], provenId: mallory) == .recorded,
            "a held link's claim takes the soonest ended one's place")
        #expect(aliases.resolve(blinded(tags[0])) == .unresolved)
        #expect(aliases.resolve(blinded(tags[1])) == .resolved(bob, .claim))
        #expect(aliases.onDialed("l3", dialed: blinded(tags[3]), told: tags[3], provenId: eve) == .recorded)
        #expect(aliases.counters.claimsEvicted == 2)
        // Every slot is a held link's now; an ended link's announced tag, first heard, cannot displace one.
        aliases.onTagNext("l4", provenId: carol, tag: tags[4])
        aliases.onLinkEnded("l4")
        #expect(aliases.resolve(blinded(tags[4])) == .unresolved)
        #expect(aliases.counters.claimsRefusedFull == 1)
        #expect(aliases.counters.pending == 1, "refused, the announced tag survives to try again")
        aliases.onLinkEnded("l2")
        #expect(aliases.resolve(blinded(tags[4])) == .resolved(carol, .claim))
        #expect(aliases.counters.pending == 0)
    }

    @Test mutating func sybilsCyclingDialProvenClaimsCannotLockOutAHeldLink() {
        let aliases = aliases()
        for index in 0..<200 {
            let tag = freshTag()
            #expect(aliases.onDialed("s\(index)", dialed: blinded(tag), told: tag, provenId: BlindFixture.id("sybil\(index)")) == .recorded)
            aliases.onLinkEnded("s\(index)")
            clocks.now += 10
        }
        #expect(aliases.counters.claims == Aliases.Configuration().maxClaims)
        let alices = tagUnder(aliceKey, owner: alice)
        #expect(aliases.onDialed("la", dialed: blinded(alices), told: alices, provenId: alice) == .recorded)
        #expect(aliases.resolve(blinded(alices)) == .resolved(alice, .claim))
        let bobs = tagUnder(bobKey)
        #expect(aliases.onTagNext("lb", provenId: bob, tag: bobs) == .pending)
        #expect(aliases.resolve(blinded(bobs)) == .resolved(bob, .claim), "a promoted announcement survives the full table")
        #expect(aliases.counters.claimsRefusedFull == 0)
    }

    @Test mutating func alternatingAnnouncementsStayBounded() {
        // Two links announce the same fresh tag, pair after pair: each pair voids a tag for 990 s.
        let throttled = aliases()
        let unthrottled = aliases(Aliases.Configuration(maxClaims: 8, tagNextMinIntervalMilliseconds: 0))
        let key = fixture.key()
        for index in 0..<10_000 {
            let tag = tagUnder(key, slotOffset: -Int64(index))
            for aliases in [throttled, unthrottled] {
                aliases.onTagNext("l1", provenId: alice, tag: tag)
                aliases.onTagNext("l2", provenId: mallory, tag: tag)
                _ = aliases.resolve(blinded(tag))
            }
            clocks.now += 50
        }
        let limited = throttled.counters
        #expect(limited.tagNextRateLimited > 19_000, "one TAG_NEXT per link per window")
        #expect(limited.voided <= Aliases.Configuration().entryCap)
        let open = unthrottled.counters
        let cap = Aliases.Configuration(maxClaims: 8).entryCap
        #expect(open.voided <= cap, "voids stay at their cap: \(open.voided)")
        #expect(open.pending <= cap, "announced tags stay at their cap: \(open.pending)")
        #expect(
            open.deadlines <= 4 * (open.claims + open.pending + open.voided) + 256, "the deadline queue stays bounded: \(open.deadlines)")
        #expect(open.entriesEvicted > 0)
    }

    /// Kotlin's bound above, with live claims and announcements under the stale deadlines: the queue rebuilt from the
    /// tables keeps every live entry's expiry, so each still lapses on time once its link ends.
    @Test mutating func aRebuiltDeadlineQueueStillLapsesEveryLiveEntry() {
        let aliases = aliases()
        let claimed = freshTag()
        #expect(aliases.onDialed("l0", dialed: blinded(claimed), told: claimed, provenId: alice) == .recorded)
        // Bob announces from 300 links in turn: each replaces his last announcement and leaves a stale deadline.
        var announced = claimed
        for index in 1...300 {
            announced = freshTag()
            #expect(aliases.onTagNext("l\(index)", provenId: bob, tag: announced) == .pending)
        }
        let live = aliases.counters
        #expect(live.claims == 1 && live.pending == 1)
        #expect(live.deadlines <= 4 * (live.claims + live.pending) + 256, "rebuilt: \(live.deadlines)")
        #expect(live.deadlines < 300)
        for index in 0...300 {
            aliases.onLinkEnded("l\(index)")
        }
        clocks.now += Aliases.Configuration().claimLifetimeMilliseconds - 1
        #expect(aliases.standing(claimed) == Aliases.Answer(nodeId: alice, source: .claim))
        clocks.now += 1
        #expect(aliases.standing(claimed) == nil)
        #expect(aliases.counters.claims == 0 && aliases.counters.pending == 0, "both lapsed on time")
        #expect(aliases.resolve(blinded(announced)) == .unresolved)
    }

    @Test mutating func ourDialLiftsAVoidThatUnprovenClaimantsMade() {
        let aliases = aliases()
        let strangersId = BlindFixture.id("stranger")
        let strangers = freshTag()
        let other = freshTag()
        aliases.onDialed("l0", dialed: blinded(other), told: other, provenId: mallory)
        aliases.onTagNext("l1", provenId: mallory, tag: strangers)
        #expect(aliases.onTagNext("l2", provenId: bob, tag: strangers) == .contested)
        #expect(aliases.resolve(blinded(strangers)) == .unresolved)
        #expect(
            aliases.onDialed("l3", dialed: blinded(strangers), told: strangers, provenId: strangersId) == .recorded,
            "our dial's proof lifts their void")
        #expect(aliases.resolve(blinded(strangers)) == .resolved(strangersId, .claim))
        #expect(aliases.resolve(blinded(other)) == .unresolved, "the claimants lose their other entries")
    }
}
