import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The presence keys' receive side in the engine (ADR 2026-11.sv5t): a ctl 11 an Android phone seals over the ratchet,
/// point to point, is filed for its sender inside the open's unit (`applyPresenceKey`, `InboundPipeline.kt:1959-1974` at
/// knit-next `cad69c77b`), and only the direct contacts' keys are listed to the radio (`MeshManager.feedPresenceKeys`), a
/// leaver's deleted (`PresenceKeyEngine.dropLeavers`). `PresenceKeyForkLabTest`'s stranger case (`:54`, `:75`, `:166`) and
/// `PresenceKeyLabTest`'s carrier (`:381`) are ported here.
@Suite struct MeshEnginePresenceKeyTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    /// A key of 32 bytes, each `byte`.
    private static func key(_ byte: UInt8) -> [UInt8] {
        [UInt8](repeating: byte, count: PresenceKey.byteCount)
    }

    /// The iPhone with the switch on and Alice's Android pinned; `accepted` accepts her thread.
    private func rig(stores: MeshStores = .inMemory(), accepted: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        if accepted {
            fixture.engine.accept(alice.nodeId.string)
        }
        // The session's first listing, which the mesh makes at its start, before any frame.
        fixture.engine.feedPresenceKeys()
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// Alice's ctl 11 handing over `keys`, padded as Android pads it, sent point to point as Android sends one.
    private func keyFrame(
        _ android: AndroidPeer, _ keys: [(generation: Int64, key: [UInt8])], _ fixture: EngineFixture, id: String, sentAt: Int64? = nil
    ) throws -> TestFrame {
        try android.dm(
            PresenceKeyFrame.content(keys), to: me, prekey: try fixture.ourPrekey(), id: frameIdOf(id), sentAt: sentAt ?? now, relay: false)
    }

    /// The keys the engine listed last, as raw bytes.
    private func listed(_ fixture: EngineFixture) -> [NodeId: [[UInt8]]]? {
        fixture.engine.feedPresenceKeys()
        return fixture.transport.presenceKeyListings.last?.mapValues { $0.map(\.bytes) }
    }

    private func held(_ fixture: EngineFixture, _ peer: TestPeer) -> [Int64] {
        fixture.stores.presenceKeys.keys(of: peer.nodeId).map(\.held.generation)
    }

    @Test func androidsFrameIsTheSizeItPadsTo() {
        let one = PresenceKeyFrame.content([(generation: now, key: Self.key(1))])
        let two = PresenceKeyFrame.content([(generation: now, key: Self.key(1)), (generation: now + 1, key: Self.key(2))])
        #expect(one.encoded.count == PresenceKeyFrame.plaintextBytes && two.encoded.count == PresenceKeyFrame.plaintextBytes)
        #expect(one.sealBytes(v3: true).scheme == EncEnvelope.Version.ratchet, "a ctl 11 has no compact form: v2, named")
    }

    @Test func aKeyFromAContactIsStoredAndListed() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try keyFrame(android, [(now, Self.key(1)), (now + 1, Self.key(2))], fixture, id: "pk-1"), from: android)
        #expect(held(fixture, alice) == [now + 1, now])
        #expect(listed(fixture) == [alice.nodeId: [Self.key(2), Self.key(1)]])
        #expect(fixture.engine.presenceKeyCounts.stored == 1)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [1], "committed, its index spent")
        #expect(fixture.stores.messages.message(frameIdOf("pk-1")) == nil, "a ctl is never a row")
        #expect(fixture.engine.dropped.isEmpty && fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.sealedReceipts(to: android).isEmpty, "never acknowledged")
        #expect(!fixture.stores.custody.contains(frameIdOf("pk-1")), "point to point: never carried")
        #expect(!fixture.log.all.contains { $0.contains("presence key") && $0.contains(alice.nodeId.string) && !$0.hasPrefix("debug") })
        // Opened again, it is the same keys: nothing moves.
        fixture.deliver(try keyFrame(android, [(now, Self.key(1)), (now + 1, Self.key(2))], fixture, id: "pk-1b"), from: android)
        #expect(fixture.engine.presenceKeyCounts.stored == 1)
    }

    /// `PresenceKeyForkLabTest`'s stranger (`:54`, `:75`, `:166`): a key from someone with a peer row who is no contact is
    /// stored, as Android stores it, and listed only once the user accepts them.
    @Test func aStrangersKeyIsStoredButListedOnlyOnceAccepted() throws {
        let (fixture, android) = try rig(accepted: false)
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-s"), from: android)
        #expect(held(fixture, alice) == [now])
        #expect(listed(fixture)?.isEmpty == true)
        fixture.engine.accept(alice.nodeId.string)
        #expect(listed(fixture) == [alice.nodeId: [Self.key(1)]])
    }

    /// The sender is the verified one the open ran for. One with no peer row cannot reach the open, which needs its
    /// bundle, and we never open our own frames, so both refusals are checked at the arm.
    @Test func aKeyFromNobodyPinnedOrFromUsIsRefused() throws {
        let (fixture, _) = try rig()
        let payload = PresenceKeyPayload(generation: 5, key: Self.key(1))
        let under = OpenedUnder(rootTag: 1, active: true)
        #expect(fixture.engine.applyPresenceKey(payload, from: carol.nodeId, under: under) == .refused(.unknownSender))
        #expect(fixture.engine.applyPresenceKey(payload, from: me.nodeId, under: under) == .refused(.unknownSender))
        #expect(fixture.engine.applyPresenceKey(nil, from: alice.nodeId, under: under) == nil)
        #expect(fixture.stores.presenceKeys.peersWithKeys().isEmpty)
    }

    @Test func aRefusedKeyChangesNothingAndTheChainStillAdvances() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-a"), from: android)
        _ = listed(fixture)
        let listings = fixture.transport.presenceKeyListings.count
        // Same era: lower is OLDER, the same generation with other bytes CONFLICT.
        fixture.deliver(try keyFrame(android, [(now - 1, Self.key(3))], fixture, id: "pk-b"), from: android)
        fixture.deliver(try keyFrame(android, [(now, Self.key(4))], fixture, id: "pk-c"), from: android)
        #expect(fixture.engine.dropped == [.presenceKeyRefused: 2])
        #expect(held(fixture, alice) == [now] && fixture.stores.presenceKeys.keys(of: alice.nodeId).first?.held.key.bytes == Self.key(1))
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [3], "every refused frame committed its chain")
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.count == listings, "nothing to list again")
        #expect(fixture.log.all.contains { $0.contains("mesh presence key refused: OLDER") })
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    /// A ctl 11 whose `pk` is the empty map is no key, as kotlinx reads it; one whose `g` kotlinx wraps negative is
    /// malformed. Neither stores anything, and both advance the chain.
    @Test func anEmptyOrWrappedPayloadChangesNothingAndAdvancesTheChain() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        func sealing(_ pk: CBOR, id: String) throws -> TestFrame {
            guard case .map(var entries) = MessageContent(body: "", ctl: MessageContent.Control.presenceKey).cbor else {
                throw AndroidPeer.Refused()
            }
            entries.append(CBOR.Entry(key: .text("pk"), value: pk))
            return try android.dm(sealing: CBOR.map(entries).encoded, to: me, prekey: prekey, id: frameIdOf(id), sentAt: now, relay: false)
        }
        fixture.deliver(try sealing(.map([]), id: "pk-empty"), from: android)
        let wrapped = CBOR.map([
            CBOR.Entry(key: .text("g"), value: .unsigned(1 << 63)), CBOR.Entry(key: .text("k"), value: .bytes(Self.key(1))),
        ])
        fixture.deliver(try sealing(wrapped, id: "pk-wrapped"), from: android)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [2])
        #expect(fixture.engine.dropped == [.presenceKeyRefused: 1], "the wrapped one, MALFORMED")
        #expect(fixture.log.all.contains { $0.contains("mesh presence key refused: MALFORMED") })
        #expect(fixture.stores.presenceKeys.peersWithKeys().isEmpty)
    }

    /// A block unlists the contact and deletes their keys at the next listing, writing counts and no line.
    @Test func aBlockUnlistsTheContactAndDeletesTheirKeys() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-1"), from: android)
        #expect(listed(fixture) == [alice.nodeId: [Self.key(1)]])
        let lines = fixture.log.all.count
        fixture.engine.block(alice.nodeId)
        #expect(listed(fixture)?.isEmpty == true)
        #expect(fixture.stores.presenceKeys.peersWithKeys().isEmpty)
        #expect(fixture.engine.presenceKeyCounts.leavers == 1)
        #expect(!fixture.log.all.dropFirst(lines).contains { $0.contains("presence") }, "no dated line says when the user blocked")
        // An unblock lists nothing until a key comes again: the block deleted it.
        fixture.engine.unblock(alice.nodeId)
        #expect(listed(fixture)?.isEmpty == true)
    }

    /// A block covers the device tag the contact's row carries (`isBlocked(deviceTag:)`): every listed contact whose row
    /// carries it, such as the same person under keys they made again, is unlisted at once, before any feed, and their keys
    /// go at the next listing, while a contact under another tag stays listed. `DirectContactsTest.aBlockOutranksEverySignal`'s
    /// `blockedByTag` case (`DirectContactsTest.kt:66-71` at knit-next `cad69c77b`), through the listing.
    @Test func aBlockByDeviceTagUnlistsEveryRowCarryingItAndDeletesTheirKeys() throws {
        let (fixture, android) = try rig()
        let rekeyed = try AndroidPeer(TestPeer(seed: 4))
        let other = try AndroidPeer(carol)
        for peer in [rekeyed, other] {
            try fixture.pin(peer)
            fixture.engine.accept(peer.peer.nodeId.string)
        }
        let tag = "a1b2c3d4e5f60718"
        for (peer, deviceTag) in [(alice, tag), (rekeyed.peer, tag), (carol, "0f0e0d0c0b0a0908")] {
            var row = try #require(fixture.stores.peers.peer(peer.nodeId))
            row.deviceTag = deviceTag
            fixture.stores.peers.upsert(row)
        }
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-a"), from: android)
        fixture.deliver(try keyFrame(rekeyed, [(now, Self.key(2))], fixture, id: "pk-r"), from: rekeyed)
        fixture.deliver(try keyFrame(other, [(now, Self.key(3))], fixture, id: "pk-c"), from: other)
        #expect(listed(fixture).map { Set($0.keys) } == Set([alice, rekeyed.peer, carol].map(\.nodeId)))
        let listings = fixture.transport.presenceKeyListings.count
        fixture.engine.block(alice.nodeId)
        #expect(fixture.transport.presenceKeyListings.count == listings + 1, "unlisted at once")
        #expect(fixture.transport.presenceKeyListings.last?.mapValues { $0.map(\.bytes) } == [carol.nodeId: [Self.key(3)]])
        #expect(fixture.stores.blocks.isBlocked(deviceTag: tag) && !fixture.engine.isBlocked(rekeyed.peer.nodeId))
        #expect(listed(fixture) == [carol.nodeId: [Self.key(3)]])
        #expect(fixture.stores.presenceKeys.peersWithKeys() == [carol.nodeId])
        #expect(fixture.engine.presenceKeyCounts.leavers == 2)
    }

    /// A block of someone the last listing does not name, by id or by a device tag no listed row carries, pushes no
    /// listing: there is nothing to unlist at once (the radio's `KeyChurnLimiter` sees no change), and the contacts listed
    /// stay listed.
    @Test func aBlockOfSomeoneUnlistedPushesNoListing() throws {
        let (fixture, android) = try rig()
        let stranger = try AndroidPeer(carol)
        try fixture.pin(stranger)
        var row = try #require(fixture.stores.peers.peer(carol.nodeId))
        row.deviceTag = "0f0e0d0c0b0a0908"
        fixture.stores.peers.upsert(row)
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-a"), from: android)
        #expect(listed(fixture) == [alice.nodeId: [Self.key(1)]])
        let listings = fixture.transport.presenceKeyListings.count
        fixture.engine.block(carol.nodeId)
        fixture.engine.block(TestPeer(seed: 5).nodeId)
        #expect(fixture.transport.presenceKeyListings.count == listings, "nothing to unlist")
        #expect(listed(fixture) == [alice.nodeId: [Self.key(1)]])
    }

    /// A session's first pass deletes every non-contact's keys (`dropLeavers`, `before == null`), and nothing else.
    @Test func aSessionsFirstPassDeletesEveryNonContactsKeys() throws {
        let stores = MeshStores.inMemory()
        let stranger = TestPeer(seed: 5)
        let tagged = PresenceKeyPolicy.keysIn(PresenceKeyPayload(generation: 9, key: Self.key(9)))?.first
        let key = try #require(tagged?.key)
        stores.presenceKeys.replaceKeys(of: stranger.nodeId, with: [HeldPresenceKey(generation: 9, key: key, rootTag: 1)], now: 1)
        stores.presenceKeys.replaceKeys(of: alice.nodeId, with: [HeldPresenceKey(generation: 9, key: key, rootTag: 1)], now: 1)
        stores.conversations.accept(alice.nodeId.string)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        #expect(stores.presenceKeys.peersWithKeys() == [stranger.nodeId, alice.nodeId].sorted(), "nothing deleted before the listing")
        #expect(listed(fixture) == [alice.nodeId: [Self.key(9)]])
        #expect(stores.presenceKeys.peersWithKeys() == [alice.nodeId])
        #expect(fixture.engine.presenceKeyCounts.leavers == 1)
        #expect(!fixture.log.all.contains { $0.contains("presence") }, "counts only")
        // A later pass deletes only those who left: a stranger's key stored meanwhile waits for the next session.
        stores.presenceKeys.replaceKeys(of: stranger.nodeId, with: [HeldPresenceKey(generation: 9, key: key, rootTag: 1)], now: 2)
        fixture.engine.accept(carol.nodeId.string)
        _ = listed(fixture)
        #expect(stores.presenceKeys.peersWithKeys() == [stranger.nodeId, alice.nodeId].sorted())
        fixture.engine.startPresenceKeySession()
        _ = listed(fixture)
        #expect(stores.presenceKeys.peersWithKeys() == [alice.nodeId], "a new session's first pass")
    }

    /// A carrier between two peers keeps no ctl 11 (`PresenceKeyLabTest.kt:381`): it is point to point, so custody never
    /// takes it, nothing floods it, and its keys are nobody's here. Linked to its addressee, the carrier hands it that one
    /// hop, as every point-to-point DM-form chat (ADR 2026-09.wkbk), and still keeps nothing.
    @Test func aCarrierKeepsNoKeyFrameForOthers() throws {
        let (fixture, android) = try rig()
        let carolPrekey = try #require(PeerPrekey(verifying: try carol.prekey(id: 1), signedBy: carol.keys.bundle))
        func frame(_ id: String) throws -> TestFrame {
            let content = PresenceKeyFrame.content([(generation: now, key: Self.key(1))])
            return try android.dm(content, to: carol, prekey: carolPrekey, id: frameIdOf(id), sentAt: now, relay: false)
        }
        fixture.deliver(try frame("pk-carol"), from: android)
        fixture.advance(1000)
        #expect(!fixture.stores.custody.contains(frameIdOf("pk-carol")))
        #expect(!fixture.transport.written.contains { $0.envelope.id == frameIdOf("pk-carol") }, "never flooded")
        fixture.link(carol)
        fixture.deliver(try frame("pk-carol-2"), from: android)
        fixture.advance(1000)
        #expect(fixture.transport.written.filter { $0.envelope.id == frameIdOf("pk-carol-2") }.map(\.to) == [carol.nodeId])
        #expect(!fixture.stores.custody.contains(frameIdOf("pk-carol-2")))
        #expect(fixture.stores.presenceKeys.peersWithKeys().isEmpty)
    }

    /// The open's unit fails on the key's write: nothing is stored or counted, the copy is kept, and the replay at the next
    /// sweep stores it, once the store heals.
    @Test func aFailedUnitStoresNoKeyAndTheReplayStoresIt() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let (fixture, android) = try rig(stores: memory.replacing(presenceKeys: refusing))
        refusing.refusesWrites = true
        fixture.deliver(try keyFrame(android, [(now, Self.key(1))], fixture, id: "pk-f"), from: android)
        #expect(fixture.engine.dropped == [.storeRefused: 1])
        #expect(fixture.stores.presenceKeys.peersWithKeys().isEmpty && fixture.engine.presenceKeyCounts.stored == 0)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.isEmpty, "the chain's advance went with it")
        refusing.refusesWrites = false
        fixture.advance(sweep)
        #expect(held(fixture, alice) == [now])
        #expect(fixture.engine.presenceKeyCounts.stored == 1)
        #expect(listed(fixture) == [alice.nodeId: [Self.key(1)]])
    }

    /// A store read failing at the first pass deletes nothing and lists nothing; the next pass, the store healed, does both.
    @Test func aFailedReadAtTheFirstPassDeletesAndListsNothing() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let stranger = TestPeer(seed: 5)
        let key = try #require(PresenceKey(bytes: Self.key(9)))
        memory.presenceKeys.replaceKeys(of: stranger.nodeId, with: [HeldPresenceKey(generation: 9, key: key, rootTag: 1)], now: 1)
        refusing.refusesReads = true
        let fixture = try EngineFixture.ratcheting(me, stores: memory.replacing(presenceKeys: refusing))
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.isEmpty)
        #expect(memory.presenceKeys.peersWithKeys() == [stranger.nodeId])
        #expect(fixture.log.all.contains { $0.contains("mesh presence key listing skipped: a store failed") })
        refusing.refusesReads = false
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.count == 1)
        #expect(memory.presenceKeys.peersWithKeys().isEmpty)
    }
}

/// A presence key store over the memory one a ``MemoryTransactor`` covers, refusing its writes or its reads when told to:
/// inside a unit the refusal fails the unit, as a database error does, and outside one the read answers nothing held.
final class RefusingPresenceKeys: PresenceKeyStore, @unchecked Sendable {
    private let held: any PresenceKeyStore
    private let unit: MemoryTransactor
    private let flags = Lock((writes: false, reads: false))

    init(_ stores: MeshStores) throws {
        held = stores.presenceKeys
        unit = try #require(stores.transactor as? MemoryTransactor)
    }

    var refusesWrites: Bool {
        get { flags.withLock { $0.writes } }
        set { flags.withLock { $0.writes = newValue } }
    }

    var refusesReads: Bool {
        get { flags.withLock { $0.reads } }
        set { flags.withLock { $0.reads = newValue } }
    }

    func keys(of peer: NodeId) -> [StoredPresenceKey] {
        guard !refusesReads else {
            unit.failCurrentUnit()
            return []
        }
        return held.keys(of: peer)
    }

    func replaceKeys(of peer: NodeId, with rows: [HeldPresenceKey], now: Int64) {
        guard !refusesWrites else {
            unit.failCurrentUnit()
            return
        }
        held.replaceKeys(of: peer, with: rows, now: now)
    }

    func peersWithKeys() -> [NodeId] {
        guard !refusesReads else {
            unit.failCurrentUnit()
            return []
        }
        return held.peersWithKeys()
    }

    func deleteKeys(of peers: Set<NodeId>) {
        guard !refusesWrites else {
            unit.failCurrentUnit()
            return
        }
        held.deleteKeys(of: peers)
    }
}

extension MeshStores {
    /// These stores with the presence keys' swapped for `presenceKeys`, a wrapper over the store the transactor was made
    /// over, so a unit that is undone still puts it back.
    func replacing(presenceKeys: any PresenceKeyStore) -> Self {
        MeshStores(
            custody: custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet,
            groupRatchet: groupRatchet,
            presenceKeys: presenceKeys,
            transactor: transactor
        )
    }
}
