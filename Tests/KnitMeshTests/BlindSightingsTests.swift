import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``BlindSightings``, ``ReplayMarks`` and ``Suppressor`` (knit-next ADR 2026-11.xp6d, step 5a obligations 8 and 11; ADR
/// 2026-11.sv5t), ported case for case from `BlindSightingsTest.kt` at `cad69c77b`, but for `aLateSightingReaches…`, whose
/// `reach` serves Android's asynchronous resolver and its Coded, Aware and side-channel audiences, none of which this
/// synchronous port has. This port's hint row, and `DialPlan.suppressed`'s, are added.
@Suite struct BlindSightingsTests {
    private typealias Resolution = AdvertAliases<String>.Resolution
    private typealias Attribution = BlindSightings.Attribution<String>

    private let handle = FormHandle(number: 0)
    private let bbb = BlindFixture.id("bbb")

    private func attribute(_ resolution: Resolution, replayed: Bool = false) -> Attribution? {
        BlindSightings.attribute(resolution, handle: handle, replayed: replayed)
    }

    private func answer(_ source: AdvertAliases<String>.Source, claimant: String? = nil) -> Resolution {
        .resolved(AdvertAliases<String>.Answer(nodeId: bbb, source: source, claimant: claimant))
    }

    @Test func anUnresolvedFormStaysUnderItsHandleAndNeverSuppresses() {
        #expect(attribute(.unresolved) == Attribution(key: .form(handle), suppressor: .never, history: .inPlace, full: true))
    }

    @Test func aKeysAnswerCarriesTheHistoryAndSuppressesOnlyThroughAProvenLinkReadAtTheDial() {
        let keyed = attribute(answer(.key))
        #expect(keyed?.key == .node(bbb))
        #expect(keyed?.history == .carry)
        #expect(keyed?.suppressor == .proven, "nothing counts as linked to X without X's proof")
    }

    @Test func aReplayedTagAttributesAndCarriesNothing() {
        #expect(attribute(answer(.key), replayed: true) == nil)
    }

    @Test func aClaimAttributesFromNowOnAndNeverBackwards() {
        let claim = attribute(answer(.claim, claimant: "link"))
        #expect(claim?.history == .drop)
        #expect(claim?.suppressor == .claim("link"), "the claimant's own link, read when the dial is decided")
        #expect(attribute(answer(.claim))?.suppressor == Suppressor<String>.never)
    }

    /// Kotlin's `aHintFeedsPresenceOnlyAndNeverSuppresses`, with this port's departure: a hint holds off a dial while its
    /// own link is held (ADR 2026-11.sv5t).
    @Test func aHintFeedsPresenceAndSuppressesOnlyThroughItsOwnLink() {
        #expect(
            attribute(answer(.hint, claimant: "link"))
                == Attribution(key: .node(bbb), suppressor: .hint("link"), history: .drop, full: false))
        #expect(attribute(answer(.hint))?.suppressor == Suppressor<String>.never)
    }

    @Test func aHandshakeEventAfterItsLinkEndedNeverReachesTheResolver() {
        // The end is enqueued only after the link leaves the table, so the guard orders every event it lets through before
        // that end; one it stops would have held a dead link and a hint for good.
        let clocks = BlindClocks()
        let aliases = clocks.aliases(String.self)
        let key = required(PresenceKey(bytes: [UInt8](repeating: 3, count: PresenceKey.byteCount)))
        let tag = BlindFixture.tag(key, owner: required(NodeId(bytes: [UInt8](repeating: 0, count: NodeId.byteCount))), slot: 1)
        let fork = BlindFixture.id("fork")
        let link = "link"
        // The fork proves and closes at once: its end runs before its `onAnswered`.
        let registered: String? = nil
        aliases.onLinkEnded(link)
        if BlindSightings.current(registered: registered, link: link) {
            aliases.onAnswered(link, told: tag, provenId: fork)
        }
        clocks.now += 24 * 60 * 60_000
        #expect(aliases.resolve(BlindFixture.blinded(tag)) == .unresolved, "no hint stands for the dead link")
        // The positive control: the same order unguarded leaves a hint that never lapses (why the guard exists).
        let unguarded = clocks.aliases(String.self)
        unguarded.onLinkEnded("dead")
        unguarded.onAnswered("dead", told: tag, provenId: fork)
        clocks.now += 24 * 60 * 60_000
        #expect(unguarded.resolve(BlindFixture.blinded(tag)) == .resolved(fork, .hint), "a dead link's hint")
        // While the link is the registered one, the event goes through and its end follows it.
        #expect(BlindSightings.current(registered: "live", link: "live"))
        #expect(!BlindSightings.current(registered: "another", link: "live"), "a replacement under the same id is another link")
    }

    @Test func myOwnTagAndAMalformedOneAttributeNothing() {
        #expect(attribute(.own) == nil)
        #expect(attribute(.malformed) == nil)
    }

    @Test func aReplayIsThePairOfTagAndAddress() {
        var marks = ReplayMarks(cap: 2)
        let tags = ["t1", "t2", "t3"].map(BlindFixture.id)
        let here = RadioAddress("AA")
        marks.mark(tags[0], at: here)
        #expect(marks.replayed(tags[0], at: here))
        #expect(!marks.replayed(tags[0], at: RadioAddress("BB")), "the owner's own address")
        #expect(!marks.replayed(tags[0], at: nil))
        marks.mark(tags[1], at: here)
        marks.mark(tags[2], at: here)
        #expect(!marks.replayed(tags[0], at: here), "bounded, the oldest out first")
    }

    /// `DialPlan.suppressed` (`DialPlan.kt:43-55`) with this port's hint row: each answer holds off a dial only through the
    /// link it names, read against the links when the dial is decided.
    @Test func eachAnswerHoldsOffADialOnlyThroughTheLinkItNames() {
        let linked: Set<NodeId> = [bbb]
        let peer = bbb
        let held: (NodeId) -> String? = { $0 == peer ? "now" : nil }
        #expect(Suppressor<String>.linked.suppressed(id: bbb, linked: linked, proven: [], held: held), "a clear advert: any link")
        #expect(!Suppressor<String>.proven.suppressed(id: bbb, linked: linked, proven: [], held: held), "a key: only a proven link")
        #expect(Suppressor<String>.proven.suppressed(id: bbb, linked: linked, proven: linked, held: held))
        #expect(Suppressor.claim("now").suppressed(id: bbb, linked: linked, proven: linked, held: held), "the claimant's link is held")
        #expect(
            !Suppressor.claim("before").suppressed(id: bbb, linked: linked, proven: linked, held: held),
            "a relinked Sybil holds off nothing")
        #expect(Suppressor.hint("now").suppressed(id: bbb, linked: linked, proven: linked, held: held), "this port: the hint's own link")
        #expect(!Suppressor.hint("before").suppressed(id: bbb, linked: linked, proven: linked, held: held))
        #expect(!Suppressor<String>.never.suppressed(id: bbb, linked: linked, proven: linked, held: held), "an unresolved form: never")
    }
}
