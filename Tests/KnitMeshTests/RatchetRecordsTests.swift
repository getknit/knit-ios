import KnitCrypto
import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// `RatchetRecords` maps every field both ways, and both stores keep each one: the engine's `seal` answers `nil` for a
/// session missing its send chain or, unconfirmed, its init, so a field lost on the way would quietly turn every DM to
/// v1 (the P4b review; `RatchetRepositoryTest.sessionRoundTripsEveryField` in knit-next).
@Suite struct RatchetRecordsTests {
    enum Kind: CaseIterable, Sendable {
        case memory
        case sql

        func store() throws -> any RatchetStore {
            switch self {
            case .memory:
                MemoryRatchetStore()
            case .sql:
                SQLRatchetStore(try KnitDatabase.inMemory { error in Issue.record("the database failed: \(error)") })
            }
        }
    }

    private let peer = fixtureNodeId(2)

    @Test(arguments: Kind.allCases)
    func everySessionFieldSurvivesTheEngineToTheStoreAndBack(kind: Kind) throws {
        let store = try kind.store()
        let full = RatchetEngine.SessionState(
            peerId: peer,
            confirmed: true,
            weAreInitiator: true,
            root: fixtureBytes(32, seed: 1),
            prevRoot: fixtureBytes(32, seed: 2),
            prevRootWeAreInitiator: true,
            prevRootExpiresAt: 3,
            establishedAt: 4,
            initEphPub: fixtureBytes(32, seed: 5),
            initPkid: 6,
            peerInitEphPub: fixtureBytes(32, seed: 7),
            peerBasePub: fixtureBytes(32, seed: 8),
            peerBaseEpoch: 9,
            sendEpoch: 10,
            sendEpochPub: fixtureBytes(32, seed: 11),
            sendChainKey: fixtureBytes(32, seed: 12),
            sendCount: 13,
            sendEpochStartedAt: 14,
            sendEpochBaseEpoch: 15,
            highestPeAcked: 16,
            lastResetSentAt: 17
        )
        store.upsertSession(RatchetRecords.record(full))
        #expect(store.session(peer).map(RatchetRecords.session) == full)

        let bare = RatchetEngine.SessionState(
            peerId: peer, confirmed: false, weAreInitiator: false, root: fixtureBytes(32, seed: 18), establishedAt: 19)
        store.upsertSession(RatchetRecords.record(bare))
        #expect(store.session(peer).map(RatchetRecords.session) == bare, "every flag false and every optional absent comes back so")
    }

    /// The fields `seal` needs come back: a session the engine started, unconfirmed with its init, seals after the trip
    /// with its init still riding.
    @Test(arguments: Kind.allCases)
    func aStartedSessionStillSealsWithItsInitAfterTheTrip(kind: Kind) throws {
        let store = try kind.store()
        let (alice, bob) = (IdentityKeys.generate(), IdentityKeys.generate())
        let signed = try SignedPrekey.mint(id: 1, signedBy: bob, createdAt: 0)
        let prekey = try #require(PeerPrekey(verifying: signed.info, signedBy: bob.bundle))
        let engine = RatchetEngine()
        let initiation = try engine.initiate(peerId: bob.nodeId, identity: alice, peerIdentity: bob.bundle, peerPrekey: prekey, now: 1)
        store.commitSend(RatchetRecords.record(initiation.session), newLocalEpoch: RatchetRecords.record(initiation.epoch))
        let back = try #require(store.session(bob.nodeId).map(RatchetRecords.session))
        #expect(back == initiation.session)
        let sealed = try #require(try engine.seal(back, plaintext: [1], aad: [], peerPrekey: nil, now: 2))
        #expect(sealed.header.initial?.eph == initiation.session.initEphPub)
        let epoch = try #require(store.records(of: bob.nodeId).localEpochs.first)
        #expect(RatchetRecords.localEpoch(epoch) == initiation.epoch)
    }

    @Test func anOpensDeltaMapsEveryRowAndBack() throws {
        let (alice, bob) = (IdentityKeys.generate(), IdentityKeys.generate())
        let signed = try SignedPrekey.mint(id: 1, signedBy: bob, createdAt: 0)
        let prekey = try #require(PeerPrekey(verifying: signed.info, signedBy: bob.bundle))
        let engine = RatchetEngine()
        let initiation = try engine.initiate(peerId: bob.nodeId, identity: alice, peerIdentity: bob.bundle, peerPrekey: prekey, now: 1)
        let first = try #require(try engine.seal(initiation.session, plaintext: [1], aad: [], peerPrekey: prekey, now: 1))
        let second = try #require(try engine.seal(first.session, plaintext: [2], aad: [], peerPrekey: prekey, now: 1))
        let fresh = RatchetEngine.OpenContext(
            selfNodeId: bob.nodeId,
            peerId: alice.nodeId,
            session: nil,
            recvEpochs: [],
            skippedKeys: [],
            ownBasePrivateKey: nil,
            identity: bob,
            peerIdentity: alice.bundle,
            prekeyForInit: signed
        )
        // The second frame first: it banks a key for the first.
        guard case .opened(let opened) = try engine.open(fresh, header: second.header, nonce: second.nonce, ct: second.ct, aad: [], now: 2)
        else {
            Issue.record("the second frame opens")
            return
        }
        let delta = RatchetRecords.record(opened.delta)
        #expect(RatchetRecords.session(delta.session) == opened.delta.session)
        #expect(delta.recvEpoch.map(RatchetRecords.recvEpoch) == opened.delta.recvEpoch)
        #expect(delta.skippedInserts.map(RatchetRecords.skippedKey) == opened.delta.skippedInserts)
        #expect(delta.skippedInserts.count == 1 && delta.consumedSkippedTag == nil && !delta.purgePeerRecvState)

        var banked = fresh
        banked.session = opened.delta.session
        banked.skippedKeys = opened.delta.skippedInserts
        guard case .opened(let late) = try engine.open(banked, header: first.header, nonce: first.nonce, ct: first.ct, aad: [], now: 3)
        else {
            Issue.record("the first frame opens on its banked key")
            return
        }
        #expect(RatchetRecords.record(late.delta).consumedSkippedTag == late.delta.consumedSkippedTag)
        #expect(late.delta.consumedSkippedTag != nil)
    }
}
