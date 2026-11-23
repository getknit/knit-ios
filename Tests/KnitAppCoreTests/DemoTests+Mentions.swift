import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

// Mentions (ADR 2026-10.nbhj), apart from the suite's body to keep it under the lint's file length.
extension DemoTests {
    @Test func theDemosMentionsAreStoredAndLit() throws {
        // The other Sam's room post mentions Sam under the label that tells the two Sams apart, as a composer writes it,
        // and ours in the group mentions Priya, whose name is hers alone. Each bubble lights its name (knit-ios #36).
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .edgeCases)
        let room = try #require(stores.messages.message("room-2"))
        let sam = try #require(room.mentions.first)
        #expect(room.mentions.count == 1 && sam.name.hasPrefix("Sam (") && room.body.hasPrefix(sam.token + " same here."))
        let group = try #require(stores.messages.message("group-2"))
        #expect(group.mentions.map(\.name) == ["Priya"] && group.replyTo != nil)
        let (session, _) = Self.session(stores, identity: identity, radio: .on, linked: [])
        #expect(session.directory.label(for: try #require(NodeId(sam.nodeId))).text == sam.name)
        for (record, span) in [(room, 0..<sam.token.utf16.count), (group, 0..<6)] {
            let thread = ChatModel(conversationId: record.conversationId, session: session)
            #expect(thread.state.messages.first { $0.id == record.id }?.mentionSpans == [span])
        }
    }
}
