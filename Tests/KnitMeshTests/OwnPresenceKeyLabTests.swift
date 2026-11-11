import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our own presence keys between two engines of this port (ADR 2026-11.prsp; `PresenceKeyLabTest` at knit-next
/// `cad69c77b` in miniature): the iPhone, node 0, mints and seals; its contacts store what they open and resolve its tags by
/// it. Each node's pass is run by hand, as the `Mesh` actor runs it after every entry.
@Suite struct OwnPresenceKeyLabTests {
    private typealias Node = EngineFixture

    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private static let configuration = MeshConfiguration(ratchet: true, sendsOwnPresenceKeys: true, logsPresenceKeyTrail: true)
    private static let twoMinutes: Int64 = 120_000

    /// A node of `peer`'s, with a device tag of its own, so a block of one blocks no other by tag.
    private func node(_ peer: TestPeer, keychain: KeptSecretStore? = nil, stores: MeshStores = .inMemory(), seed: UInt64) throws -> Node {
        try EngineFixture.ratcheting(
            peer,
            stores: stores,
            keychain: keychain ?? KeptSecretStore(peer.keys.storedForm),
            configuration: Self.configuration,
            seed: seed,
            deviceTag: String(repeating: "0", count: 14) + String(seed, radix: 16).suffix(2)
        )
    }

    /// Links node 0 and node `index`, their profiles crossing, then holds what the peer sends us.
    private func linkHolding(_ lab: EngineLab, _ index: Int) {
        lab.link(0, index)
        lab.hold(from: index, to: 0)
    }

    /// Every node's pass, and whatever it sends, twice over.
    private func pass(_ lab: EngineLab, nodes: Int) {
        for _ in 0..<2 {
            for index in 0..<nodes {
                lab[index].engine.feedPresenceKeys()
            }
            lab.carry()
        }
    }

    /// Our ctl 11 frames node 0 sent `to`.
    private func keyFrames(_ lab: EngineLab, to peer: TestPeer) -> [Written] {
        lab[0].transport.provenSends.filter { $0.to == peer.nodeId }
    }

    /// What node `index` holds of our keys, newest first.
    private func held(_ lab: EngineLab, _ index: Int) -> [HeldPresenceKey] {
        lab[index].stores.presenceKeys.keys(of: me.nodeId).map(\.held)
    }

    /// A tag of `owner`'s for the slot `wall` falls in, under `key`.
    private func tag(_ key: PresenceKey, owner: NodeId, wall: Int64) throws -> NodeId {
        let slot = BlindTag.slotOf(wallMilliseconds: wall)
        let bytes = try #require(BlindTag.tag(key: key, owner: owner.bytes, slot: slot, restart: 0))
        return try #require(NodeId(bytes: bytes))
    }

    /// The iPhone greets `peer`, node `index`, holding the peer's replies until `answered`, and the peer accepts it.
    private func greet(_ lab: EngineLab, _ index: Int, answered: Bool = true) throws {
        lab[index].engine.accept(me.nodeId.string)
        _ = try #require(lab[0].engine.sendDirectMessage("hello", to: lab[index].me.nodeId))
        lab.carry()
        if answered {
            lab.release(from: index, to: 0)
        }
    }

    /// The trial's first half: no ctl 11 before our init is answered, the first one straight after, and the peer's table
    /// resolves our tags by the key it opened.
    @Test func noKeyGoesBeforeTheSessionConfirmsAndThePeerResolvesOurTagsByTheOneThatFollows() throws {
        let lab = EngineLab([try node(me, seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1, answered: false)
        pass(lab, nodes: 1)
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == false, "precondition: our init is unanswered")
        #expect(keyFrames(lab, to: bob).isEmpty, "nothing rides our unanswered init")
        #expect(held(lab, 1).isEmpty)

        lab.release(from: 1, to: 0)
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == true)
        // The answer's commit owes our keys a pass at once: no heal, no link-up delay.
        #expect(lab[0].engine.presenceKeyFeed.ownPassOwed)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 1)
        let ours = try #require(lab[0].transport.publishedKey)
        #expect(held(lab, 1).map(\.generation) == [ours.generation + 1, ours.generation])
        #expect(held(lab, 1).last?.key == ours.key)
        let bobsRoot = try #require(lab[1].ratchetRecords(of: me).session?.root)
        #expect(held(lab, 1).allSatisfy { $0.rootTag == RatchetCrypto.rootTag(bobsRoot) }, "filed under the root it opened under")

        // Bob lists the key, and his table resolves our tag for this slot to us, and nobody else's.
        let listing = try #require(lab[1].transport.presenceKeyListings.last?[me.nodeId])
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: PresenceKeyPolicy.weekMilliseconds)
        let wall = lab[1].clock.wallMilliseconds()
        table.setKeys(
            [me.nodeId: try #require(ExpectedTagTable.ContactKey(keys: listing))], now: lab[1].clock.monotonicMilliseconds(), wall: wall)
        #expect(
            table.lookup(try tag(ours.key, owner: me.nodeId, wall: wall), now: lab[1].clock.monotonicMilliseconds())?.nodeId == me.nodeId)
        #expect(table.lookup(try tag(ours.key, owner: carol.nodeId, wall: wall), now: lab[1].clock.monotonicMilliseconds()) == nil)
        #expect(lab.sessionsAgree(0, 1))
    }

    /// After the peer resets the session, the adoption's commit owes a pass, which seals our keys again under the new root,
    /// with no heal; the peer files them as a new era.
    @Test func afterThePeersResetTheNextPassResendsUnderTheNewRoot() throws {
        let lab = EngineLab([try node(me, seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 1)
        let before = try #require(lab[0].ratchetRecords(of: bob).session?.root)

        lab.advance(Self.twoMinutes)
        let reset = lab[1].engine.sendSessionReset(to: me.nodeId, now: lab[1].clock.wallMilliseconds(), cause: .onDemand)
        lab.carry()
        guard case .sent(_, reRooted: true) = reset else {
            Issue.record("precondition: bob re-roots, not \(reset)")
            return
        }
        let after = try #require(lab[0].ratchetRecords(of: bob).session?.root)
        #expect(after != before, "precondition: we adopted bob's reset")

        #expect(lab[0].engine.presenceKeyFeed.ownPassOwed, "the adoption owes a pass")
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 2, "sealed again under the new root")
        #expect(held(lab, 1).allSatisfy { $0.rootTag == RatchetCrypto.rootTag(after) }, "a new era for bob")
        #expect(lab.sessionsAgree(0, 1))
    }

    /// A block mints a fresh pair: the other contact gets the new generation, the blocked one nothing, and the blocked
    /// one's table no longer resolves the tags we air.
    @Test func aBlockSendsTheFreshPairToTheRestAndNothingToTheBlocked() throws {
        let lab = EngineLab([try node(me, seed: 11), try node(bob, seed: 12), try node(carol, seed: 13)])
        linkHolding(lab, 1)
        linkHolding(lab, 2)
        try greet(lab, 1)
        try greet(lab, 2)
        pass(lab, nodes: 3)
        let first = try #require(lab[0].transport.publishedKey)
        #expect(held(lab, 1).last?.key == first.key && held(lab, 2).last?.key == first.key)

        lab[0].engine.block(bob.nodeId)
        pass(lab, nodes: 3)
        let fresh = try #require(lab[0].transport.publishedKey)
        #expect(fresh.generation > first.generation + 1 && fresh.key != first.key)
        #expect(keyFrames(lab, to: bob).count == 1, "bob gets nothing more")
        #expect(keyFrames(lab, to: carol).count == 2)
        #expect(held(lab, 2).map(\.generation).prefix(2) == [fresh.generation + 1, fresh.generation])
        #expect(!held(lab, 1).contains { $0.key == fresh.key })
        let source = try #require(lab[0].transport.presenceKeySource)
        #expect(!source.hearsTagNext(bob.nodeId) && source.hearsTagNext(carol.nodeId))
    }

    /// A relaunch over the same stores and item sends each linked contact our keys once more, at the link-up's pass, under
    /// the same generations the peer already holds.
    @Test func aRelaunchResendsOnceUnderTheSameGenerations() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let lab = EngineLab([try node(me, keychain: keychain, seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1)
        pass(lab, nodes: 2)
        let generations = held(lab, 1).map(\.generation)
        let wall = lab[0].clock.wallMilliseconds()
        let relaunched = try EngineFixture.ratcheting(
            me, stores: lab[0].stores, keychain: keychain, wall: wall, configuration: Self.configuration, seed: 21)
        lab.replace(0, with: relaunched)
        lab.link(0, 1)
        lab.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 1, "once")
        #expect(held(lab, 1).map(\.generation) == generations)
        let last = try PrekeyRing.load(for: me.keys, from: keychain).presenceLastGeneration()
        #expect(generations.first == last, "nothing minted above the last")
    }

    /// A store that fails our pass's unit sends and records nothing; the peer holds nothing until a pass commits.
    @Test func aFailedUnitSendsNothingToThePeer() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let lab = EngineLab([try node(me, stores: memory.replacing(presenceKeys: refusing), seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1)
        refusing.refusesWrites = true
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).isEmpty && held(lab, 1).isEmpty && lab[0].engine.presenceKeyFeed.sent.isEmpty)
        refusing.refusesWrites = false
        lab.advance(MeshEngine.ownSettleRetryMilliseconds)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 1 && held(lab, 1).count == 2)
    }

    /// A ctl 11 queued on a link that ends soon after may have died in its outbox: the next link's pass sends it again. One
    /// whose link outlived the write-stall bound is not sent again.
    @Test func aLinkThatDropsSoonAfterTheSendGetsItAgainAtTheRelink() throws {
        let lab = EngineLab([try node(me, seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 1)
        lab.advance(1000)
        lab.unlink(0, 1)
        lab.link(0, 1)
        lab.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 2, "sent again on the new link")

        lab.advance(MeshEngine.presenceLostSendMilliseconds)
        lab.unlink(0, 1)
        lab.link(0, 1)
        lab.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).count == 2, "a link that outlived the bound delivered it")
        #expect(held(lab, 1).count == 2)
    }

    /// An unproven link to a contact gets nothing, and spends no chain key.
    @Test func anUnprovenLinkGetsNothing() throws {
        let lab = EngineLab([try node(me, seed: 11), try node(bob, seed: 12)])
        linkHolding(lab, 1)
        try greet(lab, 1)
        lab[0].transport.unproven = [bob.nodeId]
        let chain = lab[0].ratchetRecords(of: bob).session?.sendCount
        pass(lab, nodes: 2)
        #expect(keyFrames(lab, to: bob).isEmpty && held(lab, 1).isEmpty)
        #expect(lab[0].ratchetRecords(of: bob).session?.sendCount == chain)
    }
}
