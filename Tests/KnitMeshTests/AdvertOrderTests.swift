import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertOrder`` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t), ported case for case from `AdvertOrderTest.kt` at
/// `cad69c77b` but for `theAwareChaseTakesEveryForeignIdWhileBlinding`, whose `initiable` this port has no Wi-Fi Aware to
/// need. The two-phone simulation pairs every build a mixed mesh holds (a shipped build, a reader that airs its id, and a
/// blinding writer) over seeded ids and tags, and walks the rotation edges.
@Suite struct AdvertOrderTests {
    private typealias Form = AdvertOrder.Form

    private enum Build: CaseIterable { case old, reader, writer }

    /// One phone: its real id and, for a writer, its tags oldest first (the last is the one on air).
    private struct Phone {
        let build: Build
        let id: NodeId
        var tags: [NodeId] = []

        func form(age: Int = 0) -> Form {
            build == .writer ? Form(advertised: tags[tags.count - 1 - age], blinded: true) : .clear(id)
        }

        var current: Form { form() }
        var previous: Form? { build == .writer && tags.count > 1 ? form(age: 1) : nil }

        /// Whether this phone's ordinary dial goes to `seen`. A shipped build reads bytes 1–16 as an id, flag unread.
        func dials(_ seen: Form) -> Bool {
            build == .old ? seen.advertised < id : AdvertOrder.iDial(current, seen)
        }
    }

    private static let pairs = 200
    private static let slots: UInt64 = 1_000_000

    private var random = SeededGenerator(seed: 285)
    private var fixture = BlindFixture()

    private mutating func id() -> NodeId {
        required(NodeId(bytes: (0..<NodeId.byteCount).map { _ in UInt8.random(in: 0...UInt8.max, using: &random) }))
    }

    private mutating func tag() -> NodeId {
        let key = fixture.key()
        let slot = Int64(random.next() % Self.slots)
        return BlindFixture.tag(key, owner: required(NodeId(bytes: [UInt8](repeating: 0, count: NodeId.byteCount))), slot: slot)
    }

    private mutating func phone(_ build: Build, tags: Int = 2) -> Phone {
        let id = id()
        return Phone(build: build, id: id, tags: build == .writer ? (0..<tags).map { _ in tag() } : [])
    }

    /// Whether `dialer`'s dial to `responder`, made against the form it saw, links: a shipped build expects the dialed form
    /// back as the HELLO's id, so its dial to a tag fails; a blinding responder refuses a dialer that cannot read tags; any
    /// other responder refuses only a sighted dialer it should have dialed itself, judged on the HELLO's `a` and `t`.
    private static func lands(_ dialer: Phone, _ responder: Phone, seen: Form) -> Bool {
        if dialer.build == .old, seen.blinded {
            return false
        }
        if responder.build == .writer, dialer.build == .old {
            return false
        }
        switch responder.build {
        case .old:
            return dialer.build == .writer || responder.id < dialer.id
        case .reader, .writer:
            let told = dialer.build == .old ? nil : dialer.current.advertised.bytes
            return !AdvertOrder.responderShouldHaveDialed(
                current: responder.current,
                previous: responder.previous,
                dialed: dialer.build == .old ? nil : seen.advertised,
                dialer: .fromHello(dialer.id, told: told)
            )
        }
    }

    @Test func theRuleFromOneSide() {
        let small = Form.clear(BlindFixture.form("aaaa"))
        let large = Form.clear(BlindFixture.form("mmmm"))
        let tagLow = Form(advertised: BlindFixture.form("zzzzb"), blinded: true)
        let tagHigh = Form(advertised: BlindFixture.form("zzzzq"), blinded: true)
        #expect(AdvertOrder.iDial(large, small), "two clear ids: the larger dials")
        #expect(!AdvertOrder.iDial(small, large))
        #expect(AdvertOrder.iDial(tagLow, large), "a blinding phone dials every clear advert")
        #expect(!AdvertOrder.iDial(large, tagLow), "a clear phone leaves a blinded advert to dial it")
        #expect(AdvertOrder.iDial(tagHigh, tagLow), "two tags: the larger dials")
        #expect(!AdvertOrder.iDial(tagLow, tagHigh))
        #expect(!AdvertOrder.iDial(large, large), "equal forms never dial")
        #expect(!AdvertOrder.iDial(tagLow, tagLow))
    }

    @Test mutating func aClearIdAboveTheTagStillLeavesTheDialToTheBlindingSide() {
        // About 2⁻²⁰ of real ids sort above a tag. Comparing strings there would have both sides dial and each responder
        // refuse the other's dial as out of order, for good.
        let zid = Form.clear(BlindFixture.form(String(repeating: "z", count: NodeId.length - 1) + "y"))
        let tag = Form(advertised: tag(), blinded: true)
        #expect(tag.advertised < zid.advertised)
        #expect(AdvertOrder.iDial(tag, zid))
        #expect(!AdvertOrder.iDial(zid, tag))
        #expect(
            !AdvertOrder.responderShouldHaveDialed(current: zid, previous: nil, dialed: zid.advertised, dialer: tag),
            "the blinding dial passes the responder's check")
    }

    @Test mutating func exactlyOneSideLinksEveryPairOfBuilds() {
        for _ in 0..<Self.pairs {
            for first in Build.allCases {
                for second in Build.allCases {
                    let one = phone(first)
                    let other = phone(second)
                    let oneLinks = one.dials(other.current) && Self.lands(one, other, seen: other.current)
                    let otherLinks = other.dials(one.current) && Self.lands(other, one, seen: one.current)
                    #expect(oneLinks != otherLinks, "\(first)↔\(second): exactly one dial links")
                    if first != .old, second != .old {
                        #expect(one.dials(other.current) != other.dials(one.current), "\(first)↔\(second): exactly one side dials")
                    }
                }
            }
        }
    }

    @Test mutating func aShippedBuildsDialToAZzzzTagIsTheOnlyDoubleDialAndItFails() {
        let old = Phone(build: .old, id: BlindFixture.form(String(repeating: "z", count: NodeId.length - 1) + "y"))
        let writer = phone(.writer)
        #expect(old.dials(writer.current), "it reads the tag as a smaller id and dials it")
        #expect(!Self.lands(old, writer, seen: writer.current), "WrongPeer: the HELLO names the writer's real id")
        #expect(writer.dials(old.current) && Self.lands(writer, old, seen: old.current), "the writer's own dial links the pair")
    }

    @Test mutating func aRotationEdgeCanMakeBothOrNeitherDialAndTheDialedFormKeepsEveryDialThatIsMade() {
        var both = 0
        var neither = 0
        var refusedOnCurrentForms = 0
        for _ in 0..<(Self.pairs * 4) {
            for other in [Build.writer, .reader] {
                let one = phone(.writer)
                let two = phone(other)
                // Each side may still see the other's previous form: its scan has not yet heard the rotation.
                let oneSees = Bool.random(using: &random) ? two.previous ?? two.current : two.current
                let twoSees = Bool.random(using: &random) ? one.previous ?? one.current : one.current
                let oneDials = one.dials(oneSees)
                let twoDials = two.dials(twoSees)
                if oneSees == two.current, twoSees == one.current {
                    #expect(oneDials != twoDials, "fresh views: exactly one dials")
                }
                both += oneDials && twoDials ? 1 : 0
                neither += !oneDials && !twoDials ? 1 : 0
                let made = [(one, two, oneSees, oneDials), (two, one, twoSees, twoDials)].filter(\.3)
                for (dialer, responder, seen, _) in made {
                    #expect(Self.lands(dialer, responder, seen: seen), "judged on the form it dialed, a dial made in order is admitted")
                    let dialerForm = Form.fromHello(dialer.id, told: dialer.current.advertised.bytes)
                    refusedOnCurrentForms += AdvertOrder.iDial(responder.current, dialerForm) ? 1 : 0
                }
            }
        }
        // Both dialing gives two links, settled by the responder's held-link row; neither dialing lasts until a scan hears
        // the current form, after which exactly one dials.
        #expect(both > 0, "a stale view can have both dial")
        #expect(neither > 0, "a stale view can have neither dial")
        #expect(refusedOnCurrentForms > 0, "judged on current forms alone, some good dials would be refused")
    }

    @Test mutating func theDialedFormIsHonouredOnlyForMyCurrentOrPreviousForm() throws {
        let writer = phone(.writer, tags: 3)
        let gone = writer.form(age: 2)
        let previous = try #require(writer.previous)
        #expect(AdvertOrder.dialedForm(current: writer.current, previous: previous, dialed: writer.current.advertised) == writer.current)
        #expect(AdvertOrder.dialedForm(current: writer.current, previous: previous, dialed: previous.advertised) == previous)
        #expect(AdvertOrder.dialedForm(current: writer.current, previous: previous, dialed: gone.advertised) == nil, "two rotations back")
        #expect(AdvertOrder.dialedForm(current: writer.current, previous: previous, dialed: tag()) == nil, "not mine")
        #expect(AdvertOrder.dialedForm(current: writer.current, previous: previous, dialed: nil) == nil, "no a")
        // Not honoured: judged against my current form.
        let dialer = Form(advertised: BlindFixture.form("zzzz"), blinded: true)
        #expect(
            AdvertOrder.iDial(writer.current, dialer)
                == AdvertOrder.responderShouldHaveDialed(
                    current: writer.current, previous: previous, dialed: gone.advertised, dialer: dialer))
    }

    @Test mutating func aFormPrintsNoTagOrId() {
        let tag = tag()
        let id = BlindFixture.form("abcdefghij")
        let printed = Form(advertised: tag, blinded: true).description + Form.clear(id).description
        #expect(!printed.contains(tag.string.dropFirst(4).prefix(6)))
        #expect(!printed.contains("efghij"))
    }

    @Test func theDialersFormComesFromItsHello() {
        let abc = BlindFixture.form("abc")
        let tag = BlindFixture.form("zzzzq")
        #expect(Form.fromHello(abc, told: nil) == .clear(abc))
        #expect(Form.fromHello(abc, told: abc.bytes) == .clear(abc), "a t equal to the id is a clear advert")
        #expect(Form.fromHello(abc, told: tag.bytes) == Form(advertised: tag, blinded: true))
    }

    @Test mutating func theLonelyDialGoesOnlyWhereTheOrderLeavesTheDialToThePeer() {
        for _ in 0..<Self.pairs {
            for first in [Build.reader, .writer] {
                for second in Build.allCases {
                    let one = phone(first)
                    let other = phone(second)
                    #expect(!one.dials(other.current) == AdvertOrder.lonelyMayDial(one.current, other.current))
                }
            }
        }
        let abc = Form.clear(BlindFixture.form("abc"))
        #expect(!AdvertOrder.lonelyMayDial(abc, abc), "never my own form")
        let reader = phone(.reader)
        let writer = phone(.writer)
        #expect(AdvertOrder.lonelyMayDial(reader.current, writer.current), "a lonely reader dials a writer by tag")
        // As for every lonely dial: a responder that sights the dialer refuses it, judged on `a` and `t`, and its own
        // ordinary dial is on the way.
        #expect(!Self.lands(reader, writer, seen: writer.current), "a writer that sights the reader refuses it")
        #expect(writer.dials(reader.current) && Self.lands(writer, reader, seen: reader.current), "and dials it itself")
        #expect(!AdvertOrder.lonelyMayDial(writer.current, reader.current), "a writer already dials a reader")
    }

    @Test mutating func aShippedBuildsLonelyDialPicksAWritersTagAndFails() {
        let old = phone(.old)
        let writer = phone(.writer)
        #expect(old.id < writer.current.advertised, "the shipped lonely rule picks the tag")
        #expect(!Self.lands(old, writer, seen: writer.current), "WrongPeer: the HELLO names the writer's real id")
        #expect(writer.dials(old.current) && Self.lands(writer, old, seen: old.current), "the writer dials the old phone instead")
    }

    @Test mutating func theRoleWalkWithMyFormsBlinded() throws {
        let mine = AdvertOrder.Mine(current: Form(advertised: tag(), blinded: true), previous: Form(advertised: tag(), blinded: true))
        for _ in 0..<50 {
            let clear = Form.clear(id())
            // Ordinary dial: every clear advert, whatever the id order (a tag sorts above them all).
            #expect(AdvertOrder.iDial(mine.current, clear))
            // Lonely dial: never to a clear advert (I dial those anyway).
            #expect(!AdvertOrder.lonelyMayDial(mine.current, clear))
            // The responder: a clear dialer is one I should have dialed.
            #expect(AdvertOrder.responderShouldHaveDialed(current: mine.current, previous: mine.previous, dialed: nil, dialer: clear))
            // Two blinded adverts: exactly one side dials, the larger tag; the lonely dial only toward the larger one.
            let theirs = Form(advertised: tag(), blinded: true)
            #expect(AdvertOrder.iDial(mine.current, theirs) != AdvertOrder.iDial(theirs, mine.current))
            #expect(!AdvertOrder.iDial(mine.current, theirs) == AdvertOrder.lonelyMayDial(mine.current, theirs))
        }
        // A dial made against my previous tag is judged as the dialer saw it.
        let previous = try #require(mine.previous)
        #expect(AdvertOrder.dialedForm(current: mine.current, previous: previous, dialed: previous.advertised) == previous)
    }

    /// This port's own form: clear for good, so it never dials a blinded advert by the order (ADR 2026-11.sv5t).
    @Test mutating func aClearPhoneNeverDialsABlindedAdvertByTheOrder() {
        let mine = AdvertOrder.Mine.clear(id())
        for _ in 0..<50 {
            #expect(!AdvertOrder.iDial(mine.current, Form(advertised: tag(), blinded: true)))
        }
    }
}

/// The responder's order check on advertised forms (`BleAdmissionPolicyTest.kt:340-418` at knit-next `cad69c77b`, the
/// reader's rows): ``AdvertOrder/outOfOrder(_:dialer:told:addressed:honoured:)`` and its gate. The held-link and legacy
/// rows that follow there are a blinding phone's, which this port is not (ADR 2026-11.sv5t).
@Suite struct ResponderOrderTests {
    private let low = LinkRig.low
    private let high = LinkRig.high
    private let reader = AdvertOrder.Mine.clear(LinkRig.high)
    private let contactTag: NodeId
    // A garbage `t`: a canonical form other than the dialer's id, without the tag prefix.
    private let garbage = BlindFixture.form("bbbbbbbbbbbbbbbbbbbbbbbbb")

    init() {
        let key = required(PresenceKey(bytes: [UInt8](repeating: 7, count: PresenceKey.byteCount)))
        contactTag = BlindFixture.tag(key, owner: required(NodeId(bytes: [UInt8](repeating: 0, count: NodeId.byteCount))), slot: 1)
    }

    private func outOfOrder(
        mine: AdvertOrder.Mine? = nil, dialer: NodeId? = nil, told: NodeId? = nil, addressed: NodeId? = nil, honoured: Bool = true
    ) -> Bool {
        AdvertOrder.outOfOrder(mine ?? reader, dialer: dialer ?? low, told: told?.bytes, addressed: addressed?.bytes, honoured: honoured)
    }

    @Test func aReaderAdmitsABlindingContactsProvenDialThoughItsRealIdSortsBelowAndItIsSighted() {
        #expect(
            !outOfOrder(told: contactTag, addressed: high),
            "a clear phone never dials a blinded advert, so it should not have dialed this one")
    }

    @Test func aDialerWithNoTOrAIsJudgedExactlyAsToday() {
        #expect(outOfOrder())
        #expect(!outOfOrder(mine: .clear(low), dialer: high))
        #expect(outOfOrder(addressed: high), "a clear dial carries a = the id it dialed (mine): the same answer")
        #expect(outOfOrder(addressed: low), "an a naming no form of mine is not honoured")
    }

    @Test func aNoProofDialerClaimingASightedSmallerIdWithATagIsStillRefused() {
        // The security pass's Blocking case (knit-next #275): `t` and `a` count only on a HELLO that offers a proof.
        #expect(outOfOrder(told: contactTag, addressed: high, honoured: false))
    }

    @Test func theHelloFieldsAreHonouredOnTheFirstPassOnlyWithAProofOfferedAndOnTheLateOnlyWhenProven() {
        // One row of the gate: whether the HELLO offered a proof, whether it proved, which pass, and the answer.
        struct Row {
            let offersProof: Bool
            let proven: Bool
            let late: Bool
            let honoured: Bool
        }
        let rows = [
            Row(offersProof: false, proven: false, late: false, honoured: false),
            Row(offersProof: true, proven: false, late: false, honoured: true),
            Row(offersProof: true, proven: false, late: true, honoured: false),
            Row(offersProof: true, proven: true, late: true, honoured: true),
            Row(offersProof: false, proven: false, late: true, honoured: false),
            // A late pass is never reached proven without the offer; read on `proven` alone, it stays honest.
            Row(offersProof: false, proven: true, late: true, honoured: true),
            Row(offersProof: false, proven: true, late: false, honoured: false),
            Row(offersProof: true, proven: true, late: false, honoured: true),
        ]
        for row in rows {
            #expect(AdvertOrder.honours(offersProof: row.offersProof, proven: row.proven, late: row.late) == row.honoured, "\(row)")
        }
        // And what it guards: a no-proof dialer's tag `t` never skips "we dial it".
        #expect(
            outOfOrder(told: contactTag, addressed: high, honoured: AdvertOrder.honours(offersProof: false, proven: false, late: false)))
    }

    @Test func aGarbageToldIsJudgedClear() {
        #expect(outOfOrder(told: garbage), "a prefixless t is absent")
        #expect(outOfOrder(told: low), "a t equal to the id is clear")
    }
}
