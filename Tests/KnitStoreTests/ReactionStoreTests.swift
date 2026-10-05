import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Reactions in the message store (`ReactionRepositoryTest` and `ReactionDaoTest` in knit-next), against every store.
@Suite struct ReactionStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)

    private let thumbs = "\u{1F44D}"
    private let heart = "\u{2764}\u{FE0F}"

    /// Bob's message `id` in `conversation`.
    private func message(_ id: String, in conversation: String = "nearby", sentAt: Int64 = 1) -> MessageRecord {
        MessageRecord(id: id, senderId: bob, recipientId: nil, conversationId: conversation, body: "hi", sentAt: sentAt)
    }

    /// `reactor`'s reaction to `messageId`.
    private func reaction(_ emoji: String?, on messageId: String = "m", by reactor: NodeId? = nil, at updatedAt: Int64) -> ReactionRecord {
        ReactionRecord(messageId: messageId, reactor: reactor ?? alice, emoji: emoji, updatedAt: updatedAt)
    }

    @Test(arguments: kinds)
    func strictlyNewerWinsAndATieKeepsWhatIsHeld(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        #expect(store.applyReaction(reaction(thumbs, at: 5)))
        #expect(!store.applyReaction(reaction(heart, at: 5)), "a tie keeps what is held")
        #expect(!store.applyReaction(reaction(heart, at: 4)), "an older update changes nothing")
        #expect(store.reaction(on: "m", by: alice) == reaction(thumbs, at: 5))
        #expect(store.applyReaction(reaction(heart, at: 6)), "a newer one replaces it")
        #expect(store.reactions(in: "nearby") == [reaction(heart, at: 6)])
    }

    @Test(arguments: kinds)
    func aRetractionBeatsAnOlderAddThatArrivesAfterIt(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        #expect(store.applyReaction(reaction(nil, at: 7)))
        #expect(!store.applyReaction(reaction(thumbs, at: 6)), "the add was overtaken by its retraction")
        #expect(store.reaction(on: "m", by: alice) == reaction(nil, at: 7), "the retraction is kept, with its clock")
        #expect(store.reactions(in: "nearby").isEmpty, "a retraction stands for nothing")
    }

    @Test(arguments: kinds)
    func aThreadsReactionsLeaveOutRetractionsStatusLinesOtherThreadsAndOrphans(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        store.save(message("elsewhere", in: "g-1"))
        let created = StatusNotices.groupCreated("nearby", by: bob, at: 1)
        store.save(created)
        store.applyReaction(reaction(thumbs, on: "m", by: alice, at: 3))
        store.applyReaction(reaction(nil, on: "m", by: carol, at: 4))
        store.applyReaction(reaction(thumbs, on: "elsewhere", by: alice, at: 5))
        store.applyReaction(reaction(thumbs, on: created.id, by: alice, at: 6))
        store.applyReaction(reaction(thumbs, on: "not-yet", by: alice, at: 7))
        #expect(store.reactions(in: "nearby") == [reaction(thumbs, on: "m", by: alice, at: 3)])
        #expect(store.reactions(in: "g-1") == [reaction(thumbs, on: "elsewhere", by: alice, at: 5)])
    }

    @Test(arguments: kinds)
    func aThreadsReactionsReadOldestFirstWithTiesByTheirBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a"))
        store.save(message("b"))
        store.applyReaction(reaction(thumbs, on: "b", by: alice, at: 2))
        store.applyReaction(reaction(thumbs, on: "a", by: bob, at: 2))
        store.applyReaction(reaction(heart, on: "a", by: alice, at: 2))
        store.applyReaction(reaction(heart, on: "b", by: carol, at: 1))
        let first = alice.string.utf8.lexicographicallyPrecedes(bob.string.utf8) ? alice : bob
        let second = first == alice ? bob : alice
        #expect(
            store.reactions(in: "nearby").map { [$0.messageId, $0.reactor.string] } == [
                ["b", carol.string], ["a", first.string], ["a", second.string], ["b", alice.string],
            ])
    }

    @Test(arguments: kinds)
    func aReactionThatOvertookItsMessageShowsOnceTheMessageLands(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.applyReaction(reaction(thumbs, at: 3)), "kept with no message to show it on")
        #expect(store.reactions(in: "nearby").isEmpty)
        store.save(message("m"))
        #expect(store.reactions(in: "nearby") == [reaction(thumbs, at: 3)])
    }

    @Test(arguments: kinds)
    func messageIdsCompareByTheirBytes(kind: RepositoryKind) throws {
        // "K" and the Kelvin sign are one string to Swift and two ids to Android (ADR 2026-09.jc2x).
        let store = try kind.make().messages
        store.save(message("K"))
        store.applyReaction(reaction(thumbs, on: "K", at: 3))
        #expect(store.applyReaction(reaction(heart, on: "\u{212A}", at: 2)), "another message's reaction, older or not")
        #expect(store.reaction(on: "K", by: alice)?.emoji == thumbs)
        #expect(store.reactions(in: "nearby") == [reaction(thumbs, on: "K", at: 3)])
    }

    @Test(arguments: kinds)
    func deletingAMessageTakesItsReactionsAndRefusesNewOnes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        store.save(message("n"))
        store.applyReaction(reaction(thumbs, on: "m", at: 3))
        store.applyReaction(reaction(thumbs, on: "n", at: 3))
        store.deleteMessage("m", at: 10)
        #expect(store.reaction(on: "m", by: alice) == nil)
        #expect(!store.applyReaction(reaction(heart, on: "m", at: 4)), "a re-served reaction to a deleted message")
        #expect(store.reaction(on: "m", by: alice) == nil)
        #expect(store.reaction(on: "n", by: alice)?.emoji == thumbs, "its neighbour keeps its own")
    }

    @Test(arguments: kinds)
    func deletingAChatTakesEveryReactionInIt(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m", in: "g-1"))
        store.save(message("n", in: "nearby"))
        store.applyReaction(reaction(thumbs, on: "m", at: 3))
        store.applyReaction(reaction(thumbs, on: "n", at: 3))
        store.deleteMessages(in: "g-1", at: 10)
        #expect(store.reaction(on: "m", by: alice) == nil)
        #expect(!store.applyReaction(reaction(heart, on: "m", at: 4)))
        #expect(store.reactions(in: "nearby") == [reaction(thumbs, on: "n", at: 3)])
    }

    @Test(arguments: kinds)
    func thePruneForgetsOnlyOldReactionsWhoseMessageIsNotHeld(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("held"))
        store.applyReaction(reaction(thumbs, on: "held", at: 1))
        store.applyReaction(reaction(thumbs, on: "old", at: 1))
        store.applyReaction(reaction(nil, on: "gone", at: 1))
        store.applyReaction(reaction(thumbs, on: "young", at: 10))
        store.pruneOrphanReactions(updatedBefore: 10)
        #expect(store.reaction(on: "held", by: alice) != nil, "a held message keeps its reactions however old")
        #expect(store.reaction(on: "old", by: alice) == nil)
        #expect(store.reaction(on: "gone", by: alice) == nil, "a retraction with no message goes too")
        #expect(store.reaction(on: "young", by: alice) != nil, "still within its grace")
    }
}
