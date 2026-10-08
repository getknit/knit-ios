import Foundation
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A classifier that scores words from a table, counting each time it is asked. Words it does not know score `nil`, as
/// words the model cannot read do.
actor FakeTextClassifier: TextClassifier {
    private let table: [String: [Float]]
    private(set) var asked: [String] = []

    init(_ table: [String: [Float]]) {
        self.table = table
    }

    func scores(of text: String) -> [Float]? {
        asked.append(text)
        return table[text]
    }

    /// One score per label, `label` at `score` and the rest at nothing.
    static func scores(_ label: String, _ score: Float) -> [Float] {
        AbusiveText.labels.map { $0 == label ? score : 0 }
    }
}

/// A classifier that holds its first read until ``release()``, as the model does while it loads. It reads nothing, so
/// every message passes.
actor HeldTextClassifier: TextClassifier {
    private var held: CheckedContinuation<Void, Never>?
    private var watching: [CheckedContinuation<Void, Never>] = []
    private(set) var asked = 0

    func scores(of _: String) async -> [Float]? {
        asked += 1
        if asked == 1 {
            for watcher in watching {
                watcher.resume()
            }
            watching = []
            await withCheckedContinuation { held = $0 }
        }
        return nil
    }

    /// Returns once the first read is held.
    func holding() async {
        if asked == 0 {
            await withCheckedContinuation { watching.append($0) }
        }
    }

    /// Lets the first read finish.
    func release() {
        held?.resume()
        held = nil
    }
}

/// The content filter for words: Android's policy over the classifier's scores, the check before a message is sent, and
/// screening as a message arrives, which every place that shows its words reads (ADR 2026-10.e4kz).
@MainActor
@Suite struct TextScreeningTests {
    private static let threat = "I will find you"
    private static let fine = "see you at noon"
    /// A stand-in slur list: `SlurListTests` reads the shipped one.
    private static let slurs = WordFilter(words: ["zorp"])

    private static func screening(_ table: [String: [Float]] = [threat: FakeTextClassifier.scores("threat", 0.95)]) -> (
        TextScreening, FakeTextClassifier
    ) {
        let classifier = FakeTextClassifier(table.merging([fine: FakeTextClassifier.scores("toxicity", 0.2)]) { kept, _ in kept })
        return (TextScreening(classifier: classifier, words: WordFilter(words: ["shit"]), slurs: Self.slurs), classifier)
    }

    // MARK: The policy

    @Test func onlySeriousAbuseCrossesALine() {
        #expect(AbusiveText.labels.count == 16)
        #expect(AbusiveText.lines.map(\.label) == ["severe_toxicity", "identity_attack", "sexual_explicit", "threat"])
        #expect(AbusiveText.isAbusive(FakeTextClassifier.scores("threat", 0.9)))
        #expect(!AbusiveText.isAbusive(FakeTextClassifier.scores("threat", 0.899)))
        #expect(AbusiveText.isAbusive(FakeTextClassifier.scores("sexual_explicit", 0.8)))
        #expect(AbusiveText.isAbusive(FakeTextClassifier.scores("identity_attack", 0.85)))
        #expect(AbusiveText.isAbusive(FakeTextClassifier.scores("severe_toxicity", 0.85)))
        for rude in ["toxicity", "insult", "obscene", "muslim"] {
            #expect(!AbusiveText.isAbusive(FakeTextClassifier.scores(rude, 1)), "\(rude) is rudeness or a topic, never held against anyone")
        }
        #expect(AbusiveText.blockingLabel([1, 1, 1]) == nil, "scores from some other model block nothing")
    }

    @Test func theHighestLabelPastItsLineIsTheOneThatBlocks() {
        var scores = FakeTextClassifier.scores("threat", 0.95)
        scores[AbusiveText.labels.firstIndex(of: "sexual_explicit") ?? 0] = 0.99
        #expect(AbusiveText.blockingLabel(scores) == "sexual_explicit")
        #expect(AbusiveText.blockingLabel(FakeTextClassifier.scores("threat", 0.5)) == nil)
    }

    // MARK: The check

    @Test func theRoomRunsTheWordListFirstAndADMRunsTheModelAlone() async {
        let (screening, classifier) = Self.screening()
        #expect(await screening.isAbusive("oh shit", inRoom: true))
        #expect(await classifier.asked.isEmpty, "the list answered, so the model was never asked")
        #expect(await !screening.isAbusive("oh shit", inRoom: false), "profanity between people who chose each other is theirs")
        #expect(await screening.isAbusive(Self.threat, inRoom: false))
        #expect(await screening.isAbusive(Self.threat, inRoom: true))
        #expect(await !screening.isAbusive(Self.fine, inRoom: true))
    }

    @Test func everyConversationRunsTheSlurListBeforeTheModel() async {
        // knit-next ADR 2026-10.d62w: the model scores a slur aimed at someone as an insult, which blocks nothing.
        let (screening, classifier) = Self.screening(["you zorp": FakeTextClassifier.scores("insult", 0.99)])
        #expect(await screening.isAbusive("you zorp", inRoom: false))
        #expect(await screening.isAbusive("you z0rp", inRoom: true))
        #expect(await classifier.asked.isEmpty, "the list answered, so the model was never asked")
        let blind = TextScreening(classifier: nil, words: WordFilter(words: []), slurs: Self.slurs)
        #expect(await blind.isAbusive("z o r p", inRoom: false), "with no model, the slur list still holds")
    }

    @Test func positionsComeOutAndWordsTheModelCannotReadPass() async {
        let (screening, classifier) = Self.screening()
        #expect(await screening.isAbusive("\(Self.threat) geo:37.9455,-122.1", inRoom: false))
        #expect(await classifier.asked == [Self.threat], "the model read the words without the position")
        #expect(await !screening.isAbusive("geo:37.9455,-122.1", inRoom: true), "a position alone is no words at all")
        #expect(await !screening.isAbusive("something the model cannot read", inRoom: false))
        #expect(await !screening.isAbusive("  ", inRoom: true))
        let blind = TextScreening(classifier: nil, words: WordFilter(words: ["shit"]), slurs: Self.slurs)
        #expect(await blind.isAbusive("oh shit", inRoom: true))
        #expect(await !blind.isAbusive(Self.threat, inRoom: false), "with no model, only the lists hold anything back")
    }

    // MARK: Arriving

    @Test func someoneElsesWordsAreScreenedBeforeTheyShowOrNotify() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening)
        await rig.pin(AppRig.sam, name: "Sam")
        let bad = await rig.receive(Self.threat, from: AppRig.sam.nodeId, sentAt: 1)
        let good = await rig.receive(Self.fine, from: AppRig.sam.nodeId, sentAt: 2)
        #expect(rig.stores.messages.message(bad.id)?.moderation == .flagged)
        #expect(rig.stores.messages.message(good.id)?.moderation == .clear)
        let bodies = rig.notifier.posted.map(\.body)
        #expect(
            bodies == [
                Copy.Notifications.roomBody(sender: "Sam", body: Copy.Moderation.hiddenMessage),
                Copy.Notifications.roomBody(sender: "Sam", body: Self.fine),
            ])
        #expect(!bodies.joined().contains(Self.threat), "a hidden message's words never reach the lock screen")
    }

    @Test func withTheFilterOffTheNotificationShowsTheWordsButTheVerdictIsKept() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening, preferences: MemoryPreferences(filtersContent: false))
        await rig.pin(AppRig.sam, name: "Sam")
        let bad = await rig.receive(Self.threat, from: AppRig.sam.nodeId)
        #expect(rig.notifier.posted.map(\.body) == [Copy.Notifications.roomBody(sender: "Sam", body: Self.threat)])
        #expect(rig.stores.messages.message(bad.id)?.moderation == .flagged, "so turning the filter on hides it at once")
    }

    @Test func withNoModelEveryMessageIsClear() async {
        let rig = AppRig()
        let message = await rig.receive(Self.threat, from: AppRig.sam.nodeId)
        #expect(rig.stores.messages.message(message.id)?.moderation == .clear)
        #expect(rig.stores.messages.waitingForModeration().isEmpty)
    }

    @Test func whatWaitedWhenKnitStoppedIsScreenedBeforeTheFirstEvent() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening)
        let stranded = MessageRecord(
            id: "stranded",
            senderId: AppRig.sam.nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: Self.threat,
            sentAt: 1,
            moderation: .waiting
        )
        rig.stores.messages.save(stranded)
        let revision = rig.session.revision
        rig.mesh.finish()
        await rig.session.listen()
        #expect(rig.stores.messages.message("stranded")?.moderation == .flagged)
        #expect(rig.session.revision > revision, "the screens rebuild with the verdict")
        #expect(rig.notifier.posted.isEmpty, "an old message never notifies again")
    }

    @Test func aMessageAlreadyScreenedIsNotAskedAgain() async {
        let (screening, classifier) = Self.screening()
        let rig = AppRig(screening: screening)
        let message = await rig.receive(Self.threat, from: AppRig.sam.nodeId)
        var replayed = message
        replayed.moderation = .waiting
        await rig.session.handle(.received(replayed, isRequest: false))
        #expect(await classifier.asked == [Self.threat])
        #expect(rig.stores.messages.message(message.id)?.moderation == .flagged)
    }

    // MARK: Showing

    @Test func aThreadHidesFlaggedAndUnscreenedWordsFromOthersWhileTheFilterIsOn() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening)
        await rig.receive(Self.threat, from: AppRig.sam.nodeId, sentAt: 1)
        await rig.receive(Self.fine, from: AppRig.sam.nodeId, sentAt: 2)
        rig.stores.messages.save(
            MessageRecord(
                id: "late",
                senderId: AppRig.sam.nodeId,
                recipientId: nil,
                conversationId: Conversations.nearby,
                body: "just landed",
                sentAt: 3,
                moderation: .waiting
            )
        )
        await rig.session.send(Self.threat, in: Conversations.nearby)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(model.state.messages.map(\.hiddenWords) == [.flagged, nil, .unscreened, nil], "our own words never hide from us")
        #expect(model.state.messages.first?.body == Self.threat, "the words stay, for a tap to show")
        rig.session.filtersContent = false
        #expect(model.state.messages.map(\.hiddenWords) == [nil, nil, nil, nil])
    }

    /// A message is found by its id, through the photo it carries or through itself, so a UI test can read what the
    /// filter hides of either.
    @Test func aMessagesIdentifierNamesItsId() {
        #expect(AccessibilityID.chatMessage("room-9") == "chat_message_room-9")
        #expect(AccessibilityID.chatPhoto("room-5") == "chat_photo_room-5")
    }

    @Test func theChatListAndRequestsSayAMessageIsHidden() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening)
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.receive(Self.threat, from: AppRig.sam.nodeId)
        await rig.receive(Self.threat, from: AppRig.stranger.nodeId, to: rig.me)
        let list = ChatListModel(session: rig.session)
        #expect(list.state.rows.first?.preview == Copy.ChatList.preview(speaker: "Sam", body: Copy.Moderation.hiddenMessage))
        #expect(RequestsModel(session: rig.session).rows.map(\.preview) == [Copy.Moderation.hiddenMessage])
        rig.session.filtersContent = false
        #expect(list.state.rows.first?.preview == Copy.ChatList.preview(speaker: "Sam", body: Self.threat))
    }

    // MARK: Sending

    @Test func abusiveWordsAreNotSentAndStayInTheComposer() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening, preferences: MemoryPreferences(filtersContent: false))
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        model.draft = Self.threat
        await model.send()
        #expect(model.wordsRefused, "checked whatever the filter says")
        #expect(model.draft == Self.threat && !model.isSending)
        #expect(rig.mesh.calls.room.isEmpty)
        model.wordsRefused = false
        model.draft = "oh shit"
        await model.send()
        #expect(model.wordsRefused, "the room adds its word list")
        model.wordsRefused = false
        model.draft = Self.fine
        await model.send()
        #expect(!model.wordsRefused && model.draft.isEmpty)
        #expect(rig.mesh.calls.room == [Self.fine])
    }

    @Test func profanityGoesInADM() async {
        let (screening, _) = Self.screening()
        let rig = AppRig(screening: screening)
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
        model.draft = "oh shit"
        await model.send()
        #expect(!model.wordsRefused)
        #expect(rig.mesh.calls.direct == ["\(AppRig.sam.nodeId): oh shit"])
    }

    @Test func sendIsUnderWayWhileTheWordsAreCheckedAndATapMeanwhileSendsNothingMore() async {
        let classifier = HeldTextClassifier()
        let rig = AppRig(screening: TextScreening(classifier: classifier, words: WordFilter(words: []), slurs: WordFilter(words: [])))
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
        model.draft = Self.fine
        let first = Task { await model.send() }
        await classifier.holding()
        #expect(model.isSending)
        await model.send()
        #expect(await classifier.asked == 1, "the second tap checks nothing")
        await classifier.release()
        await first.value
        #expect(!model.isSending && model.draft.isEmpty)
        #expect(rig.mesh.calls.direct == ["\(AppRig.sam.nodeId): \(Self.fine)"], "sent once")
    }
}
