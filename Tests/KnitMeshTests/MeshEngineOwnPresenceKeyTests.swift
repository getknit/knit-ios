import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our own presence keys in the engine (ADR 2026-11.prsp): minted, rotated and sealed to linked direct contacts, Android
/// phones here, which open what we send (`PresenceKeyEngineTest`'s cases at knit-next `cad69c77b`, as this port's one actor
/// runs them). The two-engine trials are `OwnPresenceKeyLabTests`.
@Suite struct MeshEngineOwnPresenceKeyTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let stranger = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }
    private static let configuration = MeshConfiguration(ratchet: true, sendsOwnPresenceKeys: true, logsPresenceKeyTrail: true)

    /// The iPhone with its keys on, and `contacts` as Android phones, each pinned, accepted, holding a session it opened to
    /// us (so ours is confirmed), and linked with a HELLO carrying `CAP_BLIND_ADVERT` and `CAP_LINK_PROOF`.
    private func rig(
        _ contacts: [TestPeer], keychain: KeptSecretStore? = nil, stores: MeshStores = .inMemory(),
        configuration: MeshConfiguration = configuration, link: Bool = true
    ) throws -> (EngineFixture, [AndroidPeer]) {
        let fixture = try EngineFixture.ratcheting(
            me, stores: stores, keychain: keychain ?? KeptSecretStore(me.keys.storedForm), configuration: configuration)
        var phones: [AndroidPeer] = []
        for (index, contact) in contacts.enumerated() {
            let android = try AndroidPeer(contact)
            try fixture.pin(android)
            fixture.engine.accept(contact.nodeId.string)
            let hello = try android.dm(
                MessageContent(body: "hi"), to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("hello-\(index)"), sentAt: now)
            fixture.deliver(hello, from: android)
            if link {
                fixture.link(contact)
            }
            phones.append(android)
        }
        return (fixture, phones)
    }

    /// Our ctl 11 frames to `android`, opened as the phone reads them.
    private func keysSent(_ fixture: EngineFixture, to android: AndroidPeer) -> [PresenceKeyPayload] {
        fixture.transport.provenSends.filter { $0.to == android.nodeId }.compactMap { android.peek($0, from: me)?.pk }
    }

    private func lastGeneration(_ keychain: KeptSecretStore) throws -> Int64 {
        try PrekeyRing.load(for: me.keys, from: keychain).presenceLastGeneration()
    }

    @Test func aFirstPassMintsACurrentAndANextKeyAndSealsBothToALinkedContact() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (fixture, phones) = try rig([alice], keychain: keychain)
        fixture.engine.feedPresenceKeys()
        let published = try #require(fixture.transport.publishedKey)
        #expect(published.generation == now)
        #expect(fixture.stores.presenceKeys.ownKeys().map(\.generation) == [now + 1, now])
        #expect(try lastGeneration(keychain) == now + 1, "the item holds the last generation minted")
        let sent = keysSent(fixture, to: phones[0])
        #expect(sent.count == 1)
        let payload = try #require(sent.first)
        #expect(payload.generation == now && payload.key == published.key.bytes)
        #expect(payload.nextGeneration == now + 1 && payload.nextKey?.count == PresenceKey.byteCount)
        let frame = try #require(fixture.transport.provenSends.first)
        #expect(!frame.wire.relay, "point to point")
        #expect(!fixture.stores.custody.contains(frame.envelope.id), "never custodied")
        #expect(
            fixture.transport.written.count { ExactKey($0.envelope.id) == ExactKey(frame.envelope.id) && $0.to == nil } == 0,
            "never flooded")
        let content = try #require(phones[0].peek(frame, from: me))
        #expect(content.ctl == MessageContent.Control.presenceKey && content.encoded.count == PresenceKeyFrame.plaintextBytes)
        #expect(try ChatContent(decoding: frame.envelope.payload).enc?.version == EncEnvelope.Version.ratchet, "named v2")
        #expect(fixture.engine.presenceKeyCounts.sent == 1 && fixture.engine.presenceKeyCounts.ownGeneration == now)
        #expect(fixture.log.all.contains { $0.contains("mesh presence keys sealed to \(alice.nodeId): frame ") })
        #expect(!fixture.log.all.contains { $0.contains(Hex.encode(published.key.bytes)) })

        // Nothing changed: nothing more is sealed, whatever asks for a pass.
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
    }

    @Test func aWeekLaterTheNextKeyBecomesCurrentAndTheNewPairGoes() throws {
        let (fixture, phones) = try rig([alice])
        fixture.engine.feedPresenceKeys()
        fixture.clock.advance(PresenceKeyPolicy.weekMilliseconds)
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.publishedKey?.generation == now + 1)
        let week = now + PresenceKeyPolicy.weekMilliseconds
        #expect(fixture.stores.presenceKeys.ownKeys().map(\.generation) == [week, now + 1, now], "previous, current, next")
        #expect(keysSent(fixture, to: phones[0]).map(\.generation) == [now, now + 1])
        #expect(keysSent(fixture, to: phones[0]).last?.nextGeneration == week)
    }

    /// A block withdraws our key and refuses `TAG_NEXT` at once, with no store read; the next pass mints a fresh pair that
    /// the rest get and the blocked person never does (`PresenceKeyEngineTest`'s fresh pair).
    @Test func aBlockMintsAFreshPairThatTheBlockedNeverGets() throws {
        let (fixture, phones) = try rig([alice, carol])
        fixture.engine.feedPresenceKeys()
        let source = try #require(fixture.transport.presenceKeySource)
        #expect(source.hearsTagNext(alice.nodeId) && source.hearsTagNext(carol.nodeId))
        fixture.engine.block(alice.nodeId)
        #expect(fixture.transport.ownKeys.last == .some(nil), "withdrawn at once")
        #expect(source.ownKey() == nil && !source.hearsTagNext(alice.nodeId))
        fixture.engine.feedPresenceKeys()
        let fresh = try #require(source.ownKey())
        #expect(fresh.generation == now + 2)
        #expect(keysSent(fixture, to: phones[0]).map(\.generation) == [now], "alice has only what she had")
        #expect(keysSent(fixture, to: phones[1]).map(\.generation) == [now, now + 2])
        #expect(keysSent(fixture, to: phones[1]).last?.key == fresh.key.bytes)
        #expect(!source.hearsTagNext(alice.nodeId) && source.hearsTagNext(carol.nodeId), "departed, and blocked")
        #expect(fixture.stores.presenceKeys.ownKeys().allSatisfy { $0.activatedAt != nil || !$0.audience.contains(alice.nodeId) })
    }

    @Test func nothingGoesToAStrangerAnUnprovenLinkOrAProfileWithoutTheBits() throws {
        let (fixture, phones) = try rig([alice, carol])
        let strangerPhone = try AndroidPeer(stranger)
        try fixture.pin(strangerPhone)
        fixture.link(stranger)
        fixture.transport.unproven = [carol.nodeId]
        let carolChain = fixture.ratchetRecords(of: carol).session?.sendCount
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
        #expect(keysSent(fixture, to: phones[1]).isEmpty, "an unproven link gets nothing")
        #expect(fixture.ratchetRecords(of: carol).session?.sendCount == carolChain, "and spends no chain key on it")
        #expect(fixture.transport.provenSends.allSatisfy { $0.to == alice.nodeId }, "a stranger gets nothing")

        // A HELLO and a pinned profile with neither bit: no key, however proven the link.
        let (bare, barePhones) = try rig([alice], link: false)
        bare.link(alice, capabilities: Capabilities.local.subtracting([.blindAdvert, .linkProof]))
        bare.engine.feedPresenceKeys()
        #expect(keysSent(bare, to: barePhones[0]).isEmpty)
    }

    /// With the ratchet's switch off our keys are minted and rotated, and none is ever sealed.
    @Test func theRatchetOffMintsAndSendsNothing() throws {
        let (fixture, _) = try rig([alice])
        let off = try EngineFixture.ratcheting(
            me, stores: fixture.stores, configuration: MeshConfiguration(sendsOwnPresenceKeys: true), seed: 17)
        off.link(alice)
        off.engine.feedPresenceKeys()
        #expect(off.transport.publishedKey?.generation == now)
        #expect(off.transport.provenSends.isEmpty)
    }

    @Test func aBuildThatSendsNoKeysMintsNoneAndStillPublishesTheDeparted() throws {
        let (fixture, _) = try rig([alice], configuration: MeshConfiguration(ratchet: true))
        fixture.engine.feedPresenceKeys()
        #expect(fixture.stores.presenceKeys.ownKeys().isEmpty && fixture.transport.provenSends.isEmpty)
        let source = try #require(fixture.transport.presenceKeySource)
        #expect(source.ownKey() == nil && source.hearsTagNext(alice.nodeId))
    }

    /// A store that fails the pass's unit mints, publishes, seals and records nothing, and the next pass that commits does
    /// it all once.
    @Test func aFailedUnitPublishesSealsAndRecordsNothing() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (fixture, phones) = try rig([alice], keychain: keychain, stores: memory.replacing(presenceKeys: refusing))
        refusing.refusesWrites = true
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.ownKeys.isEmpty && memory.presenceKeys.ownKeys().isEmpty)
        #expect(fixture.transport.provenSends.isEmpty && fixture.engine.presenceKeyFeed.sent.isEmpty)
        // The settle sits out a minute after a failed unit, so a store that keeps failing writes the item no more.
        let last = try lastGeneration(keychain)
        fixture.engine.notePresenceKeyInputsChanged()
        fixture.engine.feedPresenceKeys()
        #expect(try lastGeneration(keychain) == last)
        refusing.refusesWrites = false
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty && fixture.engine.presenceKeyFeed.ownPassOwed, "still owed")
        fixture.advance(MeshEngine.ownSettleRetryMilliseconds)
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
    }

    /// A mint the identity's item cannot record mints nothing and publishes nothing new; the next pass after the item
    /// answers mints.
    @Test func aMintTheItemCannotRecordMintsNothing() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (fixture, phones) = try rig([alice], keychain: keychain)
        keychain.refusesWrites = true
        fixture.engine.feedPresenceKeys()
        #expect(fixture.stores.presenceKeys.ownKeys().isEmpty && fixture.transport.ownKeys.isEmpty)
        #expect(fixture.transport.provenSends.isEmpty && fixture.engine.presenceKeyCounts.mintsFailed == 1)
        keychain.refusesWrites = false
        fixture.engine.noteOwnPresenceKeyPassOwed()
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
    }

    /// A link-up's pass comes 2 to 20 s on, from the link-up alone; a relink with nothing changed sends nothing.
    @Test func theLinkUpPassRunsTwoToTwentySecondsOnAndARelinkSendsNothingNew() throws {
        let (fixture, phones) = try rig([alice], link: false)
        fixture.engine.feedPresenceKeys()
        fixture.link(alice)
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty, "not in the link's first second")
        fixture.advance(MeshEngine.presenceLinkUpDelay.lowerBound - 1)
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty)
        fixture.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
        // A link that outlived the write-stall bound delivered it, so the ledger outlives that link.
        fixture.advance(MeshEngine.presenceLostSendMilliseconds)
        fixture.unlink(alice)
        fixture.link(alice)
        fixture.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1, "the ledger outlives the link")
    }

    /// A stored profile that gains `CAP_BLIND_ADVERT` asks for a pass, and the linked peer gets its keys there.
    @Test func aProfileGainingTheBitAsksForAPass() throws {
        let (fixture, phones) = try rig([alice], link: false)
        fixture.link(alice, capabilities: Capabilities.local.subtracting([.blindAdvert, .linkProof]))
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty)
        let bits = Capabilities(rawValue: AndroidPeer.capabilities).union([.blindAdvert, .linkProof]).rawValue
        let gained = try alice.profile(publishedAt: now + 1, capabilities: bits, prekey: phones[0].prekey.info)
        fixture.deliver(gained, from: alice)
        fixture.engine.feedPresenceKeys()
        #expect(keysSent(fixture, to: phones[0]).count == 1)
    }

    /// A relaunch over the same stores and item mints nothing and sends once more what each contact holds; a reinstall,
    /// fresh stores over the same item, mints above the last generation.
    @Test func aRelaunchResendsOnceAndAReinstallMintsAboveTheLast() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (fixture, phones) = try rig([alice], keychain: keychain)
        fixture.engine.feedPresenceKeys()
        let relaunched = try EngineFixture.ratcheting(
            me, stores: fixture.stores, keychain: keychain, configuration: Self.configuration, seed: 21)
        relaunched.link(alice)
        relaunched.engine.feedPresenceKeys()
        relaunched.engine.feedPresenceKeys()
        #expect(keysSent(relaunched, to: phones[0]).map(\.generation) == [now], "once, the same keys")
        #expect(relaunched.stores.presenceKeys.ownKeys().map(\.generation) == [now + 1, now])

        let reinstalled = try EngineFixture.ratcheting(me, keychain: keychain, configuration: Self.configuration, seed: 22)
        reinstalled.engine.feedPresenceKeys()
        #expect(reinstalled.transport.publishedKey?.generation == now + 2, "above the last the item kept")
    }

    /// The item's generation is clamped to the clock when a reinstall finds it more than a year ahead, and only then.
    @Test func aGenerationAYearAheadIsClampedAtAReinstallAndNowhereElse() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let ahead = now + 2 * PresenceKeyPolicy.clampAheadMilliseconds
        try PrekeyRing.load(for: me.keys, from: keychain).setPresenceLastGeneration(ahead)
        let first = try EngineFixture.ratcheting(me, keychain: keychain, configuration: Self.configuration)
        first.engine.feedPresenceKeys()
        #expect(first.transport.publishedKey?.generation == ahead + 1, "a first start is no reinstall")
        let restarted = try EngineFixture.ratcheting(me, stores: first.stores, keychain: keychain, configuration: Self.configuration)
        #expect(try lastGeneration(keychain) == ahead + 2, "a restart clamps nothing")
        _ = restarted
        let reinstalled = try EngineFixture.ratcheting(me, keychain: keychain, configuration: Self.configuration, seed: 23)
        #expect(try lastGeneration(keychain) == now)
        reinstalled.engine.feedPresenceKeys()
        #expect(reinstalled.transport.publishedKey?.generation == now + 1)
    }

    /// The radio's mark seams: a mark lands only under the current key and is counted, and a mark pass is asked once per
    /// generation.
    @Test func theMarkSeamsWriteUnderTheCurrentKeyAndAskOncePerGeneration() throws {
        let (fixture, _) = try rig([alice])
        fixture.engine.feedPresenceKeys()
        let source = try #require(fixture.transport.presenceKeySource)
        #expect(source.writeMark(PresenceMark(slot: 9, restart: 1), now) == .durable)
        #expect(try source.readMark(now) == PresenceMark(slot: 9, restart: 1))
        #expect(source.writeMark(PresenceMark(slot: 9, restart: 1), now + 1) == .refused, "the next key has not aired")
        let counts = fixture.engine.presenceKeyCounts
        #expect(counts.markWrites == 2 && counts.marksDurable == 1 && counts.markRefused == 1)
        source.askMarkPass(now)
        #expect(fixture.engine.presenceKeyFeed.ownPassOwed)
        fixture.engine.feedPresenceKeys()
        source.askMarkPass(now)
        #expect(!fixture.engine.presenceKeyFeed.ownPassOwed, "once per generation")
    }

    /// A session start hands the radio no key until its first pass commits.
    @Test func aSessionStartWithdrawsTheKeyUntilItsFirstPass() throws {
        let (fixture, _) = try rig([alice])
        fixture.engine.feedPresenceKeys()
        fixture.engine.startPresenceKeySession()
        #expect(fixture.transport.ownKeys.last == .some(nil))
        let source = try #require(fixture.transport.presenceKeySource)
        #expect(source.ownKey() == nil && !source.hearsTagNext(alice.nodeId))
        fixture.engine.feedPresenceKeys()
        #expect(source.ownKey()?.generation == now && source.hearsTagNext(alice.nodeId))
    }
}
