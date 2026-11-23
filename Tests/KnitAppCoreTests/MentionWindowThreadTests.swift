import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A thread's window through `ChatModel` (the paired contract's revisions 3 and 5, knit-ios #36): only the newest 200
/// received rows that carry mentions light theirs, and a blocked sender's rows don't count.
@MainActor
@Suite struct MentionWindowThreadTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// A thread lights the mentions of its newest 200 received rows that carry them (the contract's revision 3): of 201,
    /// the oldest draws plain, and our own row, which never counts, still lights.
    @Test func onlyTheNewestTwoHundredMentioningRowsLight() async {
        let rig = AppRig()
        rig.session.filtersContent = false
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        rig.stores.conversations.accept(sam.nodeId.string)
        let priyas = [MessageMention(nodeId: priya.nodeId.string, name: "Priya")]
        await rig.session.send("@Priya first", mentions: priyas, in: sam.nodeId.string)
        for index in 0...MentionWindow.size {
            await rig.receive("@Priya \(index)", from: sam.nodeId, to: rig.me, sentAt: 10_000 + Int64(index), mentions: priyas)
        }
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        let lit = thread.state.messages.filter { !$0.isMine }.map(\.mentionSpans)
        #expect(lit.count == MentionWindow.size + 1)
        #expect(lit.first?.isEmpty == true, "the oldest is outside the window")
        #expect(lit.dropFirst().allSatisfy { $0 == [0..<6] })
        #expect(thread.state.messages.filter(\.isMine).map(\.mentionSpans) == [[0..<6]], "ours never counts")
    }

    /// Blocking a flooder takes their rows out of the window, so an honest highlight they pushed out lights again (the
    /// contract's revision 5).
    @Test func blockingAFlooderBringsAHighlightBack() async {
        let rig = AppRig()
        rig.session.filtersContent = false
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        await rig.receive(
            "@Priya hi", from: sam.nodeId, sentAt: 1000, mentions: [MessageMention(nodeId: priya.nodeId.string, name: "Priya")])
        for index in 0..<MentionWindow.size {
            let flood = [MessageMention(nodeId: sam.nodeId.string, name: "Sam")]
            await rig.receive("@Sam \(index)", from: stranger.nodeId, sentAt: 2000 + Int64(index), mentions: flood)
        }
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let honest = { thread.state.messages.first { $0.body == "@Priya hi" }?.mentionSpans }
        #expect(honest()?.isEmpty == true, "pushed out of the window")
        await rig.session.block(stranger.nodeId)
        #expect(honest() == [0..<6])
    }
}
