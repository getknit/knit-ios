import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Typing on the screens: the cue a keystroke sends, as `ChatViewModel.onUserTyping` does in knit-next, and who each kind
/// of thread shows typing at its foot.
@MainActor
@Suite struct TypingTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// Gives a cue a keystroke started time to reach the mesh: it goes on a task of its own.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // MARK: Ours

    @Test func eachKeystrokeThatLeavesWordsTellsTheThread() async {
        let rig = AppRig()
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.draft = "H"
        await settle()
        #expect(rig.mesh.calls.typing == [Conversations.nearby])
        thread.draft = "H"
        thread.draft = "   "
        await settle()
        #expect(rig.mesh.calls.typing == [Conversations.nearby], "no change, then only blanks")
        thread.draft = "Hi"
        await settle()
        #expect(rig.mesh.calls.typing == [Conversations.nearby, Conversations.nearby], "the mesh throttles, not the thread")
    }

    @Test func sendingClearsTheComposerWithoutACue() async {
        let rig = AppRig()
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.draft = "On my way"
        await thread.send()
        await settle()
        #expect(rig.mesh.calls.room == ["On my way"])
        #expect(rig.mesh.calls.typing == [Conversations.nearby])
    }

    @Test func noCueGoesWhileKnitIsBehindOrWhereTheComposerIsNot() async {
        let rig = AppRig()
        await rig.session.setActive(false)
        ChatModel(conversationId: Conversations.nearby, session: rig.session).draft = "Hi"
        await settle()
        await rig.session.setActive(true)
        await rig.receive("Hi! Blue tent?", from: stranger.nodeId, to: rig.me)
        ChatModel(conversationId: stranger.nodeId.string, session: rig.session).draft = "Who's this?"
        await rig.pin(sam, name: "Sam")
        await rig.receive("Hey", from: sam.nodeId, to: rig.me)
        await rig.session.block(sam.nodeId)
        ChatModel(conversationId: sam.nodeId.string, session: rig.session).draft = "Hey"
        await settle()
        #expect(rig.mesh.calls.typing.isEmpty, "in the background, a request and a blocked person's DM")
    }

    // MARK: Theirs

    @Test func whoIsTypingLaysOverTheThreadWithoutARebuild() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(thread.state.typing.isEmpty && thread.state.typingLabel == nil)
        let revision = rig.session.revision
        await rig.session.handle(.typing([Conversations.nearby: [sam.nodeId, priya.nodeId].sorted()]))
        #expect(thread.state.typing.map(\.name) == ["Priya", "Sam"], "in name order")
        #expect(thread.state.typing.map(\.nodeId) == [priya.nodeId, sam.nodeId])
        #expect(thread.state.typingLabel == "Priya and others are typing")
        #expect(rig.session.revision == revision, "nothing stored moved")
        await rig.session.handle(.typing([Conversations.nearby: [sam.nodeId]]))
        #expect(thread.state.typingLabel == "Sam is typing")
        await rig.session.handle(.typing([:]))
        #expect(thread.state.typing.isEmpty && thread.state.typingLabel == nil)
    }

    @Test func eachThreadShowsOnlyThePeopleItsAudienceTakes() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        let group = await rig.group([sam, priya], createdBy: sam)
        await rig.session.handle(
            .typing([
                Conversations.nearby: [rig.me, stranger.nodeId],
                sam.nodeId.string: [sam.nodeId, stranger.nodeId],
                group.id: [priya.nodeId, stranger.nodeId],
            ]))
        let room = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(room.state.typing.map(\.nodeId) == [stranger.nodeId], "anyone but us")
        #expect(ChatModel(conversationId: sam.nodeId.string, session: rig.session).state.typing.map(\.nodeId) == [sam.nodeId])
        #expect(ChatModel(conversationId: group.id, session: rig.session).state.typing.map(\.nodeId) == [priya.nodeId])
        await rig.session.block(stranger.nodeId)
        #expect(room.state.typing.isEmpty, "a blocked person hides")
        await rig.session.unblock(stranger.nodeId)
        #expect(room.state.typing.map(\.nodeId) == [stranger.nodeId])
    }
}
