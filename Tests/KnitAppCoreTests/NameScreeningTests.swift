import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Names, statuses and group names under the name screen (knit-next ADR 2026-11.y4pc): drawn blank while the content
/// filter is on, so a person shows their alias, a group its members' title and a status nothing; never ours; and as
/// they arrived in a report (ADR 2026-10.f6kf). `PeerLabelsTest`, `PeerRepositoryTest` and `ConversationFacesTest`
/// in knit-next.
@MainActor
@Suite struct NameScreeningTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// A screen with one slur and one profanity term, each looked for inside words too.
    static func names() -> ShownNames {
        ShownNames(
            screen: NameScreen(
                slurs: ["pikey"], profanity: ["fuck", "pikey"], embeddable: ["fuck", "pikey"], exclusions: [], allowedNames: []))
    }

    private func alias(_ person: Person) -> String {
        Alias.alias(for: person.nodeId.string)
    }

    // MARK: People

    @Test func aFlaggedNameShowsTheAliasWhileTheFilterIsOnAndInFullWhenItIsOff() async {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Fuck69")
        #expect(rig.session.directory.label(for: sam.nodeId).name == alias(sam))
        rig.session.filtersContent = false
        #expect(rig.session.directory.label(for: sam.nodeId).name == "Fuck69", "the toggle relabels at once")
        rig.session.filtersContent = true
        #expect(rig.session.directory.label(for: sam.nodeId).text == alias(sam))
    }

    @Test func twoFlaggedPeopleStayApartAndAPlainNameKeepsItsOwn() async {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Fuck69")
        await rig.pin(priya, name: "fuck_lord")
        await rig.pin(stranger, name: "Ada")
        let directory = rig.session.directory
        let labels = [sam, priya].map { directory.label(for: $0.nodeId) }
        #expect(labels.map(\.name) == [alias(sam), alias(priya)])
        #expect(labels[0].text != labels[1].text)
        #expect(directory.label(for: stranger.nodeId).text == "Ada")
    }

    @Test func aRawNameACallerHoldsLabelsAsTheIndexWouldAndOursNeverHides() async {
        let rig = AppRig(names: Self.names())
        await rig.session.updateProfile(name: "Fuck69", status: "", openToChat: false)
        let labels = rig.session.directory.labels
        #expect(labels.label(for: stranger.nodeId.string, storedName: "Fuck69").name == alias(stranger), "an id outside the index")
        #expect(labels.label(for: rig.me.string, storedName: "Fuck69").name == "Fuck69")
        #expect(rig.session.directory.label(for: rig.me).name == "Fuck69", "our own name shows as we set it")
    }

    @Test func withNoScreenNothingIsHidden() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Fuck69")
        #expect(rig.session.directory.label(for: sam.nodeId).name == "Fuck69")
    }

    @Test func aFlaggedStatusShowsNothingOnTheProfileAndOursShows() async {
        let rig = AppRig(names: Self.names())
        rig.stores.peers.upsert(sam.record(name: "Sam", status: "fuck mondays"))
        await rig.session.handle(.peerUpdated(sam.nodeId))
        #expect(PeerProfileModel(nodeId: sam.nodeId, session: rig.session).state.status.isEmpty)
        rig.session.filtersContent = false
        #expect(PeerProfileModel(nodeId: sam.nodeId, session: rig.session).state.status == "fuck mondays")
    }

    @Test func aNotificationNamesAFlaggedSenderByTheirAlias() async throws {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Fuck69")
        await rig.receive("Anyone here?", from: sam.nodeId)
        let posted = try #require(rig.notifier.posted.first)
        #expect(posted.body == "\(alias(sam)): Anyone here?")
    }

    @Test func aContactLinksFlaggedNameShowsTheirAlias() {
        let rig = AppRig(names: Self.names())
        let model = AddContactModel(session: rig.session)
        model.lookup(ContactCard.encode(sam.keys, name: "Fuck69", issuedAt: 1_790_000_000_000)?.url ?? "")
        #expect(model.preview?.title == alias(sam))
    }

    // MARK: Groups

    @Test func aGroupNameReadsTheSlurListAloneAndHidesBehindItsMembersTitle() async {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        var group = await rig.group([sam, priya], createdBy: sam)
        let directory = rig.session.directory
        group.name = "Fuck Mondays"
        #expect(GroupNaming.title(of: group, me: rig.me, directory: directory) == "Fuck Mondays", "members read slurs alone")
        group.name = "Pikey club"
        #expect(GroupNaming.title(of: group, me: rig.me, directory: directory) == "Sam & Priya")
        // The screen reads what is drawn: a control inside the slur goes before it is read.
        group.name = "pi\u{202E}key club"
        #expect(GroupNaming.title(of: group, me: rig.me, directory: directory) == "Sam & Priya")
        let notice = StatusNotices.groupRenamed(group.id, by: sam.nodeId, to: "Pikey club", at: 1)
        #expect(
            GroupNaming.notice(notice, in: group, me: rig.me, directory: directory) == Copy.Groups.renamed(by: "Sam", to: "Sam & Priya"))
        rig.session.filtersContent = false
        #expect(GroupNaming.title(of: group, me: rig.me, directory: rig.session.directory) == "pikey club")
    }

    @Test func aRequestsRowReadsAStrangersGroupNameWithBothLists() async {
        let rig = AppRig(names: Self.names())
        let group = await rig.group([stranger, priya], name: "Fuck Mondays", createdBy: stranger)
        await rig.receive("Hello?", from: stranger.nodeId, in: group, sentAt: 2000)
        #expect(RequestsModel(session: rig.session).rows.first?.title == Copy.Groups.names([alias(stranger), alias(priya)]))
        #expect(GroupNaming.title(of: group, me: rig.me, directory: rig.session.directory) == "Fuck Mondays", "inside, as members")
    }

    // MARK: Ours, when it is set

    @Test func aFlaggedNameOrStatusIsRefusedWhateverTheFilterSaysAndNothingIsPublished() async {
        let rig = AppRig(names: Self.names(), preferences: MemoryPreferences(filtersContent: false))
        let model = OwnProfileModel(session: rig.session)
        model.name = "Fuck69"
        model.status = "fuck mondays"
        #expect(await !model.save())
        #expect(model.nameRefused && model.statusRefused)
        #expect(rig.mesh.calls.profiles.isEmpty)
        #expect(model.name == "Fuck69" && model.status == "fuck mondays", "what was typed stays")
        #expect(model.hasChanges)
        model.name = "Ada"
        #expect(!model.nameRefused && model.statusRefused, "editing a field clears its own note")
        #expect(await !model.save())
        model.status = "Hiking"
        #expect(await model.save())
        #expect(rig.mesh.calls.profiles == ["Ada|Hiking|false"])
    }

    @Test func withNoScreenOurNameIsNeverRefused() async {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session)
        model.name = "Fuck69"
        #expect(await model.save())
        #expect(rig.mesh.calls.profiles == ["Fuck69||false"])
    }

    @Test func theNamePageHoldsAFlaggedNameUntilItChanges() async {
        let rig = AppRig(names: Self.names())
        let model = OnboardingModel(session: rig.session, preferences: MemoryPreferences(), permission: FakePermission())
        model.next()
        model.next()
        model.name = "Fuck69"
        model.next()
        #expect(model.step == .name && model.nameRefused)
        model.name = "Ada"
        #expect(!model.nameRefused)
        model.next()
        #expect(model.step == .permissions)
        await model.finish()
        #expect(rig.mesh.calls.profiles.last == "Ada||false")
    }

    /// The refusal notes' identifiers: Android's tag for onboarding's, and the iPhone's own for the profile's, whose
    /// refusal Android shows in a snackbar with none.
    @Test func theRefusalNotesIdentifiersAreAndroidsWhereItHasOne() {
        #expect(AccessibilityID.onboardingNameRefused == "onboarding_name_refused")
        #expect(AccessibilityID.profileNameRefused == "profile_name_refused")
        #expect(AccessibilityID.profileStatusRefused == "profile_status_refused")
    }

    // MARK: Reports

    @Test func aReportCarriesTheNameAndStatusTheFilterHid() async throws {
        let rig = AppRig(names: Self.names())
        rig.stores.peers.upsert(sam.record(name: "Fuck69", status: "fuck mondays"))
        await rig.session.handle(.peerUpdated(sam.nodeId))
        let report = try #require(PeerProfileModel(nodeId: sam.nodeId, session: rig.session).reporting)
        #expect(report.name == alias(sam))
        #expect(report.hiddenName == "Fuck69")
        #expect(report.status == "fuck mondays")
        let email = ReportEmail(report, version: "1.0 (1)", now: Date(timeIntervalSince1970: 0))
        #expect(email.body.contains(Copy.Report.emailName("Fuck69")))
        rig.session.filtersContent = false
        #expect(PeerProfileModel(nodeId: sam.nodeId, session: rig.session).reporting?.hiddenName == nil, "nothing was hidden")
    }

    @Test func aReportOfSomeoneNotPinnedHasNoHiddenNameOrStatus() throws {
        let rig = AppRig(names: Self.names())
        let report = try #require(PeerProfileModel(nodeId: stranger.nodeId, session: rig.session).reporting)
        #expect(report.name == alias(stranger) && report.hiddenName == nil && report.status.isEmpty)
    }

    @Test func aReportFromAGroupNamesItAsItNamedItselfOrByItsMembers() async {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let group = await rig.group([sam, priya], createdBy: sam)
        #expect(GroupNaming.reportedTitle(of: group, me: rig.me, directory: rig.session.directory) == "Sam & Priya")
    }

    @Test func theRefusalsSayWhoSeesWhatWasRefused() {
        #expect(Copy.Moderation.nameRefused.contains("your name"))
        #expect(Copy.Moderation.statusRefused.contains("your status"))
    }

    @Test func aReportFromAGroupNamesItAsItNamedItself() async throws {
        let rig = AppRig(names: Self.names())
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let group = await rig.group([sam, priya], name: "Pikey club", createdBy: sam)
        rig.stores.conversations.accept(group.id)
        let message = await rig.receive("hi", from: sam.nodeId, in: group, sentAt: 2000)
        let chat = ChatModel(conversationId: group.id, session: rig.session)
        let row = try #require(chat.state.messages.first { $0.id == message.id })
        #expect(chat.reporting(row)?.place == .group("Pikey club"))
    }
}
