import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// What a full group's `@everyone` is to a receiving engine (ADR 2026-10.jwst): seven ordinary mentions, sealed inside the
/// group message, stored whole and alerting by the node-id match alone.
@Suite struct MeshEngineEveryoneTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private func fixture() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// `@everyone` is seven ordinary mentions in a full group of eight, one for each member but the sender (ADR
    /// 2026-10.jwst): a receiver stores all seven and is told once, by its own node id among them. Without it in the list,
    /// the message is no mention of us.
    @Test func aFullGroupsEveryoneListIsStoredWholeAndMentionsUsOnce() throws {
        let fixture = try fixture()
        let others = (4...8).map { TestPeer(seed: $0) }
        let members = [alice, bob, carol] + others
        let info = roster(members, createdBy: bob)
        let everyone = (members.filter { $0.nodeId != bob.nodeId }).map { Mention(nodeId: $0.nodeId.string, name: "everyone") }
        #expect(everyone.count == 7)
        let content = MessageContent(body: "@everyone lunch?", mentions: everyone)
        let readers = members.filter { $0.nodeId != bob.nodeId }
        let frame = try bob.groupMessage("", in: info, to: readers, id: "gm-all", sentAt: start, content: content)
        fixture.deliver(frame, from: bob)
        let stored = try #require(fixture.stores.messages.message("gm-all"))
        #expect(stored.mentions.count == 7 && stored.mentions.allSatisfy { $0.name == "everyone" })
        #expect(stored.mentions.mentions(alice.nodeId))
        let heard = announced(fixture.engine.drainEvents()).map(\.record)
        #expect(heard.count == 1 && heard.first?.mentions.mentions(alice.nodeId) == true)
    }

    /// The same list without us in it stores whole and mentions nobody here.
    @Test func anEveryoneListWithoutUsIsNoMentionOfUs() throws {
        let fixture = try fixture()
        let others = (4...8).map { TestPeer(seed: $0) }
        let members = [alice, bob, carol] + others
        let info = roster(members, createdBy: bob)
        let listed = members.filter { $0.nodeId != bob.nodeId && $0.nodeId != alice.nodeId }
        let content = MessageContent(body: "@everyone lunch?", mentions: listed.map { Mention(nodeId: $0.nodeId.string, name: "everyone") })
        let readers = members.filter { $0.nodeId != bob.nodeId }
        let frame = try bob.groupMessage("", in: info, to: readers, id: "gm-not-us", sentAt: start, content: content)
        fixture.deliver(frame, from: bob)
        let stored = try #require(fixture.stores.messages.message("gm-not-us"))
        #expect(stored.mentions.count == 6 && !stored.mentions.mentions(alice.nodeId))
        #expect(announced(fixture.engine.drainEvents()).map(\.record).first?.mentions.mentions(alice.nodeId) == false)
    }
}
