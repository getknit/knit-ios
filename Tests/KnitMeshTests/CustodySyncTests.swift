import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What a node carries and serves, ported from knit-next's `ForwardSyncTest`.
@Suite struct CustodySyncTests: CustodySyncCase {
    @Test func aRelayedFrameIsCarriedOnlyWhenItAuthenticates() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let unauthentic = sync.carry(frame("m1", to: bob), in: store, now: now) { false }
        let authentic = sync.carry(frame("m2", to: bob), in: store, now: now) { true }
        #expect(!unauthentic)
        #expect(authentic)
        #expect(!store.contains("m1"))
        #expect(store.contains("m2"))
    }

    @Test func ourOwnFramesSkipAuthentication() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let carried = sync.carryOwn(frame("m1", to: bob), in: store, now: now)
        #expect(carried)
    }

    @Test func everyCustodialTypeIsCarriedAndNothingElse() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let carried: [FrameType] = [.chat, .receipt, .reaction, .profile, .groupUpdate, .groupLeave]
        let refused: [FrameType] = [.keyRequest, .blobRequest, .blobHave, .blobHas, .typing, .commons, FrameType(rawValue: "future")]
        for type in carried + refused {
            _ = sync.carry(frame(type.rawValue, type: type), in: store, now: now) { true }
        }
        #expect(Set(store.liveIds(now: now)) == Set(carried.map(\.rawValue)))
    }

    @Test func aFrameWithNoSentAtIsRefusedEvenAsOurOwn() {
        // Work item #16: an origination that forgot sentAt expired in 1970 on every node, the author's included.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let undated = sync.carryOwn(frame("r0", type: .receipt, sentAt: 0), in: store, now: now)
        let dated = sync.carryOwn(frame("r1", type: .receipt), in: store, now: now)
        #expect(!undated)
        #expect(dated)
    }

    @Test func anOversizeFrameIsRefusedCountedAndLoggedOnEveryOrigin() {
        // knit-next #227: the cap binds our own frames as it binds a relayed one, and the counter moves for each.
        let store = MemoryCustodyStore(limits: CustodyLimits(maxSignedBytes: 2048))
        let log = RecordingLog()
        var sync = CustodySync(log: log)
        let relayed = sync.carry(frame("big-relayed", to: bob, payloadBytes: 2100), in: store, now: now) { true }
        let own = sync.carryOwn(frame("big-own", to: bob, payloadBytes: 2100), in: store, now: now)
        let small = sync.carryOwn(frame("small", to: bob, payloadBytes: 100), in: store, now: now)
        #expect(!relayed && !own && small)
        #expect(store.liveIds(now: now) == ["small"])
        #expect(sync.oversizeRefusedCount == 2)
        #expect(sync.groupRefusedCount == 0)
        let lines = log.all.filter { $0.contains("signed bytes over the cap") }
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("debug custody refused big-rela (chat): ") == true, "the id truncated, the type, the length")
        #expect(!(lines.first?.contains("*") ?? true), "never the payload")
    }

    @Test func anOversizeFrameNamingAForeignRosterCountsAsOversizeAlone() {
        let store = MemoryCustodyStore(limits: CustodyLimits(maxSignedBytes: 2048))
        var sync = CustodySync()
        // alice sends under a roster that does not name her: the group gate's refusal, were the frame not oversize first.
        let foreign = frame("g-big", members: [bob, zed], payloadBytes: 2100)
        let carried = sync.carry(foreign, in: store, now: now) { true }
        #expect(!carried)
        #expect(sync.oversizeRefusedCount == 1)
        #expect(sync.groupRefusedCount == 0, "Android's order: the byte cap first")
        let small = sync.carry(frame("g-small", members: [bob, zed]), in: store, now: now) { true }
        #expect(!small)
        #expect(sync.oversizeRefusedCount == 1 && sync.groupRefusedCount == 1)
    }

    @Test func aProfileOverTheProfileCapIsCountedApartAndLogged() {
        let store = MemoryCustodyStore(limits: CustodyLimits(maxSignedBytes: 4096, maxProfileSignedBytes: 1024))
        let log = RecordingLog()
        var sync = CustodySync(log: log)
        let relayed = sync.carry(frame("prof-relayed", type: .profile, payloadBytes: 1100), in: store, now: now) { true }
        let own = sync.carryOwn(frame("prof-own", type: .profile, payloadBytes: 1100), in: store, now: now)
        let chat = sync.carry(frame("chat", to: bob, payloadBytes: 1100), in: store, now: now) { true }
        #expect(!relayed && !own && chat, "a chat of the same size is carried")
        #expect(store.liveIds(now: now) == ["chat"])
        #expect(sync.profileOversizeRefusedCount == 2)
        #expect(sync.oversizeRefusedCount == 0 && sync.groupRefusedCount == 0)
        let lines = log.all.filter { $0.contains("signed bytes over the profile cap") }
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("debug custody refused prof-rel (profile): ") == true, "the id truncated, the type, the length")
        #expect(!(lines.first?.contains("*") ?? true), "never the payload")
    }

    @Test func aProfileOverBothCapsMovesOnlyTheOversizeCounter() {
        let store = MemoryCustodyStore(limits: CustodyLimits(maxSignedBytes: 2048, maxProfileSignedBytes: 1024))
        var sync = CustodySync()
        let carried = sync.carry(frame("prof-big", type: .profile, payloadBytes: 2100), in: store, now: now) { true }
        #expect(!carried)
        #expect(sync.oversizeRefusedCount == 1)
        #expect(sync.profileOversizeRefusedCount == 0, "the byte cap comes first")
    }

    @Test func aHeldFrameIsNotAuthenticatedAgain() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        var checks = 0
        _ = sync.carry(frame("m1"), in: store, now: now) {
            checks += 1
            return true
        }
        let again = sync.carry(frame("m1"), in: store, now: now) {
            checks += 1
            return true
        }
        #expect(!again)
        #expect(checks == 1)
    }

    @Test func aDigestIsAnsweredWithOnlyWhatThePeerLacks() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for id in ["r1", "r2", "r3"] {
            _ = sync.carry(frame(id), in: store, now: now) { true }
        }
        #expect(Set(ids(sync.missing(from: ["r2"], for: zed, in: store, now: now))) == ["r1", "r3"])
        #expect(sync.missing(from: ["r1", "r2", "r3", "extra"], for: zed, in: store, now: now).frames.isEmpty)
    }

    @Test func profilesAreServedAheadOfEverythingElse() {
        // Newest-received first put a sender's profile behind its chat, so a newcomer refused the chat for want
        // of the key (knit-next ADR 2026-09.9xuu). Profiles lead; the rest keep the store's order.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("profile-a", type: .profile), in: store, now: now) { true }
        for id in ["c1", "c2", "c3"] {
            _ = sync.carry(frame(id), in: store, now: now + 1) { true }
        }
        _ = sync.carry(frame("profile-b", type: .profile, from: bob), in: store, now: now + 2) { true }
        let served = ids(sync.missing(from: [], for: zed, in: store, now: now + 3))
        #expect(served.prefix(2).sorted() == ["profile-a", "profile-b"])
        #expect(served.dropFirst(2).sorted() == ["c1", "c2", "c3"])
    }

    @Test func aServedFrameIsAFreshFloodAroundTheVerbatimBytes() throws {
        let store = MemoryCustodyStore()
        let original = frame("p1", type: .profile)
        var sync = CustodySync()
        _ = sync.carry(original, in: store, now: now) { true }
        let served = try #require(sync.missing(from: [], for: bob, in: store, now: now).frames.first)
        #expect(served == WireEnvelope(ttl: 8, hops: 0, relay: true, sig: original.sig, signed: original.signed))
    }

    @Test func anAuthorWhoseDigestLacksItsOwnFrameIsServedIt() {
        // A node whose custody was wiped gets its own sends back this way, and the digests reconverge.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("m1", from: alice, to: bob), in: store, now: now) { true }
        #expect(sync.missing(from: ["m1"], for: alice, in: store, now: now).frames.isEmpty)
        #expect(ids(sync.missing(from: [], for: alice, in: store, now: now)) == ["m1"])
    }

    @Test func aDigestIsAnsweredAgainEveryTime() {
        // A serve lost to a torn-down link heals at the next exchange; a duplicate that landed costs only bytes.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carryOwn(frame("m1", to: bob), in: store, now: now)
        let serves = (0..<3).flatMap { _ in ids(sync.missing(from: [], for: bob, in: store, now: now)) }
        #expect(serves == ["m1", "m1", "m1"])
    }

    @Test func aGroupFrameIsServedOnlyToItsMembers() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carryOwn(frame("g1", members: [alice, bob]), in: store, now: now)
        #expect(sync.missing(from: [], for: zed, in: store, now: now).frames.isEmpty)
        #expect(ids(sync.missing(from: [], for: bob, in: store, now: now)) == ["g1"])
    }

    // MARK: The key ahead of a backlog (knit-next ADR 2026-09.g64k, `ForwardSyncTest`'s `onDigestServes…Key…`)

    @Test func aKeylessSendersKeyGoesAheadOfTheirBacklogOncePerSender() {
        // Custody holds no profile of theirs, and the peer holds none of their frames: each key goes first, once.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for (id, sender) in [("r1", alice), ("r2", alice), ("s1", bob)] {
            _ = sync.carry(frame(id, from: sender), in: store, now: now) { true }
        }
        let reply = round(sync, for: zed, in: store)
        #expect(reply.keysAhead.sorted() == [alice, bob].sorted())
        #expect(reply.keys.map(Self.frameKey) == reply.keysAhead.map { Self.frameKey(Self.key(of: $0)) })
        #expect(reply.frames.count == 3)
    }

    @Test func noKeyGoesForASenderWhoseProfileCustodyHolds() {
        // Their profile goes first already, or the peer holds it: no second copy of the key.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("p1", type: .profile), in: store, now: now) { true }
        _ = sync.carry(frame("r1"), in: store, now: now) { true }
        #expect(round(sync, for: zed, in: store).keysAhead.isEmpty)
        #expect(round(sync, from: ["p1"], for: zed, in: store).keysAhead.isEmpty)
    }

    @Test func noKeyGoesToAPeerHoldingAFrameOfTheSenders() {
        // A peer that custodies one of their frames verified it, so it has the key: two carriers of one chatty
        // sender whose profile the quota evicted do not trade the key on every reconcile.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("r1"), in: store, now: now) { true }
        _ = sync.carry(frame("r2"), in: store, now: now) { true }
        let reply = round(sync, from: ["r1"], for: zed, in: store)
        #expect(ids(reply) == ["r2"])
        #expect(reply.keysAhead.isEmpty)
    }

    @Test func noKeyGoesForTheDigestsOwnSender() {
        // Its own frames coming home after a wipe: the key is its own.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("r1", from: zed), in: store, now: now) { true }
        let reply = round(sync, for: zed, in: store)
        #expect(ids(reply) == ["r1"])
        #expect(reply.keysAhead.isEmpty)
    }

    @Test func noKeyGoesWhenNothingOfTheSendersGoesOut() {
        // A key rides only with a backlog: here the peer holds Alice's post, and is not in Bob's group.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("r1"), in: store, now: now) { true }
        _ = sync.carry(frame("g1", from: bob, members: [bob, alice]), in: store, now: now) { true }
        let reply = round(sync, from: ["r1"], for: zed, in: store)
        #expect(reply.frames.isEmpty)
        #expect(reply.keysAhead.isEmpty)
    }

    @Test func noKeyGoesForASenderThatIsNoNodeId() {
        // Nothing pins such a sender, so nothing holds a key to send; the frame itself still goes.
        let store = MemoryCustodyStore()
        let envelope = RelayEnvelope(type: .chat, id: "odd", senderId: "not-a-node", sentAt: now, payload: [])
        var sync = CustodySync()
        _ = sync.carry(CarriedFrame(envelope: envelope, sig: [1], signed: envelope.encoded), in: store, now: now) { true }
        let reply = round(sync, for: zed, in: store)
        #expect(ids(reply) == ["odd"])
        #expect(reply.keysAhead.isEmpty)
    }

    @Test func aReceiptFromTheRecipientPurgesAndTombstonesTheDM() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        #expect(!store.contains("m1"))
        #expect(sync.isTombstoned("m1", now: now))
        let again = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        #expect(!again, "the tombstone blocks a re-store")
    }

    @Test func aForgedReceiptPurgesNothing() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        sync.acknowledge("m1", from: zed.string, in: store, now: now)
        sync.acknowledge("unknown", from: bob.string, in: store, now: now)
        #expect(store.contains("m1"))
        #expect(!sync.isTombstoned("m1", now: now))
    }

    @Test func roomAndGroupFramesAreNeverPurgedByAReceipt() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("room"), in: store, now: now) { true }
        _ = sync.carry(frame("g1", members: [alice, bob]), in: store, now: now) { true }
        sync.acknowledge("room", from: bob.string, in: store, now: now)
        sync.acknowledge("g1", from: bob.string, in: store, now: now)
        #expect(store.contains("room") && store.contains("g1"))
    }

    @Test func aTombstoneLastsTheCustodyTTL() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        #expect(sync.isTombstoned("m1", now: now + CustodySync.tombstoneMilliseconds - 1))
        #expect(!sync.isTombstoned("m1", now: now + CustodySync.tombstoneMilliseconds))
    }
}

// MARK: - A receipt that lands before its DM (knit-next ADR 2026-09.adpz, `ForwardSyncTest`'s "a receipt that lands before its DM")

extension CustodySyncTests {
    @Test func aReceiptBeforeItsDMVaccinatesTheDMOnArrival() {
        // Back-fill serves the receipt ahead of the older DM, or the recipient sends it before relaying the DM.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        var checks = 0
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        let carried = sync.carry(frame("m1", to: bob), in: store, now: now) {
            checks += 1
            return true
        }
        #expect(!carried)
        #expect(!store.contains("m1"), "the DM its receipt beat here is never carried")
        #expect(checks == 0, "refused before it is authenticated, as knit-next refuses it")
        #expect(sync.isTombstoned("m1", now: now), "and tombstoned as a purge leaves it")
        let again = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        #expect(!again)
    }

    @Test func anEarlyReceiptVaccinatesOurOwnDMToo() {
        // The rule holds whatever the origin, so every node carries the same ids.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        let carried = sync.carryOwn(frame("m1", to: bob), in: store, now: now)
        #expect(!carried)
        #expect(!store.contains("m1"))
    }

    @Test func anEarlyReceiptFromANonRecipientVaccinatesNothing() {
        // Keyed on the acker: a signed receipt from anyone but the DM's recipient cannot keep the DM out of custody.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        sync.acknowledge("m1", from: zed.string, in: store, now: now)
        let carried = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        #expect(carried)
        #expect(!sync.isTombstoned("m1", now: now))
    }

    @Test func anEarlyReceiptLapsesWithTheTombstone() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        sync.acknowledge("m2", from: bob.string, in: store, now: now)
        let lastMoment = now + CustodySync.tombstoneMilliseconds - 1
        let lapsed = now + CustodySync.tombstoneMilliseconds
        let stillRemembered = sync.carry(frame("m1", to: bob, sentAt: lastMoment), in: store, now: lastMoment) { true }
        let forgotten = sync.carry(frame("m2", to: bob, sentAt: lapsed), in: store, now: lapsed) { true }
        #expect(!stillRemembered)
        #expect(forgotten)
    }

    @Test func anEarlyReceiptNeverTouchesAGroupOrRoomFrame() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        sync.acknowledge("g1", from: bob.string, in: store, now: now)
        sync.acknowledge("room", from: bob.string, in: store, now: now)
        let group = sync.carry(frame("g1", members: [alice, bob]), in: store, now: now) { true }
        let room = sync.carry(frame("room"), in: store, now: now) { true }
        #expect(group, "a group frame has no recipient")
        #expect(room, "nor has a room post")
    }

    @Test func everyReceiptIsRememberedOnceInABoundedSet() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        sync.acknowledge("m1", from: bob.string, in: store, now: now + 1)
        sync.acknowledge("m1", from: zed.string, in: store, now: now + 1)
        #expect(sync.earlyReceiptCount == 2, "one per acknowledged id and acker")
    }
}
