import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Mentions on the screens (ADR 2026-10.nbhj): whom the composer offers, a pick and its chip, what Send carries, where a
/// bubble's names sit, and the notification of its own for a message that mentions us.
@MainActor
@Suite struct MentionTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// The thread `conversationId`, its draft `text` and the cursor at its end, as the field reports it.
    private func composing(_ text: String, in conversationId: String, rig: AppRig) -> ChatModel {
        let thread = ChatModel(conversationId: conversationId, session: rig.session)
        thread.draft = text
        thread.selection = text.utf16.count..<text.utf16.count
        return thread
    }

    // MARK: Whom the composer offers

    /// The room offers everyone who wrote there, never us or someone blocked, in the order of their labels
    /// (`aBlockedSenderIsNeitherMentionableNorAbleToHideTheRestOfTheThread`).
    @Test func theRoomOffersItsSpeakersButNotUsOrTheBlocked() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "priya")
        await rig.pin(stranger, name: "Zed")
        await rig.receive("hi", from: sam.nodeId)
        await rig.receive("hey", from: priya.nodeId)
        await rig.receive("yo", from: stranger.nodeId)
        await rig.session.send("me too", in: Conversations.nearby)
        await rig.session.block(stranger.nodeId)
        let thread = composing("@", in: Conversations.nearby, rig: rig)
        #expect(thread.mentionCandidates.map(\.label.text) == ["priya", "Sam"])
        #expect(thread.mentionCandidates.map(\.id) == [priya.nodeId.string, sam.nodeId.string])
    }

    /// A group offers its members before they say anything (`ChatViewModel.kt:1013`), and the query narrows them.
    @Test func aGroupOffersItsMembersBeforeTheySpeak() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let group = await rig.group([sam, priya], createdBy: sam)
        rig.stores.conversations.accept(group.id)
        let thread = composing("hi @pri", in: group.id, rig: rig)
        #expect(thread.mentionQuery == MentionQuery(start: 3, end: 7, query: "pri"))
        #expect(thread.mentionCandidates.map(\.label.text) == ["Priya"])
        thread.draft = "hi @"
        #expect(thread.mentionCandidates.map(\.label.text) == ["Priya", "Sam"])
    }

    /// A DM offers its peer once they have written in it, as Android's senders do; a fresh one offers nobody, so the
    /// picker stays closed.
    @Test func aDMOffersItsPeerOnceTheyHaveWritten() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        let fresh = composing("@", in: sam.nodeId.string, rig: rig)
        #expect(fresh.mentionQuery != nil && fresh.mentionCandidates.isEmpty)
        await rig.receive("hello", from: sam.nodeId, to: rig.me)
        #expect(composing("@", in: sam.nodeId.string, rig: rig).mentionCandidates.map(\.label.text) == ["Sam"])
    }

    /// Two people who share a name are offered under their labels, which a pick writes after the "@"
    /// (`sameNamedSendersAreLabelledWithTheirAliasAndTheQuoteSnapshotStaysPlain`).
    @Test func sameNamedSpeakersAreOfferedUnderTheirLabels() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Alex")
        await rig.pin(priya, name: "Alex")
        await rig.receive("one", from: sam.nodeId)
        await rig.receive("two", from: priya.nodeId)
        let thread = composing("@", in: Conversations.nearby, rig: rig)
        let labels = thread.mentionCandidates.map(\.label)
        #expect(labels.count == 2 && labels.allSatisfy { $0.discriminator != nil && $0.text.hasPrefix("Alex (") })
        let pick = try #require(thread.mentionCandidates.first)
        thread.mention(pick)
        #expect(thread.pendingMentions == [MessageMention(nodeId: pick.id, name: pick.label.text)])
        #expect(thread.draft == "@\(pick.label.text) ")
    }

    /// The session writes a mention as the composer does, under this phone's clash-aware label, for the bridge; each row
    /// of the picker goes by the person's node id.
    @Test func theSessionsMentionGoesUnderTheLabel() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Alex")
        await rig.pin(priya, name: "Alex")
        let label = rig.session.directory.label(for: sam.nodeId)
        #expect(label.discriminator != nil)
        #expect(rig.session.mention(of: sam.nodeId) == MessageMention(nodeId: sam.nodeId.string, name: label.text))
        #expect(AccessibilityID.chatMention(sam.nodeId.string) == "chat_mention_\(sam.nodeId.string)")
    }

    /// No picker opens where the thread takes no message, an "@" inside a word, or a cursor with a selection.
    @Test func thePickerStaysClosedWhereItHasNothingToDo() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.receive("hi", from: sam.nodeId, to: rig.me)
        #expect(composing("@", in: sam.nodeId.string, rig: rig).mentionQuery == nil, "a request takes no message yet")
        await rig.receive("hi", from: sam.nodeId)
        #expect(composing("mail sam@", in: Conversations.nearby, rig: rig).mentionQuery == nil)
        let selecting = composing("hi @Sa", in: Conversations.nearby, rig: rig)
        selecting.selection = 3..<6
        #expect(selecting.mentionQuery == nil && selecting.mentionCandidates.isEmpty)
    }

    // MARK: A pick and its chip

    /// A pick replaces the "@" word and keeps what follows the cursor, puts the cursor past the space, and a second pick
    /// of the same person adds no second mention.
    @Test func aPickReplacesTheWordAndKeepsTheRest() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.receive("hi", from: sam.nodeId)
        let thread = composing("hey @s, see you", in: Conversations.nearby, rig: rig)
        thread.selection = 6..<6
        let pick = try #require(thread.mentionCandidates.first)
        thread.mention(pick)
        #expect(thread.draft == "hey @Sam , see you")
        #expect(thread.selection == 9..<9 && thread.mentionQuery == nil)
        #expect(thread.chips == [4..<8])
        thread.draft += " @"
        thread.selection = thread.draft.utf16.count..<thread.draft.utf16.count
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.pendingMentions.count == 1)
        #expect(thread.chips == [4..<8, 19..<23])
        thread.mention(pick)
        #expect(thread.draft.hasSuffix("@Sam "), "with no query, a pick does nothing")
    }

    /// A backspace at a chip's end takes the whole name; one that leaves the chips whole is the field's to apply; a tap
    /// inside a chip lands at its nearer edge.
    @Test func aChipIsEditedWhole() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.receive("hi", from: sam.nodeId)
        let thread = composing("hi @", in: Conversations.nearby, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.draft == "hi @Sam ")
        #expect(!thread.keepChipsWhole(replacing: 7..<8, with: ""), "the space after the chip is plain text")
        #expect(thread.keepChipsWhole(replacing: 6..<7, with: ""))
        #expect(thread.draft == "hi  " && thread.selection == 3..<3)
        thread.draft = "hi @Sam "
        #expect(thread.select(4..<4, from: nil) == 3..<3)
        #expect(thread.selection == 3..<3)
    }

    // MARK: Send

    /// Send carries the picks the text still holds, in the order they were picked, and puts the rest away with the draft
    /// (`ChatScreen.kt:535-540`). A name typed by hand is text, not a mention.
    @Test func sendCarriesThePicksTheTextStillHolds() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        await rig.receive("hi", from: sam.nodeId)
        await rig.receive("hey", from: priya.nodeId)
        let thread = composing("@pri", in: Conversations.nearby, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        thread.draft += "@sa"
        thread.selection = thread.draft.utf16.count..<thread.draft.utf16.count
        thread.mention(try #require(thread.mentionCandidates.first))
        #expect(thread.draft == "@Priya @Sam ")
        // The field took "Priya" out by hand, so only Sam is still mentioned.
        thread.draft = "@Sam and Priya "
        await thread.send()
        let sent = try #require(rig.stores.messages.messages(in: Conversations.nearby).last)
        #expect(sent.body == "@Sam and Priya")
        #expect(sent.mentions == [MessageMention(nodeId: sam.nodeId.string, name: "Sam")])
        #expect(thread.pendingMentions.isEmpty && thread.draft.isEmpty && thread.selection == 0..<0)
    }

    /// A send the room refuses keeps the picks with the draft.
    @Test func aRefusedSendKeepsThePicks() async throws {
        let classifier = FakeTextClassifier(["@Sam I will find you": FakeTextClassifier.scores("threat", 0.95)])
        let rig = AppRig(screening: TextScreening(classifier: classifier, words: WordFilter(words: []), slurs: WordFilter(words: [])))
        await rig.pin(sam, name: "Sam")
        await rig.receive("hi", from: sam.nodeId)
        let thread = composing("@", in: Conversations.nearby, rig: rig)
        thread.mention(try #require(thread.mentionCandidates.first))
        thread.draft += "I will find you"
        await thread.send()
        #expect(thread.wordsRefused && thread.pendingMentions.count == 1)
    }

    // MARK: A thread's names

    /// A bubble lights the names its message mentions, where the sender wrote them.
    @Test func aMessageShowsWhereItsNamesSit() async throws {
        let rig = AppRig()
        rig.session.filtersContent = false
        await rig.pin(sam, name: "Sam")
        let ana = MessageMention(nodeId: rig.me.string, name: "Ana Lee")
        await rig.receive("hi @Ana Lee!", from: sam.nodeId, mentions: [ana])
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let message = try #require(thread.state.messages.first)
        #expect(message.mentionSpans == [3..<11])
    }

    // MARK: Notifications

    /// A message that mentions us posts under an id of its own in its thread, and the next ordinary one leaves it there.
    @Test func aMentionOfUsNotifiesApartInItsThread() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let mention = MessageMention(nodeId: rig.me.string, name: "Me")
        await rig.receive("@Me look", from: sam.nodeId, mentions: [mention])
        await rig.receive("over here", from: sam.nodeId)
        let posted = rig.notifier.posted
        #expect(posted.map(\.id) == [NotificationPolicy.mentionId(Conversations.nearby), Conversations.nearby])
        #expect(posted.allSatisfy { $0.threadId == Conversations.nearby && $0.conversationId == Conversations.nearby })
        #expect(posted.first?.body == "Sam: @Me look", "an ordinary notification's words")
    }

    /// A mention of someone else, a request's, and one in the thread on screen are notified as anything else is there.
    @Test func onlyAMentionOfUsInAnAcceptedThreadOffScreenIsApart() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.receive("@Priya hi", from: sam.nodeId, mentions: [MessageMention(nodeId: priya.nodeId.string, name: "Priya")])
        await rig.receive("@Me hi", from: stranger.nodeId, to: rig.me, mentions: [MessageMention(nodeId: rig.me.string, name: "Me")])
        await rig.session.show(Conversations.nearby)
        await rig.receive("@Me again", from: sam.nodeId, mentions: [MessageMention(nodeId: rig.me.string, name: "Me")])
        #expect(rig.notifier.posted.map(\.id) == [Conversations.nearby, NotificationPolicy.requestsThread])
    }

    /// A group's mention is apart too, titled for the group.
    @Test func aGroupsMentionOfUsIsApart() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let group = await rig.group([sam], name: "Camp", createdBy: sam)
        rig.stores.conversations.accept(group.id)
        await rig.receive("@Me", from: sam.nodeId, in: group, mentions: [MessageMention(nodeId: rig.me.string, name: "Me")])
        let posted = try #require(rig.notifier.posted.last)
        #expect(posted.id == NotificationPolicy.mentionId(group.id) && posted.threadId == group.id && posted.title == "Camp")
    }
}
