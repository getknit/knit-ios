import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// `@everyone` in a group's composer (ADR 2026-10.jwst): the picker's first row, one mention for each other member on a
/// pick, and what Send keeps.
@MainActor
@Suite struct MentionEveryoneTests {
    /// Seven people past the two the rig names: with us, a full group of eight.
    private let crowd = (10...16).map { Person(seed: $0) }

    private func composing(_ text: String, in conversationId: String, rig: AppRig) -> ChatModel {
        let thread = ChatModel(conversationId: conversationId, session: rig.session)
        thread.draft = text
        thread.selection = text.utf16.count..<text.utf16.count
        return thread
    }

    /// A rig with `people` pinned and a full group of them, accepted.
    private func fullGroup(_ rig: AppRig, people: [Person]) async -> GroupRecord {
        for (index, person) in people.enumerated() {
            await rig.pin(person, name: "P\(index)")
        }
        let group = await rig.group(people, createdBy: people[0])
        rig.stores.conversations.accept(group.id)
        return group
    }

    // MARK: The row

    @Test func theRowIsFirstInAGroupAndOnlyThere() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        let group = await rig.group([AppRig.sam, AppRig.priya], createdBy: AppRig.sam)
        rig.stores.conversations.accept(group.id)
        let offered = composing("@", in: group.id, rig: rig).mentionCandidates
        #expect(offered.map(\.label.text) == ["everyone", "Priya", "Sam"])
        #expect(offered.map(\.isEveryone) == [true, false, false])
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("hello", from: AppRig.sam.nodeId, to: rig.me)
        #expect(composing("@", in: AppRig.sam.nodeId.string, rig: rig).mentionCandidates.map(\.isEveryone) == [false])
        await rig.receive("hi", from: AppRig.sam.nodeId)
        #expect(composing("@", in: Conversations.nearby, rig: rig).mentionCandidates.map(\.isEveryone) == [false])
    }

    @Test func theRowIsAbsentWhenNobodyElseIsLeft() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let group = await rig.group([AppRig.sam], createdBy: AppRig.sam)
        rig.stores.conversations.accept(group.id)
        #expect(composing("@", in: group.id, rig: rig).mentionCandidates.map(\.isEveryone) == [true, false])
        await rig.session.block(AppRig.sam.nodeId)
        #expect(composing("@", in: group.id, rig: rig).mentionCandidates.isEmpty)
    }

    /// The row reads the roster alone: someone who posted in the group and has left it is offered by name, never in
    /// `@everyone`.
    @Test func theRowNeverReadsSenders() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        let group = await rig.group([AppRig.sam], createdBy: AppRig.sam, departed: [AppRig.priya])
        rig.stores.conversations.accept(group.id)
        await rig.receive("bye", from: AppRig.priya.nodeId, in: group)
        let thread = composing("@", in: group.id, rig: rig)
        let row = thread.mentionCandidates.first
        #expect(row?.everyone == [AppRig.sam.nodeId.string])
        #expect(thread.mentionCandidates.map(\.label.text).contains("Priya"))
    }

    @Test func theRowMatchesWhenEveryoneStartsWithTheQuery() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        let group = await rig.group([AppRig.sam, AppRig.priya], createdBy: AppRig.sam)
        rig.stores.conversations.accept(group.id)
        let thread = composing("@", in: group.id, rig: rig)
        for text in ["@", "@e", "@ev", "@EVERYONE", "@Ever", "@everyone"] {
            thread.draft = text
            thread.selection = text.utf16.count..<text.utf16.count
            #expect(thread.mentionCandidates.first?.isEveryone == true, "\(text)")
        }
        for text in ["@x", "@one", "@everyonex", "@pri"] {
            thread.draft = text
            thread.selection = text.utf16.count..<text.utf16.count
            #expect(thread.mentionCandidates.first?.isEveryone != true, "\(text)")
        }
    }

    // MARK: A pick

    /// A full group: seven entries of one name, in ascending node id, and a second pick adds none.
    @Test func aPickMentionsEveryOtherMemberInOrder() async throws {
        let rig = AppRig()
        let group = await fullGroup(rig, people: crowd)
        let thread = composing("@ev", in: group.id, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.draft == "@everyone ")
        let ids = crowd.map(\.nodeId.string).sorted()
        #expect(thread.pendingMentions == ids.map { MessageMention(nodeId: $0, name: "everyone") })
        #expect(thread.pendingMentions.count == 7 && !thread.pendingMentions.map(\.nodeId).contains(rig.me.string))
        #expect(thread.chips == [0..<9])
        thread.draft += "@"
        thread.selection = thread.draft.utf16.count..<thread.draft.utf16.count
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.pendingMentions.count == 7)
    }

    @Test func aPickLeavesOutTheBlockedAndKeepsAHandPickBeside() async throws {
        let rig = AppRig()
        let group = await fullGroup(rig, people: crowd)
        await rig.session.block(crowd[0].nodeId)
        let thread = composing("@P1", in: group.id, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.pendingMentions == [MessageMention(nodeId: crowd[1].nodeId.string, name: "P1")])
        thread.draft += "@"
        thread.selection = thread.draft.utf16.count..<thread.draft.utf16.count
        thread.mention(try #require(thread.mentionCandidates.first))
        let names = thread.pendingMentions.map(\.name)
        #expect(names.filter { $0 == "everyone" }.count == 6 && names.contains("P1"))
        #expect(thread.pendingMentions.count == 7, "the blocked one is not mentioned, and P1 is listed twice")
        let everyone = thread.pendingMentions.filter { $0.name == "everyone" }.map(\.nodeId)
        #expect(!everyone.contains(crowd[0].nodeId.string) && everyone == everyone.sorted())
    }

    // MARK: Send

    @Test func sendCarriesEveryEntryWhileTheTokenStays() async throws {
        let rig = AppRig()
        let group = await fullGroup(rig, people: crowd)
        let thread = composing("@", in: group.id, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        thread.draft += "lunch?"
        await thread.send()
        let sent = try #require(rig.stores.messages.messages(in: group.id).last)
        #expect(sent.body == "@everyone lunch?" && sent.mentions.count == 7)
        #expect(thread.pendingMentions.isEmpty)
    }

    @Test func sendDropsEveryEntryOnceTheTokenIsEditedAway() async throws {
        let rig = AppRig()
        let group = await fullGroup(rig, people: crowd)
        let thread = composing("@", in: group.id, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        thread.draft = "lunch?"
        await thread.send()
        let sent = try #require(rig.stores.messages.messages(in: group.id).last)
        #expect(sent.body == "lunch?" && sent.mentions.isEmpty)
    }

    // MARK: Receive

    /// A group message whose list is seven `everyone` entries, one of them ours, alerts once under the mention id; the
    /// same list without us is an ordinary message.
    @Test func aFullListNotifiesOnlyTheMembersItNames() async {
        let rig = AppRig()
        let group = await fullGroup(rig, people: crowd)
        let sender = crowd[0]
        let listed = (crowd.dropFirst().map(\.nodeId) + [rig.me]).map { MessageMention(nodeId: $0.string, name: "everyone") }
        #expect(listed.count == 7)
        await rig.receive("@everyone lunch?", from: sender.nodeId, in: group, sentAt: 1000, mentions: listed)
        let posted = rig.notifier.posted
        #expect(posted.map(\.id) == [NotificationPolicy.mentionId(group.id)])
        await rig.receive("@everyone again", from: sender.nodeId, in: group, sentAt: 2000, mentions: Array(listed.dropLast()))
        #expect(rig.notifier.posted.map(\.id) == [NotificationPolicy.mentionId(group.id), group.id])
    }
}
