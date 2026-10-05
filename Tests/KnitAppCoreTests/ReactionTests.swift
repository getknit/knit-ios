import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Reactions on the screens (ADR 2026-10.ehe6): the six a bubble's menu offers, the chips under a message as
/// `ChatViewModel`'s `ReactionSummary` builds them in knit-next, and whose reactions each kind of thread shows.
@MainActor
@Suite struct ReactionTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger
    private let thumbs = "\u{1F44D}"
    private let heart = "\u{2764}\u{FE0F}"

    /// Stores `person`'s reaction to `messageId` and tells the session, as the engine does when one lands.
    private func react(_ emoji: String?, by person: NodeId, to messageId: String, at updatedAt: Int64, in rig: AppRig) async {
        let reaction = ReactionRecord(messageId: messageId, reactor: person, emoji: emoji, updatedAt: updatedAt)
        rig.stores.messages.applyReaction(reaction)
        await rig.session.handle(.reacted(reaction))
    }

    @Test func theSixAreAndroidsOriginalRowInItsOrder() {
        // `RecentReactions.DEFAULTS`, the heart with its variation selector, byte for byte.
        #expect(
            ReactionChoices.six.map { $0.unicodeScalars.map(\.value) } == [
                [0x1F44D], [0x2764, 0xFE0F], [0x1F602], [0x1F62E], [0x1F622], [0x1F64F],
            ])
        #expect(ReactionChoices.six.allSatisfy(TextLimits.isAcceptedReaction))
    }

    @Test func chipsCountEachEmojiWhereItFirstAppearedAndMarkOurs() async throws {
        let rig = AppRig()
        let post = await rig.receive("Anyone near the lake?", from: sam.nodeId)
        await react(heart, by: priya.nodeId, to: post.id, at: 2000, in: rig)
        await react(thumbs, by: sam.nodeId, to: post.id, at: 3000, in: rig)
        await react(heart, by: rig.me, to: post.id, at: 4000, in: rig)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let message = try #require(thread.state.messages.first)
        #expect(
            message.reactions == [
                ReactionChip(emoji: heart, count: 2, mine: true), ReactionChip(emoji: thumbs, count: 1, mine: false),
            ])
        await react(nil, by: priya.nodeId, to: post.id, at: 5000, in: rig)
        #expect(
            thread.state.messages.first?.reactions == [
                ReactionChip(emoji: thumbs, count: 1, mine: false), ReactionChip(emoji: heart, count: 1, mine: true),
            ],
            "Priya took hers back, so the heart now first appears with ours, after Sam's")
    }

    @Test func anyEmojiAnotherPhoneSendsShows() async {
        let rig = AppRig()
        let post = await rig.receive("Saved you a spot", from: sam.nodeId)
        await react("\u{1F525}", by: sam.nodeId, to: post.id, at: 2000, in: rig)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(thread.state.messages.first?.reactions.map(\.emoji) == ["\u{1F525}"])
    }

    @Test func aDmShowsOnlyItsTwoPeoplesReactions() async {
        // The frame names no thread, so a stranger who saw the DM's frame id could otherwise react inside it.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        let dm = await rig.receive("North gate", from: sam.nodeId, to: rig.me)
        await react(thumbs, by: stranger.nodeId, to: dm.id, at: 2000, in: rig)
        await react(heart, by: sam.nodeId, to: dm.id, at: 3000, in: rig)
        await react(thumbs, by: rig.me, to: dm.id, at: 4000, in: rig)
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        #expect(thread.state.messages.first?.reactions.map(\.emoji) == [heart, thumbs])
        #expect(thread.state.messages.first?.reactions.last?.count == 1)
    }

    @Test func aGroupShowsOnlyItsFoundingRostersReactions() async throws {
        let rig = AppRig()
        let group = await rig.group([sam, priya], createdBy: sam, departed: [])
        let message = await rig.receive("Lunch?", from: sam.nodeId, in: group)
        await react(thumbs, by: stranger.nodeId, to: message.id, at: 2000, in: rig)
        await react(heart, by: priya.nodeId, to: message.id, at: 3000, in: rig)
        let thread = ChatModel(conversationId: group.id, session: rig.session)
        let row = try #require(thread.state.messages.first { $0.id == message.id })
        #expect(row.reactions == [ReactionChip(emoji: heart, count: 1, mine: false)])
        #expect(thread.state.messages.first { $0.notice != nil }?.reactions.isEmpty == true, "a status line has none")
    }

    @Test func aBlockedPersonsReactionsHideAndComeBackOnUnblock() async {
        let rig = AppRig()
        let post = await rig.receive("Hi all", from: sam.nodeId)
        await react(thumbs, by: stranger.nodeId, to: post.id, at: 2000, in: rig)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        await rig.session.block(stranger.nodeId)
        #expect(thread.state.messages.first?.reactions.isEmpty == true)
        await rig.session.unblock(stranger.nodeId)
        #expect(thread.state.messages.first?.reactions.map(\.emoji) == [thumbs])
    }

    @Test func reactingGoesThroughTheMeshAndPickingItAgainTakesItBack() async throws {
        let rig = AppRig()
        let post = await rig.receive("Anyone near the lake?", from: sam.nodeId)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let message = try #require(thread.state.messages.first)
        await thread.react(to: message, with: thumbs)
        #expect(rig.mesh.calls.reactions == ["\(post.id) \(thumbs)"])
        #expect(thread.state.messages.first?.reactions == [ReactionChip(emoji: thumbs, count: 1, mine: true)])
        await thread.react(to: message, with: thumbs)
        #expect(thread.state.messages.first?.reactions.isEmpty == true)
    }

    @Test func aStatusLineARequestAndABlockedDmTakeNoReaction() async throws {
        let rig = AppRig()
        let group = await rig.group([sam, priya], createdBy: sam)
        let created = try #require(ChatModel(conversationId: group.id, session: rig.session).state.messages.first)
        await ChatModel(conversationId: group.id, session: rig.session).react(to: created, with: thumbs)
        await rig.receive("Hi! Blue tent?", from: stranger.nodeId, to: rig.me)
        let request = ChatModel(conversationId: stranger.nodeId.string, session: rig.session)
        #expect(request.state.isRequest && !request.state.canReact)
        try await request.react(to: #require(request.state.messages.first), with: thumbs)
        await rig.pin(sam, name: "Sam")
        await rig.receive("Hey", from: sam.nodeId, to: rig.me)
        await rig.session.block(sam.nodeId)
        #expect(!ChatModel(conversationId: sam.nodeId.string, session: rig.session).state.canReact)
        #expect(rig.mesh.calls.reactions.isEmpty)
    }

    @Test func voiceOverHearsEachEmojiAndWhoChoseIt() {
        var message = ChatMessage(id: "m", body: "Hi", sentAt: 1, isMine: false, author: sam.nodeId)
        #expect(message.reactionSummary == nil)
        message.reactions = [ReactionChip(emoji: thumbs, count: 2, mine: true), ReactionChip(emoji: heart, count: 1, mine: false)]
        #expect(message.reactionSummary == "Reactions: \(thumbs) You and 1 other, \(heart) 1 person")
        #expect(message.isOurReaction(thumbs) && !message.isOurReaction(heart))
        #expect(!message.isOurReaction("\u{2764}"), "compared by its bytes: a bare heart is another emoji")
    }

    @Test func voiceOverHearsWhoChoseEachEmoji() {
        #expect(Copy.Reactions.chipValue(count: 1, mine: true) == "You")
        #expect(Copy.Reactions.chipValue(count: 2, mine: true) == "You and 1 other")
        #expect(Copy.Reactions.chipValue(count: 4, mine: true) == "You and 3 others")
        #expect(Copy.Reactions.chipValue(count: 1, mine: false) == "1 person")
        #expect(Copy.Reactions.chipValue(count: 3, mine: false) == "3 people")
        #expect(Copy.Reactions.react(thumbs) == "React with \(thumbs)")
        #expect(Copy.Reactions.remove(thumbs) == "Remove your \(thumbs) reaction")
    }
}
