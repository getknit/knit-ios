import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The people a message mentions, kept by every message store (schema v14 for the SQL one), the rule that keeps only
/// those its body carries, and how "mentions us" is read (`MentionTest.kt`).
@Suite struct MessageMentionTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private func message(_ id: String, body: String = "", mentioning mentions: [MessageMention] = []) -> MessageRecord {
        MessageRecord(
            id: id, senderId: bob, recipientId: nil, conversationId: Conversations.nearby, body: body, sentAt: 1, mentions: mentions)
    }

    /// `@everyone` in a full group of eight is seven entries of one name, and `carried` keeps all of them: the distinct
    /// token counts once against the body's bound (ADR 2026-10.jwst).
    @Test func sevenEveryoneEntriesAreCarriedWhole() {
        let everyone = (1...7).map { MessageMention(nodeId: fixtureNodeId($0).string, name: "everyone") }
        #expect(MessageMention.carried(everyone, in: "@everyone hi") == everyone)
        #expect(MessageMention.carried(everyone + everyone, in: "@everyone hi") == everyone, "a repeat adds nothing")
        #expect(MessageMention.carried(everyone, in: "hi everyone").isEmpty, "the token went from the text")
    }

    // MARK: The stores

    /// `mentionStoreRoundTrips`: names with spaces and an alias in parentheses come back whole, in their order.
    @Test(arguments: kinds)
    func aMessageKeepsItsMentionsInOrder(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let mentions = [
            MessageMention(nodeId: alice.string, name: "Ann Lee (Joyful Ferret)"),
            MessageMention(nodeId: bob.string, name: "Bo"),
        ]
        let mentioning = message("mentioning", body: "@Ann Lee (Joyful Ferret) and @Bo", mentioning: mentions)
        store.save(mentioning)
        store.save(message("plain", body: "hi"))
        #expect(store.message("mentioning") == mentioning)
        #expect(store.messages(in: Conversations.nearby).map(\.mentions) == [mentions, []])
    }

    /// The fields are the sender's: a node id that is no node id, and a name Swift calls equal to another, are kept by
    /// their bytes (ADR 2026-09.jc2x).
    @Test(arguments: kinds)
    func aMentionIsKeptByItsBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        // "K" and the Kelvin sign are one string to Swift and two to Android.
        let odd = MessageMention(nodeId: "not a node id", name: "\u{212A}\u{0}")
        store.save(message("m1", body: "@\u{212A}\u{0}", mentioning: [odd]))
        let kept = try #require(store.message("m1")?.mentions.first)
        #expect(kept.nodeId == "not a node id")
        #expect(Array(kept.name.utf8) == Array("\u{212A}\u{0}".utf8))
    }

    /// The first copy of a frame sets its mentions: a re-served one changes nothing, every other write keeps them, and a
    /// save writes the whole row.
    @Test(arguments: kinds)
    func everyWriteKeepsTheMentions(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let ann = [MessageMention(nodeId: alice.string, name: "Ann")]
        var ours = message("ours", body: "hi @Ann", mentioning: ann)
        ours.senderId = alice
        ours.pendingKey = true
        store.save(ours)
        store.clearPendingKey("ours")
        store.markDelivered("ours")
        store.setModeration("ours", to: .flagged)
        #expect(store.message("ours")?.mentions == ann)
        #expect(!store.insertIfAbsent(message("ours", body: "hi @Bo", mentioning: [MessageMention(nodeId: bob.string, name: "Bo")])))
        #expect(store.message("ours")?.mentions == ann, "a re-served frame changes nothing")
        ours.mentions = []
        store.save(ours)
        #expect(store.message("ours")?.mentions.isEmpty == true, "a save writes the whole row")
    }

    // MARK: What a body carries

    /// A mention counts only while its token is in the body: one edited out of the text, one with an empty name, and a
    /// repeat of the same pair are dropped, and the rest keep their order (`ChatScreen.kt:535-540`, `:581`).
    @Test func onlyTheMentionsTheBodyCarriesAreKept() {
        let ann = MessageMention(nodeId: alice.string, name: "Ann")
        let bo = MessageMention(nodeId: bob.string, name: "Bo")
        let gone = MessageMention(nodeId: bob.string, name: "Carol")
        let empty = MessageMention(nodeId: bob.string, name: "")
        let annAgain = MessageMention(nodeId: alice.string, name: "Ann")
        #expect(MessageMention.carried([bo, gone, ann, empty, annAgain], in: "@Ann, @Bo!") == [bo, ann])
        #expect(MessageMention.carried([ann], in: "Ann").isEmpty, "a name without its @ is no token")
    }

    /// Two people may go by one name: each pair is its own mention.
    @Test func twoPeopleWithOneNameAreBothKept() {
        let mentions = [MessageMention(nodeId: alice.string, name: "Sam"), MessageMention(nodeId: bob.string, name: "Sam")]
        #expect(MessageMention.carried(mentions, in: "@Sam") == mentions)
    }

    /// A token is found by its UTF-16 code units, as Kotlin's `contains` finds it, so a pair Swift calls equal to it is not
    /// the token, and a token Swift reads as part of a longer character still is.
    @Test func aTokenMatchesByCodeUnits() {
        let kelvin = MessageMention(nodeId: alice.string, name: "\u{212A}im")
        #expect(MessageMention.carried([kelvin], in: "@Kim").isEmpty)
        let ann = MessageMention(nodeId: alice.string, name: "Ann")
        #expect(MessageMention.carried([ann], in: "@Ann\u{301}") == [ann])
    }

    /// Android keeps a pick while the text holds its token, so a stale pick hiding inside a longer name is still a mention
    /// there (`ChatScreen.kt:530`): both are kept here too, in either order.
    @Test func aStalePickInsideALongerNameIsKeptInEitherOrder() {
        let ann = MessageMention(nodeId: alice.string, name: "Ann")
        let annabel = MessageMention(nodeId: bob.string, name: "Annabel")
        #expect(MessageMention.carried([ann, annabel], in: "@Annabel hi") == [ann, annabel])
        #expect(MessageMention.carried([annabel, ann], in: "@Annabel hi") == [annabel, ann])
        let sam = MessageMention(nodeId: alice.string, name: "Sam")
        let samFox = MessageMention(nodeId: bob.string, name: "Sam (blue fox)")
        #expect(MessageMention.carried([samFox, sam], in: "@Sam (blue fox) lunch?") == [samFox, sam])
    }

    /// Names a body doesn't hold cost a lookup each and hide nothing: a flood of long ones leaves the real mention kept.
    @Test func aFloodOfAbsentNamesHidesNothing() {
        let ann = MessageMention(nodeId: alice.string, name: "Ann")
        let flood = (0..<5000).map { MessageMention(nodeId: bob.string, name: String(repeating: "a", count: 999) + "\($0)") }
        #expect(MessageMention.carried(flood + [ann], in: String(repeating: "a", count: 1995) + " @Ann") == [ann])
    }

    /// Tokens found that add up to more than twice the body's units are no list a composer wrote: none is kept, in any
    /// order. The edge itself is kept.
    @Test func aListNoComposerCouldWriteKeepsNone() {
        let body = "@" + String(repeating: "a", count: 20)
        let nested = (1...20).map { MessageMention(nodeId: bob.string, name: String(repeating: "a", count: $0)) }
        #expect(MessageMention.carried(nested, in: body).isEmpty)
        #expect(MessageMention.carried(nested.reversed(), in: body).isEmpty)
        // "@a" through "@aaaaa" come to 20 units: twice a 10-unit body keeps them, and twice a 9-unit one does not.
        let five = Array(nested.prefix(5))
        #expect(MessageMention.carried(five, in: "@aaaaa abc") == five)
        #expect(MessageMention.carried(five, in: "@aaaaa ab").isEmpty)
    }

    // MARK: Mentions us

    /// `detectsSelfMentionByNodeId`: by node id alone, whatever the name, and never in an empty list.
    @Test func mentionsUsByNodeIdAlone() {
        #expect([MessageMention(nodeId: alice.string, name: "Someone else")].mentions(alice))
        #expect(![MessageMention(nodeId: bob.string, name: "Ann")].mentions(alice))
        #expect(![MessageMention]().mentions(alice))
        #expect(![MessageMention(nodeId: alice.string.uppercased(), name: "Ann")].mentions(alice), "a node id compares by its bytes")
    }
}
