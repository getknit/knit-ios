import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What the engine gives the control surface of the ratchet (ADR 2026-10.5sk9): every pinned peer's state in the shape of
/// Android's `RATCHET` dump, and a forced reset, sealed, persisted and then flooded since phase P5a, behind the gates
/// Android's `sendSessionReset` names (`MeshManager.kt:906-929`, `InboundPipeline.kt:1902-1961`).
@Suite struct MeshEngineRatchetTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private func ratchetEngine(stores: MeshStores = .inMemory()) -> EngineFixture {
        EngineFixture(me, stores: stores, configuration: MeshConfiguration(ratchet: true), started: false)
    }

    private func pin(_ peer: TestPeer, in stores: MeshStores, capabilities: Int64? = 0x15F, prekey: PrekeyInfo?, publicKey: String? = nil) {
        stores.peers.upsert(
            PeerRecord(
                nodeId: peer.nodeId,
                name: "\(peer.nodeId)",
                status: "",
                publicKey: publicKey ?? peer.keys.bundle.encoded,
                capabilities: capabilities,
                updatedAt: 1,
                prekey: prekey,
                prekeyProfileAt: 1
            )
        )
    }

    @Test func everyPinnedPeerIsListedWithItsSessionAndOurEpochs() throws {
        let fixture = ratchetEngine()
        pin(bob, in: fixture.stores, prekey: try bob.prekey(id: 3))
        pin(carol, in: fixture.stores, capabilities: 0xF, prekey: nil)
        guard case .sent(_, reRooted: true) = fixture.engine.sendRatchetReset(to: bob.nodeId) else {
            Issue.record("a reset toward a capable peer with a prekey seals a fresh root")
            return
        }
        let peers = fixture.engine.ratchetPeers()
        #expect(peers.map(\.peer) == [bob.nodeId, carol.nodeId].sorted())
        let start = EngineFixture.start
        let withBob = try #require(peers.first { $0.peer == bob.nodeId })
        #expect(withBob.capRatchet && withBob.peerPrekeyId == 3 && withBob.peerPrekeyPinned)
        #expect(withBob.hasSession && !withBob.confirmed && withBob.weAreInitiator && withBob.sendEpoch == 1)
        #expect(withBob.lastResetSentAt == start && withBob.establishedAt == start && withBob.highestPeAcked == 0)
        #expect(withBob.prevRootExpiresAt == 0 && !withBob.hasPeerInitAnchor)
        #expect(withBob.localEpochs == [RatchetPeerState.LocalEpoch(epoch: 1, createdAt: start)])
        let root = try #require(fixture.stores.ratchet.session(bob.nodeId)).root
        #expect(withBob.rootHash == String(BlobHash(of: root).string.prefix(8)))
        let withCarol = try #require(peers.first { $0.peer == carol.nodeId })
        #expect(!withCarol.capRatchet && withCarol.peerPrekeyId == nil && !withCarol.peerPrekeyPinned && !withCarol.hasSession)
        #expect(withCarol.rootHash == nil && withCarol.localEpochs.isEmpty && withCarol.sendEpoch == 0)
        #expect(fixture.transport.written(.chat).map(\.envelope.recipientId) == [bob.nodeId.string], "the reset, flooded")
    }

    /// The root goes out only as the first eight hex digits of its SHA-256 (`ROOT_HASH_HEX_CHARS`, `MeshManager.kt:3447`).
    @Test func theRootIsShownOnlyAsItsHash() {
        let session = RatchetEngine.SessionState(
            peerId: bob.nodeId,
            confirmed: true,
            weAreInitiator: false,
            root: [UInt8](repeating: 1, count: 32),
            prevRootExpiresAt: 5,
            establishedAt: 6,
            peerInitEphPub: [2],
            highestPeAcked: 4,
            lastResetSentAt: 7
        )
        let record = PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "", publicKey: "key", updatedAt: 1)
        let state = RatchetPeerState(peer: record, session: session, localEpochs: [(epoch: 2, createdAt: 9), (epoch: 1, createdAt: 8)])
        #expect(state.rootHash == "72cd6e84")
        #expect(state.name == "Bob" && !state.capRatchet && state.confirmed && !state.weAreInitiator && state.hasPeerInitAnchor)
        #expect(state.highestPeAcked == 4 && state.prevRootExpiresAt == 5 && state.establishedAt == 6 && state.lastResetSentAt == 7)
        #expect(state.localEpochs.map(\.epoch) == [2, 1])
    }

    @Test func aForcedResetIsRefusedInAndroidsWordsAtEachGate() throws {
        let off = EngineFixture(me, started: false)
        pin(bob, in: off.stores, prekey: try bob.prekey(id: 1))
        #expect(off.engine.sendRatchetReset(to: bob.nodeId) == .declined("the ratchet is off"))
        #expect(off.stores.ratchet.session(bob.nodeId) == nil, "the switch keeps every peer from the ratchet")

        let fixture = ratchetEngine()
        let stores = fixture.stores
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("no peer row"))
        pin(bob, in: stores, capabilities: 0xF, prekey: try bob.prekey(id: 1))
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("peer is not ratchet-capable"))
        pin(bob, in: stores, capabilities: nil, prekey: try bob.prekey(id: 1))
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("peer is not ratchet-capable"))
        pin(bob, in: stores, prekey: try bob.prekey(id: 1), publicKey: "not a bundle")
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("no pinned pubKey"))
        pin(bob, in: stores, prekey: nil)
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("no pinned prekey id"))
        pin(bob, in: stores, prekey: try carol.prekey(id: 1))
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("no pinned prekey pub"), "signed by someone else")
        let lowOrder = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)
        let signature = try bob.keys.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: lowOrder))
        pin(bob, in: stores, prekey: PrekeyInfo(id: 1, pub: lowOrder, sig: signature))
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("sealResetDm refused (unusable prekey)"))
        #expect(stores.ratchet.session(bob.nodeId) == nil)

        pin(bob, in: stores, prekey: try bob.prekey(id: 1))
        guard case .sent(let envelope, reRooted: true) = fixture.engine.sendRatchetReset(to: bob.nodeId) else {
            Issue.record("past the gates it seals")
            return
        }
        #expect(envelope.version == EncEnvelope.Version.ratchet && envelope.ratchet?.flags == RatchetHeader.resetFlag)
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("our reset is still on its way"))
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(fixture.transport.written(.chat).count == 1, "a decline sends nothing")
        #expect(sent.envelope.recipientId == bob.nodeId.string && sent.wire.relay)
        #expect(try ChatContent(decoding: sent.envelope.payload).enc == envelope, "the envelope it sealed, as it sealed it")
        #expect(bob.keys.bundle.isValidSignature(sent.wire.sig, for: sent.wire.signed) == false, "signed by us, not the peer")
        #expect(me.keys.bundle.isValidSignature(sent.wire.sig, for: sent.wire.signed))
        #expect(fixture.stores.custody.contains(sent.envelope.id), "carried as our own frame")
        #expect(fixture.stores.messages.message(sent.envelope.id) == nil, "a reset has no row")
        #expect(fixture.log.all.contains { $0.contains("ratchet reset to \(bob.nodeId) sent under a fresh root") })
    }

    @Test func aForcedResetWhoseStoreFailsSealsNothing() throws {
        let refusing = RefusingRatchetStore()
        let memory = MeshStores.inMemory()
        let stores = MeshStores(
            custody: memory.custody,
            peers: memory.peers,
            messages: memory.messages,
            conversations: memory.conversations,
            blocks: memory.blocks,
            groups: memory.groups,
            ownProfile: memory.ownProfile,
            blobs: memory.blobs,
            ratchet: refusing,
            transactor: refusing.transactor
        )
        let fixture = ratchetEngine(stores: stores)
        pin(bob, in: stores, prekey: try bob.prekey(id: 1))
        refusing.refuse(.writes)
        #expect(fixture.engine.sendRatchetReset(to: bob.nodeId) == .declined("the store failed"))
        refusing.refuse([])
        #expect(stores.ratchet.session(bob.nodeId) == nil)
    }
}
