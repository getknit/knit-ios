import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The iPhone and Android on one ratchet session through the engine's inbound path and its resets (ADR 2026-10.5sk9,
/// phase P5a): a reset each way, a race, the iPhone reinstalled, and what the engine does on its own at start and on its
/// timers. Android is ``AndroidPeer``; what it does on its side beyond sealing and opening, such as re-sealing its unacked
/// DMs after our reset, is knit-next's, and a fresh DM stands in for it here.
@Suite struct MeshEngineRatchetPairTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }

    /// The root's SHA-256 as hex, which two phones compare to tell whether they share an era.
    private func rootHash(_ root: [UInt8]?) -> String? {
        root.map { BlobHash(of: $0).string }
    }

    /// The iPhone's reset to Android, sent, and Android's open of it.
    private func resetReachesAndroid(_ fixture: EngineFixture, _ android: AndroidPeer) throws {
        guard case .sent = fixture.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our reset goes")
            return
        }
        let reset = try #require(fixture.resetsSent(to: alice).last)
        let enc = try #require(try ChatContent(decoding: reset.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.ratchet, "every reset seals v2")
        #expect(reset.wire.relay && !reset.wire.sig.isEmpty, "signed once and flooded")
        let opened = try android.open(reset, from: me, now: fixture.clock.wallMilliseconds())
        #expect(plaintext(opened) == RatchetSessions.resetPlaintext, #"the plaintext is {"body":"","ctl":1}"#)
    }

    @Test func ourResetReachesAndroidAndItsNextDmConfirmsTheSession() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        try resetReachesAndroid(fixture, android)
        let sent = try #require(fixture.resetsSent(to: alice).last)
        #expect(fixture.stores.custody.contains(sent.envelope.id), "carried as ours")
        #expect(fixture.stores.messages.message(sent.envelope.id) == nil, "no row")
        let theirs = try #require(android.session(with: me))
        #expect(theirs.confirmed && !theirs.weAreInitiator)

        fixture.clock.advance(Self.minute)
        let reply = try android.dm("got it", to: me, prekey: try fixture.ourPrekey(), id: "after", sentAt: now + Self.minute)
        fixture.deliver(reply, from: android)
        #expect(fixture.stores.messages.message("after")?.body == "got it")
        let ours = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(ours.confirmed && ours.weAreInitiator, "their answer confirms our init")
        #expect(rootHash(ours.root) == rootHash(theirs.root))
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).confirmedAt == now + Self.minute, "settled after its commit")
    }

    /// Android's reset as its `sealResetDm` seals one toward us, from `android`'s store, at `stamp`.
    private func androidsReset(_ android: AndroidPeer, prekey: PeerPrekey, id: String, at stamp: Int64) throws -> TestFrame {
        try android.resetDm(to: me, prekey: prekey, id: id, at: stamp)
    }

    /// knit-next ADR 2026-09.qerd's receiving half (`aResetMarkerUnderTheSessionWeAlreadyHoldStillReSealsAndFlushes`,
    /// `InboundPipelineTest.kt:5383-5404`): Android's init is still unanswered, so its reset is the marker sealed under
    /// that session, which opens as the same session. The re-seal it asks of us is P5b's.
    @Test func aResetMarkerUnderTheSessionWeAlreadyHoldOpensAsThatSession() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "first", sentAt: now), from: android)
        let root = try #require(fixture.ratchetRecords(of: alice).session).root
        let mark = try androidsReset(android, prekey: prekey, id: "mark", at: now + 1)
        let header = try #require(try ChatContent(decoding: mark.envelope.payload).enc?.ratchet)
        #expect(header.flags & RatchetHeader.resetFlag != 0 && header.initial != nil, "flagged, under the init it already sent")
        fixture.deliver(mark, from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.root == root, "the same session")
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [2], "its chain advanced")
        #expect(fixture.stores.messages.message("mark") == nil)
        #expect(fixture.acknowledged(by: android) == ["first"], "a reset is machinery, never acknowledged")
    }

    /// knit-next's `anInboundResetReplacesTheSessionAndTriggersTheUnackedReseal` (`InboundPipelineTest.kt:5310-5339`):
    /// Android wiped, so its reset is a fresh init, flagged, which replaces the session we hold past the minute's floor,
    /// and what it sends next opens. The re-seal of our unacked DMs it asks for is P5b's.
    @Test func androidsResetReplacesOurSessionAndItsNextDmOpens() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "first", sentAt: now), from: android)
        let before = try #require(fixture.ratchetRecords(of: alice).session)

        fixture.clock.advance(Self.minute)
        let reborn = try AndroidPeer(alice)
        fixture.deliver(try androidsReset(reborn, prekey: prekey, id: "reset", at: now + Self.minute), from: reborn)
        let after = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(after.root != before.root && after.establishedAt == now + Self.minute, "the flagged init replaced the session")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).lastReplacementAt == now + Self.minute, "settled after its commit")
        #expect(fixture.stores.messages.message("reset") == nil && fixture.acknowledged(by: android) == ["first"])

        fixture.deliver(try reborn.dm("again", to: me, prekey: prekey, id: "second", sentAt: now + Self.minute + 1), from: reborn)
        #expect(fixture.stores.messages.message("second")?.body == "again")
        #expect(rootHash(fixture.ratchetRecords(of: alice).session?.root) == rootHash(reborn.session(with: me)?.root))
    }

    @Test func twoInitsAtOnceConvergeOnOneRoot() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        // Both start a session before either hears the other's: ours as a reset, hers as a DM.
        guard case .sent = fixture.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our init goes")
            return
        }
        let ourInit = try #require(fixture.resetsSent(to: alice).last)
        let theirDM = try android.dm("hi", to: me, prekey: try fixture.ourPrekey(), id: "theirs", sentAt: now)
        fixture.deliver(theirDM, from: android)
        _ = try android.open(ourInit, from: me, now: now)
        #expect(fixture.stores.messages.message("theirs")?.body == "hi", "the race's other opener still reads")
        let ours = try #require(fixture.ratchetRecords(of: alice).session)
        let theirs = try #require(android.session(with: me))
        #expect(rootHash(ours.root) == rootHash(theirs.root), "the smaller node id's root, on both phones")
        #expect(ours.weAreInitiator != theirs.weAreInitiator)
    }

    /// A reinstall keeps the Keychain's identity and prekeys and loses the database (ADR 2026-09.tkww): Android's frames,
    /// sealed under a session the iPhone no longer holds, fail as `NO_SESSION`, the heuristic sends a reset, Android adopts
    /// it, and what Android sends next opens.
    @Test func aReinstalledIPhoneRecoversThroughTheHeuristicsReset() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        try resetReachesAndroid(first, android)
        let prekey = try first.ourPrekey()
        first.deliver(try android.dm("before", to: me, prekey: prekey, id: "before", sentAt: now), from: android)
        #expect(first.ratchetRecords(of: alice).session?.confirmed == true)

        let reinstalled = try EngineFixture.ratcheting(me, keychain: keychain, wall: now + 2 * Self.minute)
        try reinstalled.pin(android)
        reinstalled.transport.clear()
        for index in 0..<RatchetResetPolicy.distinctFrames {
            let stamp = now + 2 * Self.minute + Int64(index)
            reinstalled.deliver(try android.dm("lost", to: me, prekey: prekey, id: "lost-\(index)", sentAt: stamp), from: android)
        }
        #expect(reinstalled.engine.dropped[.ratchetNoSession] == 3)
        let reset = try #require(reinstalled.resetsSent(to: alice).last)
        let opened = try android.open(reset, from: me, now: now + 2 * Self.minute)
        #expect(plaintext(opened) == RatchetSessions.resetPlaintext, "Android adopts it")

        let stamp = now + 3 * Self.minute
        reinstalled.deliver(try android.dm("again", to: me, prekey: prekey, id: "again", sentAt: stamp), from: android)
        #expect(reinstalled.stores.messages.message("again")?.body == "again")
        #expect(rootHash(reinstalled.ratchetRecords(of: alice).session?.root) == rootHash(android.session(with: me)?.root))
    }

    /// The blobs re-review's first finding: after our reset Android re-seals its unacked DMs under their own ids and
    /// stamps, and our custody keeps the first bytes stored under an id, the seal that could not open. A re-seal whose
    /// unit fails is opened again from the copy that failed, so the sweep delivers it once and buys no second reset.
    @Test(arguments: StoreKind.allCases)
    func aReSealWhoseUnitFailsIsOpenedAgainFromTheCopyThatFailed(kind: StoreKind) throws {
        let directory = scratchDirectory("re-seal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        try resetReachesAndroid(first, android)
        let prekey = try first.ourPrekey()
        first.deliver(try android.dm("before", to: me, prekey: prekey, id: "before", sentAt: now), from: android)

        let reinstalled = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 2 * Self.minute)
        try reinstalled.pin(android)
        reinstalled.transport.clear()
        let stamp = now + 2 * Self.minute
        for index in 0..<RatchetResetPolicy.distinctFrames {
            let lost = try android.dm("lost", to: me, prekey: prekey, id: "lost-\(index)", sentAt: stamp + Int64(index))
            reinstalled.deliver(lost, from: android)
        }
        #expect(reinstalled.stores.custody.contains("lost-0"), "the old seal, carried")
        let reset = try #require(reinstalled.resetsSent(to: alice).last)
        _ = try android.open(reset, from: me, now: stamp)

        let reSeal = try android.dm(MessageContent(body: "lost"), to: me, prekey: prekey, id: "lost-0", sentAt: stamp, now: stamp + 1000)
        refusing.refusesRows = true
        reinstalled.deliver(reSeal, from: android)
        refusing.refusesRows = false
        #expect(reinstalled.engine.dropped[.storeRefused] == 1)

        reinstalled.advance(MeshConfiguration().sweepMilliseconds)
        #expect(reinstalled.stores.messages.message("lost-0")?.body == "lost")
        #expect(reinstalled.acknowledged(by: android).filter { $0 == "lost-0" }.count == 1)
        #expect(reinstalled.resetsSent(to: alice).count == 1)
    }

    /// The start opens again every ratchet DM to us that custody holds with no row: here one that came while the switch was
    /// off, one spent already, which changes nothing, and one from a sender whose pin cannot be read.
    @Test func theStartReplaysRatchetMessagesCustodyHoldsWithNoRow() throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        var ring = try PrekeyRing.load(for: me.keys, from: keychain)
        _ = try ring.rotate(now: now)
        let stores = MeshStores.inMemory()
        let off = EngineFixture(me, stores: stores, prekeys: ring)
        let android = try AndroidPeer(alice)
        try off.pin(android)
        let newest = try #require(ring.newest)
        let prekey = try #require(PeerPrekey(verifying: newest.info, signedBy: me.keys.bundle))
        off.deliver(try android.dm("while off", to: me, prekey: prekey, id: "while-off", sentAt: now), from: android)
        #expect(off.engine.dropped[.cannotOpen] == 1)

        let dana = TestPeer(seed: 4)
        let stranger = try AndroidPeer(dana)
        let orphan = try stranger.dm("who", to: me, prekey: prekey, id: "unpinned", sentAt: now)
        stores.custody.store(
            CarriedFrame(envelope: orphan.envelope, sig: orphan.wire.sig, signed: orphan.wire.signed), origin: .relayed, now: now)
        stores.peers.upsert(PeerRecord(nodeId: dana.nodeId, name: "", status: "", publicKey: "not a bundle", updatedAt: 1))

        let on = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        #expect(stores.messages.message("while-off")?.body == "while off")
        #expect(receivedRecords(in: on.engine.drainEvents()).map(\.id) == ["while-off"])
        #expect(on.acknowledged(by: android) == ["while-off"])
        #expect(on.engine.dropped[.noSenderKey] == 1, "a pin that cannot be read opens nothing")

        // A third start finds the reset marker spent: a duplicate, and nothing else.
        let spent = try android.dm(
            MessageContent(body: "", ctl: MessageContent.Control.sessionReset), to: me, prekey: prekey, id: "ctl", sentAt: now + 1)
        on.deliver(spent, from: android)
        let again = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        #expect(again.engine.dropped[.ratchetDuplicate] == 1)
        #expect(receivedRecords(in: again.engine.drainEvents()).isEmpty)
        #expect(again.transport.written(.receipt).isEmpty && again.sealedReceipts(to: android).isEmpty)
    }

    @Test func theRatchetsSweepRunsAtStartAndHourlyWithTheSwitchOnAndNeverOff() throws {
        for on in [true, false] {
            let stores = MeshStores.inMemory()
            let stale = RatchetSkippedKeyRecord(
                epoch: 1, rootTag: 7, index: 0, messageKey: [1], createdAt: now - RatchetRetention.skippedKeyMilliseconds - 1)
            plant(stale, for: alice, in: stores)
            let fixture = on ? try EngineFixture.ratcheting(me, stores: stores) : EngineFixture(me, stores: stores)
            #expect(stores.ratchet.records(of: alice.nodeId).skippedKeys.isEmpty == on, "at start, switch \(on)")

            let aging = RatchetSkippedKeyRecord(
                epoch: 1, rootTag: 7, index: 1, messageKey: [2], createdAt: now - RatchetRetention.skippedKeyMilliseconds + 30 * Self.minute
            )
            plant(aging, for: alice, in: stores)
            fixture.advance(45 * Self.minute)
            #expect(stores.ratchet.records(of: alice.nodeId).skippedKeys.map(\.index).contains(1), "expired, and the hour not up")
            fixture.advance(20 * Self.minute)
            #expect(stores.ratchet.records(of: alice.nodeId).skippedKeys.map(\.index).contains(1) != on, "hourly, switch \(on)")
        }
    }

    /// A skipped key held for `peer`, as an open that skipped an index leaves one.
    private func plant(_ key: RatchetSkippedKeyRecord, for peer: TestPeer, in stores: MeshStores) {
        let session = RatchetSessionRecord(
            peerId: peer.nodeId, confirmed: true, weAreInitiator: false, root: [1], establishedAt: 1, sendEpoch: 1)
        let delta = RatchetOpenDelta(
            session: session, recvEpoch: nil, skippedInserts: [key], consumedSkippedTag: nil, purgePeerRecvState: false)
        stores.ratchet.applyOpen(delta, from: peer.nodeId, se: 1, n: 99)
    }
}
