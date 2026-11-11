import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The edges of our own presence keys (ADR 2026-11.prsp): each `due` step the engine applies from rows a store already
/// holds, a generation with no room left, an identity's item that cannot answer, the radio's readers once the engine is
/// gone, a link that refuses the write, and `confirmedOnly` at the session layer.
@Suite struct MeshEngineOwnPresenceKeyEdgeTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private static let configuration = MeshConfiguration(ratchet: true, sendsOwnPresenceKeys: true, logsPresenceKeyTrail: true)

    private func engine(_ keychain: KeptSecretStore, stores: MeshStores = .inMemory()) throws -> EngineFixture {
        try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, configuration: Self.configuration)
    }

    private func setLast(_ generation: Int64, in keychain: KeptSecretStore) throws {
        try PrekeyRing.load(for: me.keys, from: keychain).setPresenceLastGeneration(generation)
    }

    private func own(_ generation: Int64, _ activatedAt: Int64?, mark: PresenceMark? = nil) -> OwnPresenceKeyRecord {
        OwnPresenceKeyRecord(generation: generation, key: .generate(), mintedAt: now, activatedAt: activatedAt, audience: [], mark: mark)
    }

    /// `rows` in the store before the first pass, as an earlier run left them.
    private func seeded(_ rows: [OwnPresenceKeyRecord], last: Int64? = nil) throws -> EngineFixture {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let stores = MeshStores.inMemory()
        stores.presenceKeys.applyOwn(inserted: rows, updated: [], keep: Set(rows.map(\.generation)))
        if let last {
            try setLast(last, in: keychain)
        }
        return try engine(keychain, stores: stores)
    }

    private func generations(_ fixture: EngineFixture) -> [Int64] {
        fixture.stores.presenceKeys.ownKeys().map(\.generation)
    }

    @Test func aCurrentKeyAloneGetsANextKey() throws {
        let fixture = try seeded([own(10, now)])
        fixture.engine.feedPresenceKeys()
        #expect(generations(fixture) == [now, 10], "a next key, at the clock")
        #expect(fixture.transport.publishedKey?.generation == 10)
    }

    @Test func aWeekOldCurrentKeyWithNoNextKeyAdvancesToAFreshPair() throws {
        let fixture = try seeded([own(10, now - PresenceKeyPolicy.weekMilliseconds)])
        fixture.engine.feedPresenceKeys()
        #expect(generations(fixture) == [now + 1, now, 10])
        #expect(fixture.transport.publishedKey?.generation == now)
    }

    /// A current key activated while the clock ran two days ahead advances once, and the advance starts the day's floor.
    @Test func aCorrectedClockAdvancesOnceAndStartsTheDaysFloor() throws {
        let fixture = try seeded([own(10, now + 2 * PresenceKeyPolicy.dayMilliseconds), own(11, nil)])
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.publishedKey?.generation == 11)
        #expect(fixture.engine.presenceKeyFeed.lastClockAdvanceAt == fixture.clock.monotonicMilliseconds())
        // Within the day's floor the next pass advances no more.
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.publishedKey?.generation == 11)
    }

    @Test func noGenerationLeftMintsNothingAndPublishesNoKey() throws {
        let fixture = try seeded([], last: .max)
        fixture.engine.feedPresenceKeys()
        #expect(generations(fixture).isEmpty && fixture.transport.publishedKey == nil)
        #expect(fixture.log.all.contains { $0.contains("mesh presence key generation would overflow") })

        // Room for the current key alone: the pair is not minted, and nothing changes.
        let tight = try seeded([], last: .max - 1)
        tight.engine.feedPresenceKeys()
        #expect(generations(tight).isEmpty && tight.transport.publishedKey == nil)

        // A week's advance with no generation left keeps the keys it had, and airs none.
        let week = try seeded([own(10, now - PresenceKeyPolicy.weekMilliseconds), own(11, nil)], last: .max)
        week.engine.feedPresenceKeys()
        #expect(generations(week) == [11, 10] && week.transport.publishedKey == nil)
    }

    /// A node that keeps no identity's item mints nothing and says nothing of it; an item that holds another identity is a
    /// read that fails, which mints nothing and is counted.
    @Test func anItemThatCannotNumberAKeyMintsNothing() throws {
        let bare = EngineFixture(me, configuration: Self.configuration)
        bare.engine.feedPresenceKeys()
        #expect(bare.stores.presenceKeys.ownKeys().isEmpty && bare.engine.presenceKeyCounts.mintsFailed == 0)

        let foreign = KeptSecretStore(alice.keys.storedForm)
        let ring = try PrekeyRing.load(for: me.keys, from: foreign)
        let fixture = EngineFixture(me, configuration: Self.configuration, prekeys: ring)
        fixture.engine.feedPresenceKeys()
        #expect(fixture.stores.presenceKeys.ownKeys().isEmpty && fixture.engine.presenceKeyCounts.mintsFailed == 1)
    }

    /// A reinstall whose item will not take the clamp leaves the generation as it was, and says so.
    @Test func aClampTheItemRefusesLeavesTheGenerationAsItWas() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        _ = try engine(keychain)
        let ahead = now + 2 * PresenceKeyPolicy.clampAheadMilliseconds
        try setLast(ahead, in: keychain)
        keychain.refusesWrites = true
        let reinstalled = try engine(keychain)
        #expect(reinstalled.log.all.contains { $0.contains("mesh left the presence key generation as it was") })
        keychain.refusesWrites = false
        #expect(try PrekeyRing.load(for: me.keys, from: keychain).presenceLastGeneration() == ahead)
    }

    /// A contact accepted within a day of the current key's activation joins it and the next key; the pair stays.
    @Test func aNewContactGrowsIntoBothKeys() throws {
        let fixture = try engine(KeptSecretStore(me.keys.storedForm))
        fixture.engine.accept(alice.nodeId.string)
        fixture.engine.feedPresenceKeys()
        let minted = generations(fixture)
        fixture.engine.accept(carol.nodeId.string)
        fixture.engine.feedPresenceKeys()
        #expect(generations(fixture) == minted, "no rotation")
        #expect(fixture.stores.presenceKeys.ownKeys().allSatisfy { $0.audience == [alice.nodeId, carol.nodeId] })
    }

    /// The mark's counters: a commit that would not run at FULL, and a write asked inside a unit.
    @Test func everyMarkOutcomeIsCounted() throws {
        let memory = MeshStores.inMemory()
        let notFull = try EngineFixture.ratcheting(
            me, stores: memory.replacing(presenceKeys: MemoryPresenceKeyStore(durableMarks: false)), configuration: Self.configuration)
        #expect(notFull.engine.writePresenceMark(PresenceMark(slot: 1, restart: 0), of: 1) == .notFull)
        #expect(notFull.engine.presenceKeyCounts.markNotFull == 1)

        let fixture = try engine(KeptSecretStore(me.keys.storedForm))
        fixture.engine.feedPresenceKeys()
        let unit = fixture.stores.transactor.atomically { () -> PresenceMarkWrite? in
            fixture.engine.writePresenceMark(PresenceMark(slot: 1, restart: 0), of: now)
        }
        #expect(unit == .committed(.insideUnit))
        #expect(fixture.engine.presenceKeyCounts.markFailed == 1)
    }

    /// The radio's readers hold the engine weakly: once it is gone they answer nothing, refuse, and ask for nothing.
    @Test func theRadiosReadersAnswerNothingOnceTheEngineIsGone() throws {
        let transport = RecordingTransport()
        do {
            _ = MeshEngine(
                identity: me.keys,
                deviceTag: nil,
                stores: .inMemory(),
                transport: transport,
                clock: ManualClock(wall: now, monotonic: 1),
                random: SeededGenerator(seed: 3),
                configuration: Self.configuration
            )
        }
        let source = try #require(transport.presenceKeySource)
        #expect(source.ownKey() == nil && !source.hearsTagNext(alice.nodeId))
        #expect(throws: PresenceMarkReadFailure()) {
            try source.readMark(1)
        }
        #expect(source.writeMark(PresenceMark(slot: 1, restart: 0), 1) == .failed)
        source.askMarkPass(1)
    }

    /// A proven link that refuses the write leaves nothing in the ledger, so the next pass seals again.
    @Test func aLinkThatRefusesTheWriteIsSealedAgainNextPass() throws {
        let fixture = try engine(KeptSecretStore(me.keys.storedForm))
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.engine.accept(alice.nodeId.string)
        fixture.deliver(
            try android.dm(MessageContent(body: "hi"), to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("hi"), sentAt: now),
            from: android)
        fixture.link(alice)
        fixture.transport.refusesProvenSends = true
        fixture.engine.feedPresenceKeys()
        #expect(fixture.engine.presenceKeyCounts.sendsFailed == 1 && fixture.engine.presenceKeyFeed.sent.isEmpty)
        fixture.transport.refusesProvenSends = false
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.count == 1 && fixture.engine.presenceKeyCounts.sent == 1)
    }

    /// A contact with a session whose ratchet store refuses the seal's write sends and records nothing; a direct contact
    /// with no pinned profile reads no keys.
    @Test func aSealThatFailsOrAContactWithNoProfileSendsNothing() throws {
        let (stores, refusing) = try StoreKind.memory.storesRefusingOpens(
            blobs: scratchDirectory("pk-seal-refused"), failures: ReportedFailures().record)
        let fixture = try engine(KeptSecretStore(me.keys.storedForm), stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.engine.accept(alice.nodeId.string)
        fixture.deliver(
            try android.dm(MessageContent(body: "hi"), to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("hi"), sentAt: now),
            from: android)
        fixture.link(alice)
        fixture.engine.accept(carol.nodeId.string)
        fixture.link(carol)
        refusing.refusesWrites = true
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty && fixture.engine.presenceKeyFeed.sent.isEmpty)
        refusing.refusesWrites = false
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.map(\.to) == [alice.nodeId], "carol has no profile to read our keys by")
    }

    /// `confirmedOnly` refuses inside the seal's unit with no session, and with our own unanswered init, changing nothing.
    @Test func aConfirmedOnlySealRefusesWithoutAConfirmedSession() throws {
        let fixture = try engine(KeptSecretStore(me.keys.storedForm))
        let android = try AndroidPeer(alice)
        let prekey = try fixture.ourPrekey()
        let aad = MessageCrypto.header(id: "x", senderId: alice.nodeId.string, sentAt: now, thread: me.nodeId.string)
        let none = android.sessions.sealDm(to: me.keys.bundle, prekey: prekey, plaintext: [1], aad: aad, now: now, confirmedOnly: true)
        guard case .settled(.unavailable) = none else {
            Issue.record("sealed with no session: \(none)")
            return
        }
        #expect(android.session(with: me) == nil, "no session started")
        _ = try android.dm("hello", to: me, prekey: prekey, id: frameIdOf("init"), sentAt: now)
        let held = try #require(android.session(with: me))
        let unanswered = android.sessions.sealDm(
            to: me.keys.bundle, prekey: prekey, plaintext: [1], aad: aad, now: now, confirmedOnly: true)
        guard case .settled(.unavailable) = unanswered else {
            Issue.record("sealed over our unanswered init: \(unanswered)")
            return
        }
        #expect(android.session(with: me)?.sendCount == held.sendCount, "no chain key spent")
    }

    /// Nothing reflection shows of our published key is the key.
    @Test func reflectionShowsTheGenerationAlone() {
        let key = OwnPresenceKey(generation: 42, key: .generate())
        var dumped = ""
        dump(key, to: &dumped)
        #expect(dumped.contains("42") && !dumped.contains("bytes"))
        #expect(Mirror(reflecting: key).children.map(\.label) == ["generation"])
    }
}
