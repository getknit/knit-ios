import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Who this phone lists presence keys for (ADR 2026-11.sv5t): `DirectContactsTest`'s pure cases ported by name
/// (`contacts/DirectContactsTest.kt:43-78` at knit-next `cad69c77b`), less the commons, which iOS does not have, and the
/// read over the engine's stores, a blocked device tag included.
@Suite struct DirectContactsTests {
    private let me = TestPeer(seed: 1)
    private let accepted = TestPeer(seed: 2)
    private let verified = TestPeer(seed: 3)
    private let authored = TestPeer(seed: 4)

    private func ids(accepted: Set<String> = [], verified: Set<NodeId> = [], authored: Set<String> = [], blocked: Set<NodeId> = []) -> Set<
        NodeId
    > {
        DirectContacts.ids(accepted: accepted, verified: verified, authored: authored, blocked: blocked, me: me.nodeId)
    }

    @Test func eachOfTheUsersOwnSignalsMakesADirectContact() {
        #expect(ids(accepted: [accepted.nodeId.string]) == [accepted.nodeId])
        #expect(ids(verified: [verified.nodeId]) == [verified.nodeId])
        #expect(ids(authored: [authored.nodeId.string]) == [authored.nodeId])
    }

    @Test func aGroupIdAndTheRoomMakeNobodyADirectContact() {
        let group = "g-\(accepted.nodeId)"
        #expect(ids(accepted: [group, Conversations.nearby], authored: [group, Conversations.nearby]).isEmpty)
        // Not a canonical node id: the other case, or one character short. A DM thread is keyed by the id itself.
        let text = accepted.nodeId.string
        let others = Set([text.uppercased(), text.lowercased(), String(text.dropLast())]).subtracting([text])
        #expect(others.count == 2)
        #expect(ids(accepted: others).isEmpty)
    }

    @Test func aBlockOutranksEverySignal() {
        let all: Set<String> = [accepted.nodeId.string]
        #expect(ids(accepted: all, verified: [accepted.nodeId], authored: all, blocked: [accepted.nodeId]).isEmpty)
    }

    @Test func weAreNeverOurOwnDirectContact() {
        #expect(ids(accepted: [me.nodeId.string], verified: [me.nodeId], authored: [me.nodeId.string]).isEmpty)
    }

    /// The read over the stores: each source counts, a block by id or by the device tag a peer's row carries removes them,
    /// and neither an un-verify nor a chat's delete does, since both keep the thread accepted.
    @Test func theEngineReadsTheStoresAndResolvesABlockedDeviceTag() throws {
        let fixture = EngineFixture(me)
        let tagged = TestPeer(seed: 5)
        for peer in [accepted, verified, authored] {
            try fixture.pin(peer)
        }
        fixture.deliver(try tagged.profile(publishedAt: fixture.clock.wallMilliseconds(), deviceTag: "a1b2c3d4e5f60718"), from: tagged)
        fixture.engine.accept(accepted.nodeId.string)
        fixture.engine.accept(tagged.nodeId.string)
        fixture.engine.setVerified(verified.nodeId, true)
        _ = try #require(fixture.engine.sendDirectMessage("hi", to: authored.nodeId))
        #expect(fixture.engine.directContacts() == [accepted.nodeId, verified.nodeId, authored.nodeId, tagged.nodeId])
        // Another id carrying the same tag was blocked: the tag takes the contact out, as its row names it.
        fixture.stores.blocks.block(TestPeer(seed: 6).nodeId, deviceTag: "a1b2c3d4e5f60718")
        #expect(fixture.engine.directContacts() == [accepted.nodeId, verified.nodeId, authored.nodeId])
        fixture.engine.setVerified(verified.nodeId, false)
        #expect(fixture.engine.deleteChat(authored.nodeId.string))
        #expect(fixture.engine.directContacts() == [accepted.nodeId, verified.nodeId, authored.nodeId], "keepAccepted")
        fixture.engine.block(accepted.nodeId)
        #expect(fixture.engine.directContacts() == [verified.nodeId, authored.nodeId])
    }
}
