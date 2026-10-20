import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Add contact: our code and link, a scanned code, and a link someone sent (ADR 2026-10.tpr5).
@MainActor
@Suite struct AddContactTests {
    /// `person`'s contact link, as their phone would share it.
    private static func link(of person: Person, name: String = "") -> String {
        ContactCard.encode(person.keys, name: name, issuedAt: 1_790_000_000_000)?.url ?? ""
    }

    // MARK: Our code and link

    @Test func ourCodeIsTheKnitIdCodeEveryScannerReads() {
        let rig = AppRig()
        #expect(AddContactModel(session: rig.session).ownCode == VerifyPayload.encode(AppRig.me.bundle))
    }

    @Test func ourLinkNamesUsAndIsSharedWithItsMessage() async throws {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        #expect(model.shareText == nil, "nothing to share before it is signed")
        await model.signLink()
        let link = try #require(model.link)
        guard case .card(let card) = ContactCard.parse(link.url) else {
            Issue.record("our link does not parse")
            return
        }
        #expect(card.nodeId == AppRig.me.nodeId)
        #expect(card.bundle == AppRig.me.bundle.encoded)
        #expect(model.shareText == Copy.AddContact.shareText(link.url))
        #expect(model.linkURL == link.url)
        #expect(AddContactModel.isContactLink(link.url))
        #expect(AddContactModel.isContactLink(link.scheme))
    }

    // MARK: A link someone sent

    @Test func aLinkPreviewsThePersonWithTheSafetyNumberBothPhonesRead() throws {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam, name: "Sam"))
        let preview = try #require(model.preview)
        #expect(model.problem == nil)
        #expect(preview.nodeId == AppRig.sam.nodeId)
        #expect(preview.title == "Sam")
        #expect(preview.alias == Alias.alias(for: AppRig.sam.nodeId.string))
        #expect(preview.safetyNumber.joined(separator: " ") == SafetyNumber.compute(mine: AppRig.me.bundle, theirs: AppRig.sam.bundle))
        #expect(!preview.isContact)
        #expect(!preview.isBlocked)
        #expect(rig.mesh.contactCalls.isEmpty, "a preview writes nothing")
    }

    @Test func aLinkInsideTheMessageItCameInStillReads() {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(Copy.AddContact.shareText(Self.link(of: AppRig.sam, name: "Sam")))
        #expect(model.preview?.nodeId == AppRig.sam.nodeId)
    }

    @Test func aLinkWithNoNameShowsTheirAlias() {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam))
        #expect(model.preview?.title == Alias.alias(for: AppRig.sam.nodeId.string))
    }

    @Test func theNameKnitHoldsOutranksTheLinks() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam, name: "Not Sam"))
        #expect(model.preview?.title == "Sam")
    }

    @Test(arguments: ["hello", "", "https://getknit.app/c#omRib2R5", "knit://r/abc"])
    func whatIsNoLinkSaysSo(text: String) {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(text)
        #expect(model.preview == nil)
        #expect(model.problem == .notALink)
    }

    @Test func ourOwnLinkSaysSo() {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.me))
        #expect(model.preview == nil)
        #expect(model.problem == .ownLink)
    }

    /// A row whose key is not the one the link carries: the link is refused before anything is written.
    @Test func aLinkWhoseKeyIsNotThePinnedOneIsAMismatch() async {
        let rig = AppRig()
        rig.stores.peers.upsert(
            PeerRecord(nodeId: AppRig.sam.nodeId, name: "Sam", status: "", publicKey: AppRig.priya.bundle.encoded, updatedAt: 1))
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam))
        #expect(model.preview == nil)
        #expect(model.problem == .mismatch(name: "Sam"))
    }

    @Test func addingThemMakesThemAContactAndOpensThem() async throws {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam, name: "Sam"))
        #expect(try #require(model.preview).isContact == false)
        let opened = await model.confirm()
        #expect(opened == AppRig.sam.nodeId)
        #expect(model.preview == nil)
        #expect(model.input.isEmpty)
        #expect(rig.mesh.contactCalls == ["link \(AppRig.sam.nodeId)"])
        let contact = try #require(NewMessageModel(session: rig.session).candidates.first { $0.id == AppRig.sam.nodeId })
        #expect(contact.label == "Sam")
        #expect(!contact.isVerified, "a link never verifies")
        model.lookup(Self.link(of: AppRig.sam, name: "Sam"))
        #expect(model.preview?.isContact == true)
    }

    @Test func aBlockedPersonIsUnblockedAsTheyAreAdded() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.session.block(AppRig.sam.nodeId)
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam))
        #expect(try #require(model.preview).isBlocked)
        #expect(await model.confirm() == AppRig.sam.nodeId)
        #expect(rig.mesh.contactCalls == ["link \(AppRig.sam.nodeId) unblocking"])
        #expect(!rig.session.directory.blocked.contains(AppRig.sam.nodeId))
    }

    @Test func aPinThatDidNotLandSaysSoOnceThePreviewHasGone() async {
        let rig = AppRig()
        rig.mesh.refusesContacts()
        let model = AddContactModel(session: rig.session)
        model.lookup(Self.link(of: AppRig.sam))
        #expect(await model.confirm() == nil)
        #expect(model.problem == nil, "not while the preview is going")
        model.previewClosed()
        #expect(model.problem == .failed)
    }

    // MARK: Scanning their code

    @Test func theirCodeAddsThemVerified() async throws {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.sam.bundle)) == .added)
        #expect(rig.mesh.contactCalls == ["scan \(AppRig.sam.nodeId)"])
        let contact = try #require(NewMessageModel(session: rig.session).candidates.first { $0.id == AppRig.sam.nodeId })
        #expect(contact.isVerified)
    }

    @Test func theirCardScansAsWellAsTheirCode() async {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        #expect(await model.scanned(Self.link(of: AppRig.sam, name: "Sam")) == .added)
        #expect(rig.session.directory.verified.contains(AppRig.sam.nodeId))
    }

    @Test func aScannedKeyThatIsNotThePinnedOneIsAMismatch() async {
        let rig = AppRig()
        rig.stores.peers.upsert(
            PeerRecord(nodeId: AppRig.sam.nodeId, name: "Sam", status: "", publicKey: AppRig.priya.bundle.encoded, updatedAt: 1))
        let model = AddContactModel(session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.sam.bundle)) == .mismatch)
        #expect(!rig.session.directory.verified.contains(AppRig.sam.nodeId))
    }

    @Test func scanningOurOwnCodeSaysSoAndAsksNothingOfTheMesh() async {
        let rig = AppRig()
        let model = AddContactModel(session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.me.bundle)) == .ownCode)
        #expect(rig.mesh.contactCalls.isEmpty)
    }

    @Test(arguments: ["hello", "", " knit-id:v1:x:y"])
    func whatIsNoCodeSaysSo(text: String) async {
        let rig = AppRig()
        #expect(await AddContactModel(session: rig.session).scanned(text) == .notACode)
        #expect(rig.mesh.contactCalls.isEmpty)
    }

    @Test func everyOutcomeHasItsOwnWords() {
        let words = AddContactScanOutcome.allCases.map(Copy.AddContact.scanOutcome)
        #expect(Set(words).count == words.count)
        let problems: [AddContactProblem] = [.notALink, .ownLink, .mismatch(name: "Sam"), .failed]
        #expect(Set(problems.map(Copy.AddContact.problem)).count == problems.count)
    }
}
