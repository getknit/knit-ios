import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Add contact through the engine (ADR 2026-10.tpr5): a card's key pinned from a link (`ContactImporter.import`,
/// `MeshManager.importContact`) or a scanned code (`AddContactViewModel.onScanned`). The pin starts from the row held, so a
/// profile pinned before keeps everything it set; it releases the frames parked for the key and nothing else that waits
/// for the profile; and the profile that comes after applies in full.
@Suite struct MeshEngineContactTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// `peer`'s card as their own engine would sign it, with `name`.
    private func card(of peer: TestPeer, name: String = "Bob") throws -> ContactCard.Card {
        let links = try #require(ContactCard.encode(peer.keys, name: name, issuedAt: now))
        return try #require(ContactCard.parse(links.url).card)
    }

    /// An engine for `me` with Carol linked as a neighbour, and what linking wrote cleared.
    private func linked(stores: MeshStores = .inMemory()) -> EngineFixture {
        let fixture = EngineFixture(me, stores: stores)
        fixture.link(carol)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// The key requests written to Carol, by the ids they ask for.
    private func keyRequests(_ fixture: EngineFixture) throws -> [String] {
        try fixture.transport.written(.keyRequest).flatMap { try KeyRequestContent(decoding: $0.envelope.payload).nodeIds }
    }

    /// Bob's profile with the ratchet's bits, prekey 1, a device tag and a photo, published at `at`.
    private func ratchetProfile(at stamp: Int64, name: String = "Bob") throws -> TestFrame {
        try bob.profile(
            name: name,
            publishedAt: stamp,
            deviceTag: "aabbccddeeff0011",
            capabilities: AndroidPeer.capabilities,
            prekey: try bob.prekey(id: 1)
        )
    }

    // MARK: Our own card

    @Test(arguments: [ContactSource.scan, .link])
    func ourOwnCardWritesNothingAndAsksForNothing(source: ContactSource) throws {
        let fixture = linked()
        fixture.engine.block(carol.nodeId)
        let ours = try card(of: me)
        #expect(fixture.engine.addContact(ours, from: source, unblock: true) == .ownCode)
        #expect(fixture.stores.peers.peer(me.nodeId) == nil)
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty)
        #expect(fixture.transport.written.isEmpty, "no key request, nothing at all")
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.stores.blocks.blockedNodeIds() == [carol.nodeId], "no block touched")
    }

    // MARK: Refusals

    /// A different key held for the id refuses the card, both ways, and nothing is written. A real card cannot meet one, as
    /// its id is its key's hash, so the row is planted.
    @Test(arguments: [ContactSource.scan, .link])
    func aDifferentKeyHeldIsAMismatchAndNothingIsWritten(source: ContactSource) throws {
        let fixture = linked()
        let planted = PeerRecord(nodeId: bob.nodeId, name: "", status: "", publicKey: carol.keys.bundle.encoded, updatedAt: 5)
        fixture.stores.peers.upsert(planted)
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.addContact(try card(of: bob), from: source, unblock: true) == .mismatch(bob.nodeId))
        #expect(fixture.stores.peers.peer(bob.nodeId) == planted)
        #expect(fixture.stores.blocks.blockedNodeIds() == [bob.nodeId], "not even the unblock")
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty && fixture.transport.written.isEmpty)
    }

    /// A card made by hand whose bundle does not derive to its id is refused here too.
    @Test func aCardWhoseBundleDoesNotCertifyItsIdFails() {
        let fixture = linked()
        let forged = ContactCard.Card(nodeId: bob.nodeId, bundle: carol.keys.bundle.encoded, name: "Bob", spools: [], issuedAt: 0)
        #expect(fixture.engine.addContact(forged, from: .link, unblock: false) == .failed)
        #expect(fixture.stores.peers.peer(bob.nodeId) == nil && fixture.transport.written.isEmpty)
    }

    /// The store swallows a failed write, so the row is read back: a pin that did not land is a failure, with no accept
    /// and no key request.
    @Test func aPinThatDidNotLandFailsWithNothingSent() throws {
        let memory = MeshStores.inMemory()
        let stores = MeshStores(
            custody: memory.custody,
            peers: DroppingPeerWrites(memory.peers),
            messages: memory.messages,
            conversations: memory.conversations,
            blocks: memory.blocks,
            groups: memory.groups,
            ownProfile: memory.ownProfile,
            blobs: memory.blobs,
            ratchet: memory.ratchet,
            groupRatchet: memory.groupRatchet,
            transactor: memory.transactor
        )
        let fixture = linked(stores: stores)
        #expect(fixture.engine.addContact(try card(of: bob), from: .link, unblock: false) == .failed)
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty)
        #expect(fixture.transport.written.isEmpty)
        #expect(fixture.engine.addContact(try card(of: bob), from: .scan, unblock: false) == .failed)
    }

    // MARK: A scan

    @Test func aScanPinsVerifiedWithNoNameAndSendsNothing() throws {
        let fixture = linked()
        #expect(fixture.engine.addContact(try card(of: bob, name: "Bob"), from: .scan, unblock: false) == .added(bob.nodeId))
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(
            row == PeerRecord(nodeId: bob.nodeId, name: "", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 0, verified: true))
        #expect(fixture.transport.written.isEmpty, "no key request on a scan")
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty, "a scan accepts nothing")
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
    }

    @Test func aScanOfTheKeyHeldOnlyVerifies() throws {
        let fixture = linked()
        fixture.deliver(try ratchetProfile(at: now), from: bob)
        var expected = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(!expected.verified)
        #expect(fixture.engine.addContact(try card(of: bob, name: "Robert"), from: .scan, unblock: false) == .added(bob.nodeId))
        expected.verified = true
        #expect(fixture.stores.peers.peer(bob.nodeId) == expected, "verified, and nothing else moved")
    }

    @Test func aScanReadsNoBlockAndLiftsNone() throws {
        let fixture = linked()
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.addContact(try card(of: bob), from: .scan, unblock: true) == .added(bob.nodeId))
        #expect(fixture.stores.blocks.blockedNodeIds() == [bob.nodeId])
        #expect(fixture.stores.peers.peer(bob.nodeId)?.verified == true)
    }

    // MARK: A link

    @Test func aLinkPinsUnverifiedWithTheCardsNameAcceptsAndAsksForTheProfile() throws {
        let fixture = linked()
        #expect(fixture.engine.addContact(try card(of: bob, name: "  Bob \n Example "), from: .link, unblock: false) == .added(bob.nodeId))
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(
            row == PeerRecord(nodeId: bob.nodeId, name: "Bob Example", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 0)
        )
        #expect(fixture.stores.conversations.acceptedConversations() == [bob.nodeId.string])
        #expect(try keyRequests(fixture) == [bob.nodeId.string])
        #expect(fixture.transport.written(.keyRequest).map(\.to) == [carol.nodeId])
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
    }

    /// The blocking finding the design pass raised: the store replaces whole rows, so an import over a profile already
    /// pinned must start from that row, or the ratchet's bits and prekey go, and the next DM drops to v1.
    @Test func aLinkOverAPinnedRatchetProfileKeepsEverythingItPinned() throws {
        let fixture = linked()
        fixture.deliver(try ratchetProfile(at: now - 10_000), from: bob)
        let before = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(before.prekey != nil && before.deviceTag != nil && before.updatedAt > 0 && before.prekeyProfileAt > 0)
        #expect(fixture.engine.addContact(try card(of: bob, name: "Robert"), from: .link, unblock: false) == .added(bob.nodeId))
        let after = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(after == before, "the stored name outranks the card's, and nothing else moves")
        guard case .ratchet(let plan) = RatchetOutbound.scheme(for: MessageContent(body: "hi"), to: after, ratchet: true) else {
            Issue.record("still the ratchet")
            return
        }
        #expect(plan.prekey != nil)
    }

    @Test func aLinkFillsABlankNameAndKeepsVerified() throws {
        let fixture = linked()
        fixture.deliver(try bob.profile(name: " ", publishedAt: now), from: bob)
        fixture.engine.setVerified(bob.nodeId, true)
        #expect(fixture.engine.addContact(try card(of: bob, name: "Bob"), from: .link, unblock: false) == .added(bob.nodeId))
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Bob" && row.verified)
    }

    @Test func aLinkLiftsABlockOnlyWhenAsked() throws {
        let fixture = linked()
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.addContact(try card(of: bob), from: .link, unblock: false) == .added(bob.nodeId))
        #expect(fixture.stores.blocks.blockedNodeIds() == [bob.nodeId], "pinned, still blocked")
        #expect(fixture.engine.addContact(try card(of: bob), from: .link, unblock: true) == .added(bob.nodeId))
        #expect(fixture.stores.blocks.blockedNodeIds().isEmpty)
    }

    // MARK: What comes after the pin

    /// A pin from a card leaves both watermarks at 0, so the profile that follows applies in full, however old, and the
    /// verification the scan recorded stays.
    @Test func theProfileAfterACardAppliesInFullAndKeepsVerified() throws {
        let fixture = linked()
        #expect(fixture.engine.addContact(try card(of: bob), from: .scan, unblock: false) == .added(bob.nodeId))
        fixture.deliver(try ratchetProfile(at: now - 3_600_000, name: "Bob"), from: bob)
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.verified && row.name == "Bob")
        #expect(row.capabilities == AndroidPeer.capabilities && row.prekey != nil && row.deviceTag == "aabbccddeeff0011")
        #expect(row.updatedAt == now - 3_600_000 && row.prekeyProfileAt == now - 3_600_000, "older than the import, applied")
        #expect(fixture.engine.dropped[.pinChangeRefused] == nil)
    }

    /// A profile can only carry the key its sender's id derives from, so another key under Bob's id never reaches the pin:
    /// verification drops it, and the card's pin stands.
    @Test func anotherKeyUnderTheCardsIdIsStillRefused() throws {
        let fixture = linked()
        #expect(fixture.engine.addContact(try card(of: bob), from: .link, unblock: false) == .added(bob.nodeId))
        let content = ProfileContent(name: "Liar", status: "", pubKey: carol.keys.bundle.encoded)
        let envelope = RelayEnvelope(
            type: .profile, id: "profile-\(bob.nodeId)-9", senderId: bob.nodeId.string, sentAt: now, payload: content.encoded
        )
        fixture.deliver(try carol.signed(envelope), from: carol)
        #expect(fixture.engine.dropped[.keyMismatch] == 1)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.publicKey == bob.keys.bundle.encoded)
    }

    /// Kotlin parity: our DMs waiting for the key wait on for the profile, which says which scheme they go under.
    @Test(arguments: [ContactSource.scan, .link])
    func waitingDmsWaitForTheProfileNotTheCard(source: ContactSource) throws {
        let fixture = linked()
        let waiting = try #require(fixture.engine.sendDirectMessage("hello", to: bob.nodeId))
        #expect(waiting.pendingKey)
        fixture.transport.clear()
        #expect(fixture.engine.addContact(try card(of: bob), from: source, unblock: false) == .added(bob.nodeId))
        #expect(fixture.stores.messages.message(waiting.id)?.pendingKey == true)
        #expect(fixture.transport.written(.chat).isEmpty)
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.stores.messages.message(waiting.id)?.pendingKey == true, "the heal leaves a peer with no bits alone")

        fixture.deliver(try bob.profile(publishedAt: now), from: bob)
        #expect(fixture.stores.messages.message(waiting.id)?.pendingKey == false)
        #expect(fixture.transport.written(.chat).contains { $0.envelope.id == waiting.id })
    }

    // MARK: Our own card

    @Test func ourLinkParsesBackToUsWithOurProfilesName() throws {
        let fixture = EngineFixture(me, stores: .inMemory(ownProfile: OwnProfile(name: "  Ann \t Lee ")))
        let links = try #require(fixture.engine.ownContactLink())
        #expect(links.url == ContactCard.urlPrefix + links.compact && links.scheme == ContactCard.schemePrefix + links.compact)
        let card = try #require(ContactCard.parse(links.url).card)
        #expect(card.nodeId == me.nodeId && card.bundle == me.keys.bundle.encoded)
        #expect(card.name == "Ann Lee" && card.spools.isEmpty && card.issuedAt == fixture.clock.wallMilliseconds())
    }

    // MARK: Two engines

    /// A imports B's link while no carrier holds B's profile, and B holds A's. A's first DM goes v1, which B reads; B's goes
    /// on the ratchet, which A opens, its answer owed since A holds no prekey of B's. B's cleartext profile reaching A pays
    /// the debt, and both phones end on one session.
    @Test func aLinkImportBeforeTheProfileConvergesOnOneSessionOnceTheProfileArrives() throws {
        let alice = try EngineFixture.ratcheting(me, seed: 7)
        let bobs = try EngineFixture.ratcheting(bob, seed: 11)
        let aliceProfile = try #require(alice.engine.ownProfile())
        bobs.deliver(TestFrame(wire: aliceProfile.wire, envelope: aliceProfile.envelope), from: me)
        #expect(bobs.stores.peers.peer(me.nodeId)?.prekey != nil, "B holds A's profile")

        let bobsLink = try #require(bobs.engine.ownContactLink())
        let card = try #require(ContactCard.parse(bobsLink.url).card)
        #expect(alice.engine.addContact(card, from: .link, unblock: false) == .added(bob.nodeId))

        // A's DM: v1, since the card pins no bits.
        let first = try #require(alice.engine.sendDirectMessage("hi from A", to: bob.nodeId))
        #expect(!first.pendingKey)
        let ours = try #require(alice.transport.written(.chat).first { $0.envelope.id == first.id })
        #expect(try ChatContent(decoding: ours.envelope.payload).enc?.ratchet == nil, "v1")
        alice.transport.clear()
        bobs.deliver(TestFrame(wire: ours.wire, envelope: ours.envelope), from: me)
        #expect(bobs.stores.messages.message(first.id)?.body == "hi from A")

        // B's DM: the ratchet, its init riding.
        let reply = try #require(bobs.engine.sendDirectMessage("hi from B", to: me.nodeId))
        let fromB = bobs.transport.written(.chat).filter { $0.envelope.recipientId == me.nodeId.string && !$0.wire.sig.isEmpty }
        #expect(try fromB.contains { try ChatContent(decoding: $0.envelope.payload).enc?.ratchet?.initial != nil })
        bobs.transport.clear()
        for frame in fromB {
            alice.deliver(TestFrame(wire: frame.wire, envelope: frame.envelope), from: bob)
        }
        #expect(alice.stores.messages.message(reply.id)?.body == "hi from B", "A opens it with the card's key")
        #expect(alice.engine.answers.introsAnswered == 0, "owed: A holds no prekey of B's")
        #expect(bobs.ratchetRecords(of: me).session?.confirmed == false)
        let toBob = alice.transport.written(.chat).filter { $0.envelope.recipientId == bob.nodeId.string }
        #expect(
            try toBob.allSatisfy { try ChatContent(decoding: $0.envelope.payload).enc?.ratchet == nil }, "nothing of A's on the ratchet yet"
        )
        alice.transport.clear()

        // B's profile reaches A: the debt is paid.
        let bobsProfile = try #require(bobs.engine.ownProfile())
        alice.deliver(TestFrame(wire: bobsProfile.wire, envelope: bobsProfile.envelope), from: bob)
        #expect(alice.stores.peers.peer(bob.nodeId)?.prekey != nil)
        #expect(alice.engine.answers.introsAnswered == 1, "the owed answer, at the pin")
        let answers = alice.answerIds
        #expect(answers.count == 1 && alice.transport.written(.chat).contains { answers.contains(ExactKey($0.envelope.id)) })
        for frame in alice.transport.written(.chat) where frame.envelope.recipientId == bob.nodeId.string {
            bobs.deliver(TestFrame(wire: frame.wire, envelope: frame.envelope), from: me)
        }
        let theirs = try #require(bobs.ratchetRecords(of: me).session)
        let mine = try #require(alice.ratchetRecords(of: bob).session)
        #expect(theirs.confirmed && mine.confirmed, "both sides confirmed")
        #expect(BlobHash(of: theirs.root).string == BlobHash(of: mine.root).string, "one session")
    }
}

/// A peer store that drops every write, as a database that cannot write its file does, its error swallowed.
private final class DroppingPeerWrites: PeerStore {
    let held: any PeerStore

    init(_ held: any PeerStore) {
        self.held = held
    }

    func peer(_ nodeId: NodeId) -> PeerRecord? { held.peer(nodeId) }
    func upsert(_: PeerRecord) {
        // Dropped.
    }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
}
