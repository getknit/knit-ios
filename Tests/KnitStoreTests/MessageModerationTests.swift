import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What the content filter made of a message's words, kept by every message store (schema v7 for the SQL one, ADR
/// 2026-10.e4kz).
@Suite struct MessageModerationTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)

    private func message(_ id: String, _ moderation: MessageModeration, sentAt: Int64 = 1) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: bob,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: id,
            sentAt: sentAt,
            moderation: moderation
        )
    }

    @Test(arguments: kinds)
    func aMessageKeepsWhatTheFilterMadeOfIt(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        for record in [message("passed", .clear), message("flagged", .flagged), message("waiting", .waiting)] {
            store.save(record)
        }
        #expect(store.message("passed")?.moderation == MessageModeration.clear)
        #expect(store.message("flagged")?.moderation == .flagged)
        #expect(store.message("waiting")?.moderation == .waiting)
        #expect(store.messages(in: Conversations.nearby).map(\.moderation) == [.clear, .flagged, .waiting])
    }

    @Test(arguments: kinds)
    func aVerdictLandsOnItsRowAlone(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", .waiting))
        store.save(message("b", .waiting))
        #expect(store.setModeration("a", to: .flagged))
        #expect(!store.setModeration("a", to: .flagged), "the same verdict again changes nothing")
        #expect(!store.setModeration("missing", to: .flagged))
        #expect(store.message("a")?.moderation == .flagged)
        #expect(store.message("b")?.moderation == .waiting)
        #expect(store.message("a")?.body == "a", "only the verdict moves")
    }

    @Test(arguments: kinds)
    func whatWaitsIsListedInTheOrderItWasStored(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        // Stored out of `sentAt` order: a launch screens in arrival order, whatever the authors' clocks said.
        store.save(message("late", .waiting, sentAt: 9))
        store.save(message("passed", .clear, sentAt: 5))
        store.save(message("early", .waiting, sentAt: 1))
        #expect(store.waitingForModeration().map(\.id) == ["late", "early"])
        store.setModeration("late", to: .clear)
        #expect(store.waitingForModeration().map(\.id) == ["early"])
    }

    /// Every other write keeps the verdict: a column left out of a write would bring hidden words back the next time
    /// the row moves.
    @Test(arguments: kinds)
    func everyWriteKeepsTheVerdict(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m", .flagged))
        store.markDelivered("m")
        store.clearPendingKey("m")
        #expect(!store.insertIfAbsent(message("m", .waiting)), "a re-served frame changes nothing")
        #expect(store.message("m")?.moderation == .flagged)
        #expect(store.threadHeads().first?.moderation == .flagged)
    }
}
