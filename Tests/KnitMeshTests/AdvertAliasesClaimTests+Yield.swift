import Testing

@testable import KnitMesh

/// An ended claim's yield to its own id's hint, this port's rule inside ADR 2026-11.sv5t's departure
/// (``AdvertAliases/claimAnswer(_:)``); Kotlin's hint suppresses nothing, so `AdvertAliasesTest.kt` has no case for it.
extension AdvertAliasesClaimTests {
    /// This port's (ADR 2026-11.sv5t's departure): a claim whose link ended yields to the hint its own id left on the tag by
    /// dialing back in, so the new link holds the dial off, read alike by `standing` and `resolve`; and only while that
    /// hint's link is held, the ended claim answering again after, until it lapses.
    @Test mutating func anEndedClaimYieldsToItsOwnIdsHintWhileTheHintsLinkIsHeld() {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onLinkEnded("l1")
        #expect(aliases.onAnswered("l2", told: tag, provenId: alice) == .hinted, "she dialed back in, telling the same tag")
        let standing = aliases.standing(tag)
        #expect(standing == Aliases.Answer(nodeId: alice, source: .hint) && standing?.claimant == "l2")
        let resolved = aliases.resolve(blinded(tag))
        #expect(resolved == .resolved(alice, .hint) && resolved.answer?.claimant == "l2")
        #expect(aliases.counters.resolvedByHint == 1 && aliases.counters.resolvedByClaim == 0, "a hint's answer, counted as one")
        aliases.onLinkEnded("l2")
        #expect(aliases.standing(tag) == Aliases.Answer(nodeId: alice, source: .claim) && aliases.standing(tag)?.claimant == "l1")
        #expect(aliases.resolve(blinded(tag)).answer?.claimant == "l1", "the hint went with its link: the ended claim again")
        clocks.now += Aliases.Configuration().claimLifetimeMilliseconds
        #expect(aliases.resolve(blinded(tag)) == .unresolved, "and it lapses as it would have")
    }

    @Test mutating func aHeldClaimAnswersOverItsOwnIdsHintElsewhere() {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onAnswered("l2", told: tag, provenId: alice)
        #expect(aliases.standing(tag) == Aliases.Answer(nodeId: alice, source: .claim) && aliases.standing(tag)?.claimant == "l1")
        #expect(aliases.resolve(blinded(tag)).answer?.claimant == "l1")
        #expect(aliases.counters.resolvedByClaim == 1 && aliases.counters.resolvedByHint == 0)
    }

    /// The hint is chosen by the claim's id, never by the count of hints on the tag: another id's hint, alone or beside the
    /// claim's own id's, changes nothing about whose answer it is.
    @Test(arguments: [false, true])
    mutating func anEndedClaimYieldsOnlyToItsOwnIdsHint(ownIdToo: Bool) {
        let aliases = aliases()
        let tag = freshTag()
        aliases.onDialed("l1", dialed: blinded(tag), told: tag, provenId: alice)
        aliases.onLinkEnded("l1")
        aliases.onAnswered("l3", told: tag, provenId: mallory)
        if ownIdToo {
            aliases.onAnswered("l2", told: tag, provenId: alice)
        }
        let want = ownIdToo ? Aliases.Answer(nodeId: alice, source: .hint) : Aliases.Answer(nodeId: alice, source: .claim)
        #expect(aliases.standing(tag) == want && aliases.standing(tag)?.claimant == (ownIdToo ? "l2" : "l1"))
        let resolved = aliases.resolve(blinded(tag))
        #expect(resolved == .resolved(want) && resolved.answer?.claimant == (ownIdToo ? "l2" : "l1"))
    }
}
