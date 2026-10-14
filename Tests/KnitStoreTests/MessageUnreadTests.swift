import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Which messages nobody has read, kept by every message store (schema v15 for the SQL one, ADR 2026-10.frmj): someone
/// else's ordinary message from when it is first stored until its thread is read.
@Suite struct MessageUnreadTests {
    private static let kinds = RepositoryKind.allCases

    private let me = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)

    /// A message `author` (Bob, unless named) wrote in `thread`, which reached us at `sentAt` unless it is ours.
    private func message(
        _ id: String, from author: NodeId? = nil, in thread: String = Conversations.nearby, sentAt: Int64 = 1, kind: MessageKind = .message
    ) -> MessageRecord {
        let sender = author ?? bob
        return MessageRecord(
            id: id,
            senderId: sender,
            recipientId: nil,
            conversationId: thread,
            body: id,
            sentAt: sentAt,
            arrivedAt: sender == me ? nil : sentAt,
            kind: kind
        )
    }

    private func count(_ store: any MessageStore, in thread: String = Conversations.nearby, blocked: Set<NodeId> = []) -> Int? {
        store.unreadCounts(excludingSenders: blocked)[ExactKey(thread)]
    }

    @Test(arguments: kinds)
    func someoneElsesMessageArrivesUnreadBySaveOrInsert(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("saved"))
        #expect(store.insertIfAbsent(message("inserted")))
        #expect(count(store) == 2)
        #expect(store.unreadCounts(excludingSenders: []).count == 1, "a thread with none has no entry")
    }

    @Test(arguments: kinds)
    func ourOwnStatusLinesAndUnknownKindsNeverAre(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("ours", from: me))
        // A status line about someone else, even one dated by our clock, and a kind this build doesn't know.
        store.save(message("left", kind: .memberLeft))
        store.save(message("future", kind: MessageKind(rawValue: 42)))
        #expect(store.unreadCounts(excludingSenders: []).isEmpty)
        #expect(!store.markRead(in: Conversations.nearby), "nothing was unread")
    }

    /// Screening, the demo's quotes and mentions, and a save over a held row rewrite it: none of them moves the flag.
    @Test(arguments: kinds)
    func aResaveNeitherClearsNorResurrectsTheFlag(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var held = message("m1")
        store.save(held)
        held.body = "edited"
        store.save(held)
        store.setModeration("m1", to: .flagged)
        #expect(count(store) == 1)
        #expect(store.message("m1")?.body == "edited")
        store.markRead(in: Conversations.nearby)
        store.save(held)
        store.setModeration("m1", to: .clear)
        #expect(count(store) == nil)
    }

    @Test(arguments: kinds)
    func insertIfAbsentOfAHeldIdLeavesItsFlag(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m1"))
        store.markRead(in: Conversations.nearby)
        #expect(!store.insertIfAbsent(message("m1")), "a re-served frame")
        #expect(count(store) == nil)
    }

    @Test(arguments: kinds)
    func markingAThreadReadTouchesOnlyItAndSaysWhetherItChanged(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let dm = bob.string
        store.save(message("room1"))
        store.save(message("room2", from: carol))
        store.save(message("dm1", in: dm))
        #expect(store.markRead(in: Conversations.nearby))
        #expect(count(store) == nil)
        #expect(count(store, in: dm) == 1)
        #expect(!store.markRead(in: Conversations.nearby), "already read")
        #expect(!store.markRead(in: "g-nothing"), "a thread with no rows")
        store.save(message("room3", sentAt: 2))
        #expect(count(store) == 1, "what arrives after the read is unread")
    }

    @Test(arguments: kinds)
    func countsLeaveOutBlockedSenders(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("bob1"))
        store.save(message("bob2"))
        store.save(message("carol1", from: carol))
        #expect(count(store, blocked: [bob]) == 1)
        #expect(count(store, blocked: [bob, carol]) == nil)
        #expect(count(store) == 3, "an unblock brings their messages back, unread as they were")
    }

    @Test(arguments: kinds)
    func aDeleteTakesItsUnreadWithIt(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let dm = bob.string
        store.save(message("room1"))
        store.save(message("room2"))
        store.save(message("dm1", in: dm))
        store.deleteMessage("room1", at: 5)
        #expect(count(store) == 1)
        store.deleteMessages(in: dm, at: 5)
        #expect(count(store, in: dm) == nil)
    }

    /// A thread id is the sender's text until it parses: "K" and the Kelvin sign are one string to Swift and two threads
    /// to Android (ADR 2026-09.jc2x).
    @Test(arguments: kinds)
    func threadIdsThatSwiftCallsEqualCountApart(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("plain", in: "g-K"))
        store.save(message("kelvin1", in: "g-\u{212A}"))
        store.save(message("kelvin2", in: "g-\u{212A}"))
        #expect(count(store, in: "g-K") == 1)
        #expect(count(store, in: "g-\u{212A}") == 2)
        #expect(store.markRead(in: "g-K"))
        #expect(count(store, in: "g-K") == nil)
        #expect(count(store, in: "g-\u{212A}") == 2)
    }

    /// Store and forward hands over a message long after it was written. Android's watermark of the author's clock never
    /// counts one dated before the last read; the flag counts it whatever its date.
    @Test(arguments: kinds)
    func aLateMessageCountsWhateverItsSentAt(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("new", sentAt: 100))
        store.markRead(in: Conversations.nearby)
        var late = message("late", sentAt: 50)
        late.arrivedAt = 200
        #expect(store.insertIfAbsent(late))
        #expect(count(store) == 1)
        #expect(store.messages(in: Conversations.nearby).map(\.id) == ["late", "new"], "it still reads in its place")
    }
}
