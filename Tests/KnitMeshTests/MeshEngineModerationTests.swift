import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Someone else's words are stored waiting for the content filter, which the app runs as it hears the event (ADR
/// 2026-10.e4kz). The engine never screens anything itself: it only says what is left to screen.
@Suite struct MeshEngineModerationTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)

    @Test func someoneElsesWordsWaitForTheFilterInTheRoomAndInADM() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.roomPost("Hi all", id: "post-1", sentAt: EngineFixture.start), from: bob)
        fixture.deliver(try bob.directMessage("Hello Alice", to: alice, id: "dm-1", sentAt: EngineFixture.start), from: bob)
        #expect(fixture.stores.messages.message("post-1")?.moderation == .waiting)
        #expect(fixture.stores.messages.message("dm-1")?.moderation == .waiting)
        let announced = fixture.engine.drainEvents().compactMap { event -> MessageModeration? in
            guard case .received(let record, _) = event else {
                return nil
            }
            return record.moderation
        }
        #expect(announced == [.waiting, .waiting], "the event says so too, so the app knows to screen it")
        #expect(fixture.stores.messages.waitingForModeration().map(\.id) == ["post-1", "dm-1"])
    }

    @Test func aPhotoWithNoWordsAndOurOwnPostHaveNothingToScreen() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let photo = ChatContent(body: " \n", attachmentHash: String(repeating: "a", count: 64), attachmentMime: "image/jpeg")
        let frame = try bob.signed(
            RelayEnvelope(type: .chat, id: "photo-1", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: photo.encoded))
        fixture.deliver(frame, from: bob)
        #expect(fixture.stores.messages.message("photo-1")?.moderation == MessageModeration.clear)
        let ours = try #require(fixture.engine.postToRoom("Mine"))
        #expect(fixture.stores.messages.message(ours.id)?.moderation == MessageModeration.clear)
        #expect(fixture.stores.messages.waitingForModeration().isEmpty)
    }

    @Test func aReServedPostKeepsTheVerdictItWasGiven() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let post = try bob.roomPost("Hi all", id: "post-1", sentAt: EngineFixture.start)
        fixture.deliver(post, from: bob)
        fixture.stores.messages.setModeration("post-1", to: .flagged)
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(post, from: bob)
        #expect(fixture.stores.messages.message("post-1")?.moderation == .flagged)
    }
}
