import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A thread, its composer, a request's Accept, and the message requests list.
@MainActor
@Suite struct ChatModelTests {
    @Test func theRoomNamesEachSpeakerButUsAndTicksOurOwn() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.receive("Hello all", from: AppRig.sam.nodeId, sentAt: 1)
        await rig.session.send("Hi Sam", in: Conversations.nearby)
        let state = ChatModel(conversationId: Conversations.nearby, session: rig.session).state
        #expect(state.isRoom)
        #expect(state.title == Copy.ChatList.nearby)
        #expect(state.messages.map(\.authorLabel) == ["Sam", nil])
        #expect(state.messages.map(\.status) == [nil, .sent])
        #expect(state.messages.map(\.isMine) == [false, true])
        #expect(!state.isRequest)
    }

    @Test func aDMNamesNobodyAndSaysWhetherItsPeerIsInRange() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        await rig.receive("Where are you?", from: AppRig.sam.nodeId, to: rig.me)
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
        #expect(model.state.title == "Sam")
        #expect(model.state.peer == AppRig.sam.nodeId)
        #expect(model.state.messages.map(\.authorLabel) == [nil])
        #expect(model.state.isVerified)
        #expect(!model.state.isLinked)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId)]))
        #expect(model.state.isLinked)
    }

    @Test func aDMWaitingForItsKeySaysSo() async {
        let rig = AppRig()
        let model = ChatModel(conversationId: AppRig.priya.nodeId.string, session: rig.session)
        model.draft = "Hello before your key"
        await model.send()
        #expect(model.state.messages.map(\.status) == [.waitingForKey])
        #expect(DeliveryStatus.waitingForKey.label == Copy.Delivery.waitingForKey)
    }

    @Test func sendingClearsTheDraftOnlyOnceItIsStored() async {
        let rig = AppRig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(!model.canSend)
        model.draft = "   "
        #expect(!model.canSend)
        await model.send()
        #expect(model.draft == "   ", "nothing was sent, so nothing is cleared")
        model.draft = "Hello"
        #expect(model.canSend)
        await model.send()
        #expect(model.draft.isEmpty)
        #expect(rig.mesh.calls.room == ["Hello"])
    }

    @Test func theComposerRefusesTheOverflowAndCountsDownNearTheLimit() {
        let rig = AppRig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        model.draft = String(repeating: "a", count: 1899)
        #expect(model.remaining == nil)
        model.draft = String(repeating: "a", count: 1900)
        #expect(model.remaining == 100)
        model.draft = String(repeating: "🧶", count: 1500)
        #expect(model.draft.utf16.count == TextLimits.message, "counted in UTF-16, as Android counts")
        #expect(model.remaining == 0)
    }

    @Test func aStrangersThreadIsARequestUntilAccepted() async {
        let rig = AppRig()
        await rig.receive("Hi", from: AppRig.stranger.nodeId, to: rig.me)
        let model = ChatModel(conversationId: AppRig.stranger.nodeId.string, session: rig.session)
        #expect(model.state.isRequest)
        await model.accept()
        #expect(!model.state.isRequest)
        #expect(rig.mesh.calls.accepted == [AppRig.stranger.nodeId.string])
    }

    @Test func anEmptyDMIsNoRequest() {
        let rig = AppRig()
        #expect(!ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session).state.isRequest)
    }

    @Test func aThreadOnScreenIsTheOneKeptQuiet() async {
        let rig = AppRig()
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
        await model.appear()
        #expect(rig.notifier.withdrawn == [AppRig.sam.nodeId.string])
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("Quiet", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.isEmpty)
        model.disappear()
        await rig.receive("Loud", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.map(\.body) == ["Loud"])
    }

    // MARK: Requests

    @Test func requestsListStrangersNewestFirstWithTheirWords() async {
        let rig = AppRig()
        await rig.pin(AppRig.priya, name: "Priya")
        await rig.receive("Older", from: AppRig.stranger.nodeId, to: rig.me, sentAt: 1)
        await rig.receive("Newer\nwords", from: AppRig.priya.nodeId, to: rig.me, sentAt: 2)
        await rig.receive("Room posts are never requests", from: AppRig.sam.nodeId, sentAt: 3)
        let requests = RequestsModel(session: rig.session)
        #expect(requests.rows.map(\.title) == ["Priya", Alias.alias(for: AppRig.stranger.nodeId.string)])
        #expect(requests.rows.map(\.preview) == ["Newer words", "Older"])
        #expect(requests.rows.map(\.lastMessageAt) == [2, 1])
        await requests.accept(AppRig.priya.nodeId.string)
        #expect(requests.rows.map(\.id) == [AppRig.stranger.nodeId.string])
        #expect(ChatListModel(session: rig.session).state.rows.map(\.title).contains("Priya"))
    }

    // MARK: The composer's rules

    @Test func aBodyIsTrimmedTheWayKotlinTrimsAndCutAtTheLimit() {
        #expect(Composer.body(of: "\u{2003} hi \n") == "hi", "Kotlin's trim is Unicode-wide")
        #expect(Composer.body(of: "a  b") == "a  b", "the inside is left alone")
        #expect(Composer.body(of: "\u{3000}") == nil)
        #expect(Composer.body(of: String(repeating: "x", count: 2500))?.utf16.count == TextLimits.message)
        #expect(Composer.trimmed("").isEmpty)
    }

    @Test func aSingleLineFieldIsNormalizedAndCut() {
        #expect(Composer.singleLine("  Sam \n Smith ", limit: 32) == "Sam Smith")
        #expect(Composer.singleLine(String(repeating: "n", count: 40), limit: 32).count == 32)
    }
}
