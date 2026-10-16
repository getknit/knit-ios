import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The re-seal after a received reset (ADR 2026-10.5sk9, phase P5b; ADR 2026-09.2ved, amended): our unacked DMs of the last
/// day sealed again under the session now held, once, after the reset's first verdict commits, however that open went
/// (`InboundPipeline.kt:1137-1148`, `MeshManager.kt:3361-3407`), and never from the start's replay. The three triggers are
/// the P5a crypto re-review's.
@Suite struct MeshEngineRatchetResealTests {
    /// The iPhone, whose node id sorts first, so a race it is in is its own to win.
    private let me: TestPeer
    private let alice: TestPeer
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    init() {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        me = pair[0]
        alice = pair[1]
    }

    /// The DM frames `fixture` wrote under `id`.
    private func chats(_ fixture: EngineFixture, id: String) -> [Written] {
        fixture.transport.written(.chat).filter { $0.envelope.id == id }
    }

    /// What `android` reads of `written`, at `now`.
    private func body(_ written: Written, read android: AndroidPeer, at now: Int64) throws -> String? {
        let bytes = try #require(plaintext(try android.open(written, from: me, now: now)))
        return MessageContentV2.decode(bytes)?.body
    }

    /// (i) A reset race the iPhone wins: Android, wiped, resets while our own init is still unanswered. Its reset opens read
    /// only under its root, our root stays, and each unacked DM is sealed again once, under our init; Android reads them
    /// once it adopts our root.
    @Test func aResetRaceTheIPhoneWinsReSealsEachUnackedDMOnce() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let first = try #require(iphone.engine.sendDirectMessage("one", to: alice.nodeId)).id
        let second = try #require(iphone.engine.sendDirectMessage("two", to: alice.nodeId)).id
        let originals = iphone.transport.written(.chat).map(\.wire.signed)
        let ours = try #require(iphone.ratchetRecords(of: alice).session)
        #expect(ours.weAreInitiator && !ours.confirmed)

        iphone.clock.advance(Self.minute)
        let reset = try android.resetDm(to: me, prekey: try iphone.ourPrekey(), id: "android-reset", at: now + Self.minute)
        iphone.deliver(reset, from: android)
        #expect(iphone.ratchetRecords(of: alice).session?.root == ours.root, "the race is ours: our root stays")
        #expect(chats(iphone, id: first).count == 2 && chats(iphone, id: second).count == 2, "each sealed again once")
        let reseals = [first, second].compactMap { chats(iphone, id: $0).last }
        #expect(reseals.allSatisfy { $0.to == nil && !originals.contains($0.wire.signed) }, "new bytes, flown live")
        #expect(reseals.allSatisfy { me.keys.bundle.isValidSignature($0.wire.sig, for: $0.wire.signed) })
        #expect(iphone.stores.custody.frame(first, now: now + Self.minute)?.signed == originals.first, "custody keeps the first bytes")
        #expect(iphone.engine.seals == RatchetSealCounts(dmSealedV2: 4, dmSealedV3: 4))

        #expect(try reseals.map { try body($0, read: android, at: now + Self.minute) } == ["one", "two"])
        #expect(android.session(with: me)?.root == ours.root, "Android lost the race and took our root")
    }

    /// (ii) Android's mark under the session held: its own plain init is still unanswered, so its reset is the marker
    /// sealed under it. It opens under the session we hold, no root moves, and our unacked DM is sealed again once.
    @Test func androidsMarkUnderTheSessionHeldReSealsOnceWithNoRootMoved() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let prekey = try iphone.ourPrekey()
        iphone.deliver(try android.dm("hello", to: me, prekey: prekey, id: "hello", sentAt: now, v3: true), from: android)
        let held = try #require(iphone.ratchetRecords(of: alice).session)
        #expect(held.confirmed && !held.weAreInitiator)
        let unacked = try #require(iphone.engine.sendDirectMessage("answer", to: alice.nodeId)).id

        let mark = try android.resetDm(to: me, prekey: prekey, id: "mark", at: now + 1000)
        #expect(try ChatContent(decoding: mark.envelope.payload).enc?.ratchet?.initial != nil, "a marker under its pending init")
        iphone.deliver(mark, from: android)
        #expect(iphone.ratchetRecords(of: alice).session?.root == held.root, "no root moved")
        let copies = chats(iphone, id: unacked)
        #expect(copies.count == 2, "sealed once more")
        #expect(try body(try #require(copies.last), read: android, at: now + 1000) == "answer")
        #expect(android.session(with: me)?.confirmed == true, "our answer confirmed Android's init")
    }

    /// (iv) A reset race the iPhone loses (the P5b crypto review): Android's id sorts first, so the init its reset carries
    /// wins over our own unanswered one. We adopt Android's root, seal our unacked DM again once under it, and Android
    /// reads the copy.
    @Test func aResetRaceTheIPhoneLosesReSealsOnceUnderAndroidsRoot() throws {
        let iphone = try EngineFixture.ratcheting(alice)
        let android = try AndroidPeer(me)
        try iphone.pin(android)
        let unacked = try #require(iphone.engine.sendDirectMessage("one", to: me.nodeId)).id
        let ours = try #require(iphone.ratchetRecords(of: me).session)
        #expect(ours.weAreInitiator && !ours.confirmed)

        iphone.clock.advance(Self.minute)
        let reset = try android.resetDm(to: alice, prekey: try iphone.ourPrekey(), id: "android-reset", at: now + Self.minute)
        iphone.deliver(reset, from: android)
        let adopted = try #require(iphone.ratchetRecords(of: me).session)
        #expect(adopted.root != ours.root && !adopted.weAreInitiator, "the race is Android's: we took its root")
        #expect(adopted.root == android.session(with: alice)?.root)
        let copies = chats(iphone, id: unacked)
        #expect(copies.count == 2, "sealed again once")
        let copy = try #require(copies.last)
        let bytes = try #require(plaintext(try android.open(copy, from: alice, now: now + Self.minute)))
        #expect(MessageContentV2.decode(bytes)?.body == "one", "Android reads the copy")
        #expect(iphone.engine.seals == RatchetSealCounts(dmSealedV2: 2, dmSealedV3: 2))
    }

    /// A reborn Android's reset whose unit failed here, its copy kept for the sweep: the engine, the reborn phone, the reset,
    /// and the id of our DM no receipt acknowledged.
    private struct KeptReset {
        let iphone: EngineFixture
        let reborn: AndroidPeer
        let reset: TestFrame
        let unacked: String
    }

    /// The reborn phone's reset delivered over stores of `kind` while our ratchet store refuses writes, so its unit fails.
    private func resetKept(_ kind: StoreKind, in directory: URL) throws -> KeptReset {
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let prekey = try iphone.ourPrekey()
        iphone.deliver(try android.dm("hello", to: me, prekey: prekey, id: "hello", sentAt: now, v3: true), from: android)
        let unacked = try #require(iphone.engine.sendDirectMessage("held", to: alice.nodeId)).id

        iphone.clock.advance(2 * Self.minute)
        let reborn = try AndroidPeer(alice)
        let reset = try reborn.resetDm(to: me, prekey: prekey, id: "reborn-reset", at: now + 2 * Self.minute)
        refusing.refusesWrites = true
        iphone.deliver(reset, from: reborn)
        refusing.refusesWrites = false
        #expect(iphone.engine.dropped[.storeRefused] == 1, "the reset's unit failed, and its copy is kept")
        #expect(chats(iphone, id: unacked).count == 1, "a unit that failed seals nothing again")
        return KeptReset(iphone: iphone, reborn: reborn, reset: reset, unacked: unacked)
    }

    /// The P5b crypto review's first owed test: the sweep's open of the kept copy is the reset's first committed verdict,
    /// so the unacked DM is sealed again exactly once, then, and the reborn phone reads it.
    @Test(arguments: StoreKind.allCases)
    func aResetWhoseUnitFailedReSealsOnceWhenTheSweepOpensIt(kind: StoreKind) throws {
        let directory = scratchDirectory("reseal-sweep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try resetKept(kind, in: directory)
        kept.iphone.advance(sweep)
        #expect(chats(kept.iphone, id: kept.unacked).count == 2, "the sweep's commit sealed it again once")
        kept.iphone.advance(sweep)
        #expect(chats(kept.iphone, id: kept.unacked).count == 2, "and only once")
        let copy = try #require(chats(kept.iphone, id: kept.unacked).last)
        #expect(try body(copy, read: kept.reborn, at: kept.iphone.clock.wallMilliseconds()) == "held")
    }

    /// And when a neighbour's copy of the reset commits first, through the reopen the failure granted, that commit seals
    /// the DM again once, and the sweep lets the kept copy go and seals nothing again.
    @Test(arguments: StoreKind.allCases)
    func aResetWhoseUnitFailedReSealsOnceWhenANeighboursCopyCommitsFirst(kind: StoreKind) throws {
        let directory = scratchDirectory("reseal-neighbour")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try resetKept(kind, in: directory)
        kept.iphone.deliver(kept.reset, from: TestPeer(seed: 3))
        #expect(chats(kept.iphone, id: kept.unacked).count == 2, "the neighbour's copy committed, and sealed it again once")
        kept.iphone.advance(sweep)
        #expect(chats(kept.iphone, id: kept.unacked).count == 2, "the sweep sealed nothing again")
        #expect(kept.iphone.engine.dropped[.storeRefused] == 1)
    }

    /// (iii) A restart within the day re-opens Android's old reset, which our custody holds with no row, under the root
    /// our own re-root left draining: its first verdict re-sealed already, so the replay seals nothing again.
    @Test func aRestartWithinADayReOpensTheOldResetAndReSealsNothing() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        let prekey = try first.ourPrekey()
        first.deliver(try android.dm("hello", to: me, prekey: prekey, id: "hello", sentAt: now, v3: true), from: android)
        let unacked = try #require(first.engine.sendDirectMessage("still unacked", to: alice.nodeId)).id

        first.clock.advance(2 * Self.minute)
        let reborn = try AndroidPeer(alice)
        first.deliver(try reborn.resetDm(to: me, prekey: prekey, id: "reborn-reset", at: now + 2 * Self.minute), from: reborn)
        #expect(chats(first, id: unacked).count == 2, "the first verdict re-sealed it once")
        #expect(stores.custody.contains("reborn-reset"), "carried, so a restart finds it")

        first.clock.advance(Self.minute)
        guard case .sent(_, reRooted: true) = first.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our re-root goes")
            return
        }
        #expect(first.ratchetRecords(of: alice).recvEpochs.isEmpty, "our re-root purged the receive state of the era it left")
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + Self.minute * 60)
        #expect(restarted.engine.dropped.isEmpty)
        #expect(!restarted.ratchetRecords(of: alice).recvEpochs.isEmpty, "the old reset opened again, under the draining root")
        #expect(chats(restarted, id: unacked).isEmpty, "and sealed nothing again")
        #expect(restarted.engine.seals == RatchetSealCounts())
    }

    /// The re-seal's set (`unackedDmsTo`): ours to that peer from the last day, never acknowledged and not waiting; a file
    /// keeps its name and size, sealed from its row (knit-next `0fa6c548`), with only its hash beside the seal in the clear.
    @Test func theReSealTakesOnlyTheDaysUnackedDMsAndKeepsAFilesNameAndSize() throws {
        let iphone = try EngineFixture.ratcheting(me, wall: now)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let blob = BlobHash(of: Array("%PDF-1.7 quarterly figures".utf8))
        let file = MessageAttachment(
            hash: blob,
            mime: "application/pdf",
            key: Base64.encode([UInt8](repeating: 9, count: 32)),
            name: "quarterly-report.pdf",
            size: 1_400_000
        )
        func ours(_ id: String, to peer: TestPeer = alice, sentAt: Int64, delivered: Bool = false, pending: Bool = false) -> MessageRecord {
            MessageRecord(
                id: id,
                senderId: me.nodeId,
                recipientId: peer.nodeId,
                conversationId: peer.nodeId.string,
                body: id,
                sentAt: sentAt,
                delivered: delivered,
                pendingKey: pending,
                attachment: id == "file" ? file : nil
            )
        }
        for row in [
            ours("file", sentAt: now - Self.minute), ours("acked", sentAt: now, delivered: true),
            ours("waiting", sentAt: now, pending: true),
            ours("yesterday", sentAt: now - RatchetOutbound.resealMilliseconds - 1), ours("to-carol", to: TestPeer(seed: 3), sentAt: now),
        ] {
            iphone.stores.messages.save(row)
        }
        iphone.transport.clear()

        iphone.deliver(try android.resetDm(to: me, prekey: try iphone.ourPrekey(), id: "reset", at: now), from: android)
        // The reset carries Android's init, which our sealed profile answers first, as Kotlin's commit runs the answer before
        // the re-seal (`InboundPipeline.kt:1059-1067`, `:1140-1147`; phase P5e).
        let chats = iphone.transport.written(.chat)
        let answers = iphone.answerIds
        #expect(answers.count == 1 && chats.first.map { answers.contains(ExactKey($0.envelope.id)) } == true, "the answer first")
        #expect(chats.map(\.envelope.id).filter { !answers.contains(ExactKey($0)) } == ["file"])
        let resealed = try #require(chats.first { $0.envelope.id == "file" })
        #expect(try ChatContent(decoding: resealed.envelope.payload).attachmentHash == blob.string, "only the hash in the clear")
        let bytes = try #require(plaintext(try android.open(resealed, from: me, now: now)))
        let content = try #require(MessageContentV2.decode(bytes))
        #expect(content.attachmentName == "quarterly-report.pdf" && content.attachmentSize == 1_400_000)
        #expect(content.attachmentMime == "application/pdf" && content.attachmentKey == file.key && content.attachmentHash == blob.string)
    }

    /// A peer pinned without `CAP_RATCHET` that resets anyway, an Android whose newer profile has not reached us: our
    /// unacked DM to it went v1, and goes v1 again under its own id, through `sealEnvelopeFor`'s v1 arm
    /// (`MeshManager.kt:3388`, `:1307`), signed a second time and counted as no fallback. Custody keeps the first bytes.
    @Test func aResetFromAPeerPinnedWithoutTheBitReSealsV1() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        iphone.deliver(try alice.profile(publishedAt: now, capabilities: 0xF), from: alice)
        let unacked = try #require(iphone.engine.sendDirectMessage("plain", to: alice.nodeId)).id
        let original = try #require(chats(iphone, id: unacked).first)

        iphone.clock.advance(Self.minute)
        iphone.deliver(try android.resetDm(to: me, prekey: try iphone.ourPrekey(), id: "reset", at: now + Self.minute), from: android)
        let copies = chats(iphone, id: unacked)
        #expect(copies.count == 2, "sealed again once")
        let reseal = try #require(copies.last)
        #expect(reseal.to == nil && reseal.wire.signed != original.wire.signed)
        #expect(me.keys.bundle.isValidSignature(reseal.wire.sig, for: reseal.wire.signed))
        let enc = try #require(try ChatContent(decoding: reseal.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.staticKeys)
        let header = MessageCrypto.header(
            id: unacked, senderId: me.nodeId.string, sentAt: reseal.envelope.sentAt, thread: alice.nodeId.string)
        #expect(MessageCrypto.open(enc, header: header, as: alice.keys)?.body == "plain")
        #expect(
            iphone.stores.custody.frame(unacked, now: now + Self.minute)?.signed == original.wire.signed, "custody keeps the first bytes")
        #expect(iphone.engine.seals == RatchetSealCounts(), "v1 to a peer without the bit is no fallback")
    }

    /// Called for a peer whose reset could not have opened, the re-seal seals nothing: a pin whose bundle does not decode
    /// leaves the DM where it is, and an identity key the v1 seal refuses, a low-order point, is skipped.
    @Test func theReSealSealsNothingToAPeerItCannotSealTo() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let lowOrder = try #require(
            PublicKeyBundle(signingKey: alice.keys.bundle.signingKey, agreementKey: [UInt8](repeating: 0, count: 32)))
        for (peer, key) in [(alice.nodeId, "not a bundle"), (lowOrder.nodeId, lowOrder.encoded)] {
            iphone.stores.peers.upsert(PeerRecord(nodeId: peer, name: "", status: "", publicKey: key, capabilities: 0xF, updatedAt: 1))
            iphone.stores.messages.save(
                MessageRecord(id: "to-\(peer)", senderId: me.nodeId, recipientId: peer, conversationId: peer.string, body: "x", sentAt: now)
            )
            iphone.engine.resealRecentDirectMessages(to: peer)
        }
        #expect(iphone.transport.written(.chat).isEmpty)
    }

    /// A reset from someone we blocked never reaches the ratchet, and the re-seal itself checks the block again, as
    /// `resealRecentDmsTo` does.
    @Test func nothingIsSealedAgainForABlockedPeer() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let unacked = try #require(iphone.engine.sendDirectMessage("hi", to: alice.nodeId)).id
        iphone.engine.block(alice.nodeId)
        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        #expect(chats(iphone, id: unacked).count == 1)
    }
}
