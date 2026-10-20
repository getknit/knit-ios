import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Another person's profile and the user's own (MVP item 3).
@MainActor
@Suite struct ProfileTests {
    @Test func aPinnedPeersProfileShowsTheSafetyNumberBothPhonesRead() async throws {
        let rig = AppRig()
        rig.stores.peers.upsert(AppRig.sam.record(name: "Sam", status: "At the gate", openToChat: true))
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        let state = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session).state
        #expect(state.title == "Sam")
        #expect(state.status == "At the gate")
        #expect(state.openToChat)
        #expect(state.alias == Alias.alias(for: AppRig.sam.nodeId.string))
        #expect(state.conversationId == AppRig.sam.nodeId.string)
        let number = try #require(state.safetyNumber)
        #expect(number.count == 2)
        #expect(number.joined(separator: " ") == SafetyNumber.compute(mine: AppRig.me.bundle, theirs: AppRig.sam.bundle))
        let theirView = SafetyNumber.compute(mine: AppRig.sam.bundle, theirs: AppRig.me.bundle)
        #expect(number.joined(separator: " ") == theirView, "the same number on either phone")
    }

    @Test func anUnpinnedPersonHasTheirAliasAndNoNumber() {
        let rig = AppRig()
        let state = PeerProfileModel(nodeId: AppRig.stranger.nodeId, session: rig.session).state
        #expect(state.safetyNumber == nil)
        #expect(state.title == Alias.alias(for: AppRig.stranger.nodeId.string))
        #expect(state.status.isEmpty)
        #expect(!state.isVerified)
    }

    @Test func verifyingAndClearingFollowTheStore() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(!model.isSelf)
        await model.setVerified(true)
        #expect(model.state.isVerified)
        await model.setVerified(false)
        #expect(!model.state.isVerified)
        #expect(rig.mesh.calls.verified == ["\(AppRig.sam.nodeId): true", "\(AppRig.sam.nodeId): false"])
    }

    // MARK: Scanning their code (ADR 2026-10.65xx)

    @Test func theProfileShowsOurOwnCodeForThemToScan() {
        let rig = AppRig()
        let state = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session).state
        #expect(state.ownCode == VerifyPayload.encode(AppRig.me.bundle))
    }

    @Test func theirCodeVerifiesThem() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.sam.bundle)) == .match)
        #expect(model.state.isVerified)
        #expect(rig.mesh.calls.verified == ["\(AppRig.sam.nodeId): true"])
    }

    /// A contact card compares as their code does (ADR 2026-10.tpr5), as Android's profile reads either form.
    @Test func theirContactCardVerifiesThemToo() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        let card = try #require(ContactCard.encode(AppRig.sam.keys, name: "Sam", issuedAt: 1))
        #expect(await model.scanned(card.url) == .match)
        #expect(model.state.isVerified)
    }

    @Test func someoneElsesCodeIsAMismatchAndVerifiesNoOne() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.priya.bundle)) == .mismatch)
        #expect(!model.state.isVerified)
        #expect(rig.mesh.calls.verified.isEmpty)
    }

    @Test func aMismatchLeavesAnEarlierVerificationAlone() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.priya.bundle)) == .mismatch)
        #expect(model.state.isVerified)
        #expect(rig.mesh.calls.verified.isEmpty)
    }

    /// Android's profile scan compares only, so a code for someone whose key has not pinned verifies nothing, even
    /// their own.
    @Test func anUnpinnedPersonsOwnCodeIsAMismatch() async {
        let rig = AppRig()
        let model = PeerProfileModel(nodeId: AppRig.stranger.nodeId, session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.stranger.bundle)) == .mismatch)
        #expect(rig.mesh.calls.verified.isEmpty)
    }

    @Test func ourOwnCodeSaysSo() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(await model.scanned(VerifyPayload.encode(AppRig.me.bundle)) == .ownCode)
        #expect(rig.mesh.calls.verified.isEmpty)
    }

    @Test(arguments: [
        "https://getknit.app/c#omRib2R5",
        "hello",
        "",
        " knit-id:v1:x:y",
    ])
    func whatIsNotAKnitCodeSaysSo(text: String) async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(await model.scanned(text) == .notACode)
        #expect(rig.mesh.calls.verified.isEmpty)
    }

    /// A code whose id is Sam's but whose bundle is Priya's: no key could have made it, so it is not a code at all.
    @Test func aCodeNoKeyCouldHaveMadeIsNotACode() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        let forged = VerifyPayload.prefix + AppRig.sam.nodeId.string + ":" + AppRig.priya.bundle.encoded
        #expect(await model.scanned(forged) == .notACode)
        #expect(!model.state.isVerified)
    }

    @Test func presenceFollowsTheLinks() async {
        let rig = AppRig()
        let model = PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session)
        #expect(!model.state.isLinked)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId)]))
        #expect(model.state.isLinked)
        #expect(PeerProfileModel(nodeId: rig.me, session: rig.session).isSelf)
    }

    @Test func aSafetyNumberSplitsIntoTwoLinesOfFour() {
        #expect(PeerProfileModel.lines("1 2 3 4 5 6 7 8") == ["1 2 3 4", "5 6 7 8"])
    }

    // MARK: Our own

    @Test func ourProfileLoadsWhatWasPublishedAndSavesItNormalized() async {
        let rig = AppRig()
        rig.stores.ownProfile.save(OwnProfile(name: "Old", status: "", openToChat: false))
        let model = OwnProfileModel(session: rig.session)
        #expect(model.name == "Old")
        #expect(!model.hasChanges)
        model.name = "  New   name "
        model.status = "Around\n"
        model.openToChat = true
        #expect(model.hasChanges)
        await model.save()
        #expect(rig.mesh.calls.profiles == ["New name|Around|true"])
        #expect(model.name == "New name")
        #expect(!model.hasChanges)
        #expect(model.alias == rig.session.identity.alias)
        #expect(model.nodeId == rig.me.string)
    }

    @Test func ourFieldsStopAtAndroidsLimitsAndCountDownNearThem() {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session)
        #expect(model.nameRemaining == nil)
        model.name = String(repeating: "n", count: 40)
        #expect(model.name.utf16.count == TextLimits.displayName)
        #expect(model.nameRemaining == 0)
        model.status = String(repeating: "s", count: 85)
        #expect(model.statusRemaining == 15)
        model.status = String(repeating: "s", count: 200)
        #expect(model.status.utf16.count == TextLimits.status)
    }
}
