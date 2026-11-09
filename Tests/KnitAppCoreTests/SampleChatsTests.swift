import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The sample chats anyone can open, in a store build too (ADR 2026-11.pydf): what they hold, through a real mesh and
/// session, and what answers the user. Someone in a real outage must never take a line here for a real person's.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SampleChatsTests {
    /// App Review asked for messages from other users: the room, both DMs, the group, a request, and a stranger to report.
    @Test func theSampleHoldsEveryKindOfThreadAndAStrangerToReport() throws {
        let sample = try Self.sample()
        let list = ChatListModel(session: sample.session)
        #expect(list.state.rows.map(\.title) == ["Nearby", "Sam Rivera", "Summit crew", "Dani Cho"])
        #expect(list.state.requestCount == 1)
        #expect(!list.state.showsGettingStarted, "a sample has people in it")
        let stranger = try #require(DemoSeed.nodeId(.stranger))
        let room = sample.stores.messages.messages(in: Conversations.nearby)
        #expect(room.filter { $0.senderId == stranger }.map(\.id) == ["sample-rude", "sample-flagged", "sample-photo"])
        #expect(room.last?.id == "room-9", "the chat list's preview stays a friendly one")
        #expect(sample.stores.messages.message("sample-photo")?.attachment != nil, "the filter has a photo to hide")
    }

    /// The room is filled before the mesh starts, so a reviewer on an iPad with nothing nearby sees the people linked.
    @Test func theSampleShowsPeopleLinkedWithNobodyNearby() async throws {
        let sample = try Self.sample()
        let listening = Task { await sample.session.listen() }
        await sample.session.start()
        while sample.session.neighbors.count < 3 {
            await Task.yield()
        }
        #expect(ChatListModel(session: sample.session).status == .linked(3))
        listening.cancel()
        sample.mesh.end()
    }

    /// Nothing made up may read as a promise: each answer names itself a sample, and none says someone is coming.
    @Test func everyAnswerSaysItIsASample() {
        let answers = DemoScene.sample.cast.answers
        #expect(!answers.isEmpty)
        #expect(answers.allSatisfy { $0.hasPrefix("Sample reply:") })
        #expect(Set(answers).count == answers.count)
    }

    /// Only the sample answers: a scene for a film or a clip keeps to its script.
    @Test func noOtherSceneAnswers() {
        let answering = DemoScene.allCases.filter { !$0.cast.answers.isEmpty }
        #expect(answering == [.sample])
    }

    /// The banner has to say both things: the people aren't real, and nothing reaches anyone.
    @Test func theBannerSaysThePeopleAreMadeUpAndNothingReachesAnyone() {
        #expect(Copy.Sample.banner.contains("made up"))
        #expect(Copy.Sample.banner.contains("nothing you send reaches anyone"))
    }

    // MARK: Answers

    @Test func aPostInTheRoomShowsDeliveredAndSomeoneThereAnswers() async throws {
        let sample = try Self.sample()
        await sample.mesh.start()
        let sent = try #require(await sample.mesh.postToRoom("Hello", photo: nil, replyTo: nil, mentions: []))
        let answer = await Self.answer("answer-0", in: sample.stores)
        #expect(sample.stores.messages.message(sent.id)?.delivered == true)
        #expect(answer.conversationId == Conversations.nearby)
        #expect(answer.recipientId == nil)
        #expect(answer.senderId == DemoSeed.nodeId(.sam))
        #expect(answer.body == DemoScene.sample.cast.answers[0])
        sample.mesh.end()
    }

    @Test func aDirectMessageIsAnsweredByThePersonItWentTo() async throws {
        let sample = try Self.sample()
        let dani = try #require(DemoSeed.nodeId(.dani))
        await sample.mesh.start()
        let sent = try #require(await sample.mesh.sendDirectMessage("Hello", to: dani, photo: nil, replyTo: nil, mentions: []))
        let answer = await Self.answer("answer-0", in: sample.stores)
        #expect(sample.stores.messages.message(sent.id)?.delivered == true)
        #expect(answer.senderId == dani)
        #expect(answer.recipientId == sample.identity.nodeId)
        #expect(answer.conversationId == dani.string, "in the same thread")
        sample.mesh.end()
    }

    @Test func aGroupMessageIsAnsweredBySomeoneInTheGroup() async throws {
        let sample = try Self.sample()
        let group = try #require(sample.stores.groups.groups().first)
        await sample.mesh.start()
        _ = try #require(await sample.mesh.sendGroupMessage("Hello", to: group.id, photo: nil, replyTo: nil, mentions: []))
        let answer = await Self.answer("answer-0", in: sample.stores)
        #expect(answer.conversationId == group.id)
        #expect(answer.recipientId == nil)
        #expect(group.roster.contains { $0.nodeId == answer.senderId.string })
        #expect(answer.senderId != sample.identity.nodeId, "someone else answers")
        sample.mesh.end()
    }

    /// Each message gets the next answer, and the room's answerers take turns.
    @Test func theAnswersAndTheRoomsAnswerersTakeTurns() async throws {
        let sample = try Self.sample()
        await sample.mesh.start()
        _ = await sample.mesh.postToRoom("One", photo: nil, replyTo: nil, mentions: [])
        _ = await sample.mesh.postToRoom("Two", photo: nil, replyTo: nil, mentions: [])
        let first = await Self.answer("answer-0", in: sample.stores)
        let second = await Self.answer("answer-1", in: sample.stores)
        #expect(first.body != second.body)
        #expect(first.senderId == DemoSeed.nodeId(.sam))
        #expect(second.senderId == DemoSeed.nodeId(.dani))
        sample.mesh.end()
    }

    /// A block holds here as it does at the engine's gate: the person it stops says nothing, and the room's next answerer
    /// speaks instead.
    @Test func aBlockedPersonNeverAnswers() async throws {
        let sample = try Self.sample()
        let sam = try #require(DemoSeed.nodeId(.sam))
        await sample.mesh.start()
        await sample.mesh.block(sam)
        let toSam = try #require(await sample.mesh.sendDirectMessage("Hello", to: sam, photo: nil, replyTo: nil, mentions: []))
        while sample.stores.messages.message(toSam.id)?.delivered != true {
            await Task.yield()
        }
        _ = await sample.mesh.postToRoom("Anyone?", photo: nil, replyTo: nil, mentions: [])
        let answer = await Self.answer("answer-0", in: sample.stores)
        #expect(answer.conversationId == Conversations.nearby, "the DM went unanswered, so the room's post took the first answer")
        #expect(answer.senderId == DemoSeed.nodeId(.dani), "the turn after a skipped Sam")
        sample.mesh.end()
    }

    /// Closing the sample ends the answers, and with them the task that held the mesh.
    @Test func endingTheMeshEndsItsAnswersAndItsEvents() async throws {
        let sample = try Self.sample()
        await sample.mesh.start()
        sample.mesh.end()
        _ = await sample.mesh.postToRoom("Hello", photo: nil, replyTo: nil, mentions: [])
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(sample.stores.messages.message("answer-0") == nil)
        var events = sample.mesh.events.makeAsyncIterator()
        while await events.next() != nil {
            // Whatever was already said drains, then the stream ends rather than hanging.
        }
    }

    /// A close can overtake the start `run()` left going: the start then plays nothing, so no task keeps the mesh alive.
    @Test func aMeshEndedBeforeItStartsPlaysNothing() async throws {
        let sample = try Self.sample()
        sample.mesh.end()
        await sample.mesh.start()
        _ = await sample.mesh.postToRoom("Hello", photo: nil, replyTo: nil, mentions: [])
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(sample.stores.messages.message("answer-0") == nil)
    }

    /// The sample covers the app: a live thread left visible would keep new messages read and quiet, with nobody looking.
    @Test func hidingThreadsLeavesNoThreadVisible() async throws {
        let sample = try Self.sample()
        await sample.session.show(Conversations.nearby)
        #expect(sample.session.visible == Conversations.nearby)
        sample.session.hideThreads()
        #expect(sample.session.visible == nil)
    }

    // MARK: The filter

    /// The scene's own words answer for themselves, so the sample opens without loading the model.
    @Test func theScenesWordsNeverReachTheModel() async {
        let model = CountingText()
        let filter = SampleTextClassifier(scene: .sample, device: model)
        let friendly = await filter.scores(of: "Good call, thanks for the warning.")
        let answer = await filter.scores(of: DemoScene.sample.cast.answers[0])
        #expect(!AbusiveText.isAbusive(friendly ?? []))
        #expect(!AbusiveText.isAbusive(answer ?? []))
        #expect(await model.reads.isEmpty)
    }

    @Test func theScenesFlaggedPostIsFlagged() async {
        let filter = SampleTextClassifier(scene: .sample, device: nil)
        let scores = await filter.scores(of: DemoCast.filteredPost)
        #expect(AbusiveText.isAbusive(scores ?? []))
    }

    /// Someone testing the filter here gets the filter's real answer: what they type goes to the bundled model.
    @Test func whatTheUserTypesMeetsTheBundledModel() async {
        let model = CountingText()
        let filter = SampleTextClassifier(scene: .sample, device: model)
        let scores = await filter.scores(of: "Words the scene never says")
        #expect(await model.reads == ["Words the scene never says"])
        #expect(scores == CountingText.answer)
    }

    @Test func aDemoWithNoModelLetsTheUsersWordsThrough() async {
        let filter = SampleTextClassifier(scene: .sample, device: nil)
        #expect(await filter.scores(of: "Words the scene never says") == nil)
    }

    @Test func theFlaggedPhotoIsFlaggedAndAnyOtherMeetsTheBundledModel() async {
        let flagged: [UInt8] = [1, 2, 3]
        let other: [UInt8] = [4, 5, 6]
        let filter = SamplePhotoClassifier(flagging: [flagged], device: FixedPhoto(answer: [9]))
        #expect(await filter.scores(of: flagged) == [0, 0, 0, 1, 0])
        #expect(await filter.scores(of: other) == [9])
        #expect(await SamplePhotoClassifier(flagging: [], device: nil).scores(of: other) == nil)
    }

    // MARK: Helpers

    private struct Sample {
        let identity: IdentityKeys
        let stores: MeshStores
        let mesh: DemoMesh
        let session: AppSession
    }

    /// The sample scene over a real mesh on the demo's radio, as `AppEnvironment.sample` builds it, on a new identity of its
    /// own, with no pause in its answers.
    private static func sample() throws -> Sample {
        let identity = IdentityKeys.generate()
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .sample) { _ in
            nil
        } snap: { _ in
            [0xFF, 0xD8]
        }
        let director = try #require(
            DemoDirector(
                scene: .sample,
                stores: stores,
                me: identity.nodeId,
                snap: { _ in [0xFF, 0xD8] },
                now: { 100_000_000 },
                wait: { _ in await Task.yield() }
            )
        )
        let node = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: DemoRadio(state: .on),
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let mesh = DemoMesh(node, staging: DemoSeed.staging(in: .sample), director: director)
        let session = AppSession(identity: OwnIdentity(bundle: identity.bundle), stores: stores, mesh: mesh)
        session.director = director
        return Sample(identity: identity, stores: stores, mesh: mesh, session: session)
    }

    /// The answer stored as `id`, once it lands. The suite's time limit ends a wait for one that never does.
    private static func answer(_ id: String, in stores: MeshStores) async -> MessageRecord {
        while true {
            if let message = stores.messages.message(id) {
                return message
            }
            await Task.yield()
        }
    }
}

/// A bundled model that says what it was asked.
private actor CountingText: TextClassifier {
    static let answer: [Float] = [0.5]
    private(set) var reads: [String] = []

    func scores(of text: String) -> [Float]? {
        reads.append(text)
        return Self.answer
    }
}

/// A bundled photo model with one answer.
private struct FixedPhoto: PhotoClassifier {
    let answer: [Float]

    func scores(of _: [UInt8]) -> [Float]? {
        answer
    }
}
