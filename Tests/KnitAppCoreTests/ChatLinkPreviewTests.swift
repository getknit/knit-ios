import Foundation
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The composer's half of link previews (`ChatViewModel`'s card loop in knit-next, ADR 2026-11.hcvg): a card held for
/// Send once the draft rests on a link and every gate agrees, one attachment slot, a removed or empty link remembered for
/// the draft, and Send waiting a moment for a card.
@MainActor
@Suite struct ChatLinkPreviewTests {
    private static let link = "https://example.com/story"
    private static let page = TableFetcher.html("<meta property='og:title' content='Title'><meta property='og:description' content='Desc'>")

    /// A thread in a build that sends cards, with the setting on unless asked, over a fetcher answering ``link``.
    private struct Rig {
        let app: AppRig
        let fetcher: TableFetcher
        let gate = SwitchedGate()

        /// `debounces` holds the draft's debounce until it is cancelled, so a Send comes first; `holds` keeps Send's
        /// hold open until the card comes, rather than giving up at once.
        @MainActor
        init(fetcher: TableFetcher = TableFetcher(), on: Bool = true, debounces: Bool = false, holds: Bool = true, words: [String] = []) {
            fetcher.setPage(ChatLinkPreviewTests.link, ChatLinkPreviewTests.page)
            self.fetcher = fetcher
            let service = LinkPreviewService(
                gate: gate, fetcher: fetcher, shrink: { _ in nil }, now: { 1000 }, sleep: { try await Task.sleep(for: $0) })
            let previews = LinkPreviews(service: service, gate: gate) { duration in
                let waits = duration == LinkComposer.debounce ? debounces : holds
                if waits {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
            let screening = TextScreening(classifier: nil, words: WordFilter(words: words), slurs: WordFilter(words: []))
            app = AppRig(screening: screening, linkPreviews: previews)
            app.session.sendsLinkPreviews = on
        }

        /// Pins `person`, drawing cards when `draws`.
        func pin(_ person: Person, draws: Bool) async {
            var record = person.record(name: "\(person.nodeId)", verified: true)
            record.capabilities = draws ? Capabilities.local.union(.linkPreview).rawValue : Capabilities.local.rawValue
            app.stores.peers.upsert(record)
            await app.session.handle(.peerUpdated(person.nodeId))
        }
    }

    /// `model`'s draft set to `text`, once its watch and fetch have run out.
    private func type(_ text: String, into model: ChatModel) async throws -> LinkComposer {
        model.draft = text
        let composer = try #require(model.linkComposer)
        await composer.settled()
        return composer
    }

    // MARK: Staged and sent

    @Test func aLinkInTheDraftBecomesACardThatGoesWithTheMessage() async throws {
        let rig = Rig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type("look: \(Self.link)", into: model)
        let staged = try #require(model.stagedCard)
        #expect(staged.url == Self.link && staged.blob.title == "Title")
        #expect(await model.send())
        #expect(model.stagedCard == nil && model.linkComposer?.staged == nil)
        let sent = try #require(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment)
        #expect(sent.mime == LinkPreviewBlob.mime && rig.app.mesh.calls.photos == [sent.hash])
        #expect(LinkPreviewBlob.decode(try #require(rig.app.stores.blobs.bytes(of: sent.hash)))?.title == "Title")
        await rig.app.session.linkCards?.open(sent.hash, key: nil)
        #expect(model.state.messages.last?.card?.title == "Title", "our own card draws in the thread")
    }

    @Test func withTheSettingOffOrNoServiceNothingIsFetched() async throws {
        let rig = Rig(on: false)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil && rig.fetcher.requests.isEmpty)
        #expect(await model.send())
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment == nil)
        let drawing = AppRig(linkPreviews: LinkPreviews())
        #expect(ChatModel(conversationId: Conversations.nearby, session: drawing.session).linkComposer == nil)
    }

    // MARK: Who draws cards

    @Test func aDMTakesACardOnlyTowardAPhoneThatDrawsThem() async throws {
        let rig = Rig()
        await rig.pin(AppRig.sam, draws: false)
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil && rig.fetcher.requests.isEmpty, "a phone without the bit would show nothing")
        await rig.pin(AppRig.sam, draws: true)
        _ = try await type(Self.link + " ", into: model)
        #expect(model.stagedCard == nil, "the same link, so no new watch")
        model.linkComposer?.reconsider()
        await model.linkComposer?.settled()
        #expect(model.stagedCard?.url == Self.link)
    }

    @Test func aGroupTakesACardOnlyWhenEveryOtherMemberDrawsThem() async throws {
        let rig = Rig()
        await rig.pin(AppRig.sam, draws: true)
        await rig.pin(AppRig.priya, draws: false)
        let group = try #require(await rig.app.session.createGroup(with: [AppRig.sam.nodeId, AppRig.priya.nodeId]))
        let model = ChatModel(conversationId: group.id, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil)
        await rig.pin(AppRig.priya, draws: true)
        model.linkComposer?.reconsider()
        await model.linkComposer?.settled()
        #expect(model.stagedCard != nil)
    }

    // MARK: The draft's memory

    @Test func aRemovedCardIsNotFetchedAgainUntilTheDraftEmpties() async throws {
        let rig = Rig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        model.removeCard()
        await model.linkComposer?.settled()
        #expect(model.stagedCard == nil)
        _ = try await type("\(Self.link) again", into: model)
        #expect(model.stagedCard == nil)
        #expect(await model.linkComposer?.attachment(forSending: model.draft) == nil, "nor at Send")
        _ = try await type("", into: model)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard != nil)
        #expect(rig.fetcher.requests == [Self.link], "the memo answered the second time")
    }

    @Test func aLinkWithNoCardIsNotAskedAgainUntilTheDraftEmpties() async throws {
        let rig = Rig()
        rig.fetcher.setPage(Self.link, .notHTML)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        model.linkComposer?.reconsider()
        await model.linkComposer?.settled()
        #expect(model.stagedCard == nil && rig.fetcher.requests == [Self.link])
        rig.fetcher.setPage(Self.link, Self.page)
        _ = try await type("", into: model)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard != nil)
    }

    /// A card describes the draft's link: another link takes it away and fetches its own, and none takes it away.
    @Test func aNewLinkReplacesTheCardAndNoLinkTakesItAway() async throws {
        let rig = Rig()
        let other = "https://other.example/page"
        rig.fetcher.setPage(other, TableFetcher.html("<title>Other</title>", final: other))
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        _ = try await type(other, into: model)
        #expect(model.stagedCard?.blob.title == "Other")
        _ = try await type("no link now", into: model)
        #expect(model.stagedCard == nil)
    }

    // MARK: One slot

    @Test func aPhotoTakesTheSlotAndTheCardWaitsBehindIt() async throws {
        let rig = Rig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session, codec: FakeCodec())
        _ = try await type(Self.link, into: model)
        await model.choosePhoto(Data("a photo".utf8))
        #expect(model.staged != nil && model.stagedCard == nil)
        model.removePhoto()
        #expect(model.stagedCard?.url == Self.link, "the card comes back")
        await model.choosePhoto(Data("a photo".utf8))
        #expect(await model.send())
        let sent = try #require(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment)
        #expect(sent.mime != LinkPreviewBlob.mime, "the photo went in the card's place")
    }

    // MARK: Send's hold

    @Test func sendWaitsForTheCardOfALinkTypedJustBefore() async {
        let rig = Rig(debounces: true)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        model.draft = Self.link
        #expect(model.stagedCard == nil, "the draft has not rested yet")
        #expect(await model.send())
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment?.mime == LinkPreviewBlob.mime)
    }

    @Test func sendGoesWithoutTheCardPastTheHold() async {
        let rig = Rig(fetcher: TableFetcher(hangs: true), debounces: true, holds: false)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        model.draft = Self.link
        #expect(await model.send())
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment == nil)
    }

    /// A link handed over from the share sheet seeds the draft, and is fetched for as a typed one is.
    @Test func aSeededDraftIsFetchedFor() async {
        let rig = Rig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session, draft: Self.link)
        await model.linkComposer?.settled()
        #expect(model.stagedCard?.url == Self.link)
    }

    // MARK: The route and the room

    @Test func withoutARouteNothingIsFetchedOrRemembered() async throws {
        let rig = Rig(debounces: false)
        rig.gate.set(online: false)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil && rig.fetcher.requests.isEmpty)
        rig.gate.set(online: true)
        #expect(await model.send())
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment?.mime == LinkPreviewBlob.mime)
    }

    /// The room's card is screened on this phone, its words as the room's: flagged, there is no card.
    @Test func aRoomCardWhoseWordsTheFilterFlagsIsNotHeld() async throws {
        let rig = Rig(words: ["title"])
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil)
    }

    /// Low Data Mode is no answer about the link: nothing is fetched or remembered, and the card comes once it is off.
    @Test func lowDataModeRemembersNothing() async throws {
        let rig = Rig()
        rig.gate.set(online: true, restricted: true)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        _ = try await type(Self.link, into: model)
        #expect(model.stagedCard == nil && rig.fetcher.requests.isEmpty)
        rig.gate.set(online: true)
        model.linkComposer?.reconsider()
        await model.linkComposer?.settled()
        #expect(model.stagedCard?.url == Self.link)
    }

    /// Send joins the fetch the draft started rather than making a second.
    @Test func sendJoinsAFetchUnderWay() async {
        let latch = Latch()
        let rig = Rig(fetcher: TableFetcher(latch: latch))
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        model.draft = Self.link
        for _ in 0..<10_000 where model.linkComposer?.isLoading != true {
            await Task.yield()
        }
        #expect(model.linkComposer?.isLoading == true)
        async let sent = model.send()
        await latch.open()
        #expect(await sent)
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment?.mime == LinkPreviewBlob.mime)
        #expect(rig.fetcher.requests == [Self.link])
    }

    /// Words with no link carry no card, a cross with no card does nothing, and a card for a link the draft no longer holds
    /// is not held.
    @Test func whatHasNoLinkOrNoDraftGetsNoCard() async throws {
        let rig = Rig(debounces: true)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        model.removeCard()
        let composer = try #require(model.linkComposer)
        #expect(await composer.attachment(forSending: Self.link) == nil, "the draft is empty, so the card is not held")
        #expect(rig.fetcher.requests == [Self.link])
        model.draft = "hello"
        #expect(await model.send())
        #expect(rig.app.stores.messages.messages(in: Conversations.nearby).last?.attachment == nil)
        try await LinkPreviews().sleep(.zero)
    }

    @Test func leavingTheThreadStopsTheWatch() async {
        let rig = Rig(debounces: true)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.app.session)
        model.draft = Self.link
        model.disappear()
        await model.linkComposer?.settled()
        #expect(rig.fetcher.requests.isEmpty)
    }
}
