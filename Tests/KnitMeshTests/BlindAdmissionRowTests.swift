import KnitWire
import Testing

@testable import KnitMesh

/// The blinding admission rows, ported from the `RefuseHeld`, `RefuseLegacy` and `heldQuiet` cases of knit-next's
/// `BleAdmissionPolicyTest` at `cad69c77b` (ADR 2026-11.prsp): ``AdvertOrder/heldLinkRow(_:addressed:honoured:heldProven:heldQuiet:heldDoorbell:)``
/// and ``AdvertOrder/refusesLegacy(_:readsTags:)``. Where the table then sends the dialer is `LinkManager`'s, pinned on
/// `LinkRig` in `BlindWriterAdmissionTests`.
@Suite struct BlindAdmissionRowTests {
    static let me = LinkRig.high
    static let myTag = AdvertForm.tag(prefixing: 1, 1)
    static let myPreviousTag = AdvertForm.tag(prefixing: 2, 2)
    static let contactTag = AdvertForm.tag(prefixing: 3, 3)
    static let reader = AdvertOrder.Mine.clear(me)
    static let blinding = AdvertOrder.Mine(current: BlindFixture.blinded(myTag), previous: BlindFixture.blinded(myPreviousTag))

    static func heldRow(
        _ mine: AdvertOrder.Mine, addressed: NodeId?, honoured: Bool = true, heldProven: Bool = true, heldQuiet: Bool = false,
        heldDoorbell: Bool = false
    ) -> Bool {
        AdvertOrder.heldLinkRow(
            mine, addressed: addressed?.bytes, honoured: honoured, heldProven: heldProven, heldQuiet: heldQuiet, heldDoorbell: heldDoorbell)
    }

    @Test func theHeldLinkRowNeverFiresWhileMineIsClear() {
        // Every clear dial carries `a` = my id: a row on "a names mine" would take 6es2's replace away.
        #expect(!Self.heldRow(Self.reader, addressed: Self.me))
        #expect(!Self.reader.blinded)
    }

    @Test func theHeldLinkRowRefusesADialerWhoseAddressedFormIsABlindedOneOfMine() {
        #expect(Self.blinding.blinded)
        #expect(Self.heldRow(Self.blinding, addressed: Self.myTag))
        #expect(Self.heldRow(Self.blinding, addressed: Self.myPreviousTag), "my previous tag too")
        #expect(!Self.heldRow(Self.blinding, addressed: Self.contactTag), "a form not mine")
        #expect(!Self.heldRow(Self.blinding, addressed: nil), "no `a`")
        #expect(!Self.heldRow(Self.blinding, addressed: Self.myTag, honoured: false), "not honoured")
        #expect(!Self.heldRow(Self.blinding, addressed: Self.myTag, heldProven: false), "an unproven held link")
        #expect(!Self.heldRow(Self.blinding, addressed: Self.myTag, heldQuiet: true), "a quiet held link reaches the replace")
        #expect(!Self.heldRow(Self.blinding, addressed: Self.myTag, heldDoorbell: true), "a doorbell link never takes it")
        // Clear now, blinded before: a dial made against my previous tag still takes the row.
        let flipped = AdvertOrder.Mine(current: .clear(Self.me), previous: BlindFixture.blinded(Self.myPreviousTag))
        #expect(Self.heldRow(flipped, addressed: Self.myPreviousTag))
        #expect(!Self.heldRow(flipped, addressed: Self.me))
    }

    @Test func whileBlindingADialerThatReadsNoTagsIsRefusedFirst() {
        #expect(AdvertOrder.refusesLegacy(Self.blinding, readsTags: false))
        #expect(!AdvertOrder.refusesLegacy(Self.blinding, readsTags: true), "a tag-aware dialer")
        #expect(!AdvertOrder.refusesLegacy(Self.reader, readsTags: false), "never while I air my id")
        let flipped = AdvertOrder.Mine(current: .clear(Self.me), previous: BlindFixture.blinded(Self.myPreviousTag))
        #expect(!AdvertOrder.refusesLegacy(flipped, readsTags: false), "nor once I air it again")
    }

    @Test func aForgedDialOnALiveProvenHeldLinkIsRefusedAndOnceQuietIsNot() {
        // The security pass: a forged dial claiming X, X's link proven and held. While the held link is not quiet the row
        // refuses; once quiet, the dial reaches the table, whose replace waits for the dialer's proof (R2, R3).
        let mine = AdvertOrder.Mine(current: BlindFixture.blinded(Self.myTag), previous: nil)
        #expect(Self.heldRow(mine, addressed: Self.myTag, heldQuiet: false))
        #expect(!Self.heldRow(mine, addressed: Self.myTag, heldQuiet: true))
    }
}
