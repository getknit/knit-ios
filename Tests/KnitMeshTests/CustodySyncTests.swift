import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What a node carries and serves, ported from knit-next's `ForwardSyncTest`.
@Suite struct CustodySyncTests {
    private let now: Int64 = 1_756_200_000_000
    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let zed = fixtureNodeId(26)

    private func frame(
        _ id: String,
        type: FrameType = .chat,
        from sender: NodeId? = nil,
        to recipient: NodeId? = nil,
        members: [NodeId]? = nil,
        sentAt: Int64? = nil
    ) -> CarriedFrame {
        let author = sender ?? alice
        let group = members.map { GroupInfo(id: "g1", members: $0.map(\.string), createdBy: author.string) }
        let envelope = RelayEnvelope(
            type: type,
            id: id,
            senderId: author.string,
            sentAt: sentAt ?? now,
            recipientId: recipient?.string,
            group: group,
            payload: []
        )
        return CarriedFrame(envelope: envelope, sig: Array(repeating: 1, count: 64), signed: envelope.encoded)
    }

    private func ids(_ wires: [WireEnvelope]) -> [String] {
        wires.compactMap { try? RelayEnvelope(decoding: $0.signed).id }
    }

    @Test func aRelayedFrameIsCarriedOnlyWhenItAuthenticates() {
        let store = MemoryCustodyStore()
        let sync = CustodySync()
        #expect(!sync.carry(frame("m1", to: bob), in: store, now: now) { false })
        #expect(sync.carry(frame("m2", to: bob), in: store, now: now) { true })
        #expect(!store.contains("m1"))
        #expect(store.contains("m2"))
    }

    @Test func ourOwnFramesSkipAuthentication() {
        let store = MemoryCustodyStore()
        #expect(CustodySync().carryOwn(frame("m1", to: bob), in: store, now: now))
    }

    @Test func everyCustodialTypeIsCarriedAndNothingElse() {
        let store = MemoryCustodyStore()
        let sync = CustodySync()
        let carried: [FrameType] = [.chat, .receipt, .reaction, .profile, .groupUpdate, .groupLeave]
        let refused: [FrameType] = [.keyRequest, .blobRequest, .typing, .commons, FrameType(rawValue: "future")]
        for type in carried + refused {
            _ = sync.carry(frame(type.rawValue, type: type), in: store, now: now) { true }
        }
        #expect(Set(store.liveIds(now: now)) == Set(carried.map(\.rawValue)))
    }

    @Test func aFrameWithNoSentAtIsRefusedEvenAsOurOwn() {
        // Work item #16: an origination that forgot sentAt expired in 1970 on every node, the author's included.
        let store = MemoryCustodyStore()
        #expect(!CustodySync().carryOwn(frame("r0", type: .receipt, sentAt: 0), in: store, now: now))
        #expect(CustodySync().carryOwn(frame("r1", type: .receipt), in: store, now: now))
    }

    @Test func aHeldFrameIsNotAuthenticatedAgain() {
        let store = MemoryCustodyStore()
        let sync = CustodySync()
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
        let sync = CustodySync()
        for id in ["r1", "r2", "r3"] {
            _ = sync.carry(frame(id), in: store, now: now) { true }
        }
        #expect(Set(ids(sync.missing(from: ["r2"], for: zed, in: store, now: now))) == ["r1", "r3"])
        #expect(sync.missing(from: ["r1", "r2", "r3", "extra"], for: zed, in: store, now: now).isEmpty)
    }

    @Test func profilesAreServedAheadOfEverythingElse() {
        // Newest-received first put a sender's profile behind its chat, so a newcomer refused the chat for want
        // of the key (knit-next ADR 2026-09.9xuu). Profiles lead; the rest keep the store's order.
        let store = MemoryCustodyStore()
        let sync = CustodySync()
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
        _ = CustodySync().carry(original, in: store, now: now) { true }
        let served = try #require(CustodySync().missing(from: [], for: bob, in: store, now: now).first)
        #expect(served == WireEnvelope(ttl: 8, hops: 0, relay: true, sig: original.sig, signed: original.signed))
    }

    @Test func anAuthorWhoseDigestLacksItsOwnFrameIsServedIt() {
        // A node whose custody was wiped gets its own sends back this way, and the digests reconverge.
        let store = MemoryCustodyStore()
        let sync = CustodySync()
        _ = sync.carry(frame("m1", from: alice, to: bob), in: store, now: now) { true }
        #expect(sync.missing(from: ["m1"], for: alice, in: store, now: now).isEmpty)
        #expect(ids(sync.missing(from: [], for: alice, in: store, now: now)) == ["m1"])
    }

    @Test func aDigestIsAnsweredAgainEveryTime() {
        // A serve lost to a torn-down link heals at the next exchange; a duplicate that landed costs only bytes.
        let store = MemoryCustodyStore()
        let sync = CustodySync()
        _ = sync.carryOwn(frame("m1", to: bob), in: store, now: now)
        let serves = (0..<3).flatMap { _ in ids(sync.missing(from: [], for: bob, in: store, now: now)) }
        #expect(serves == ["m1", "m1", "m1"])
    }

    @Test func aGroupFrameIsServedOnlyToItsMembers() {
        let store = MemoryCustodyStore()
        let sync = CustodySync()
        _ = sync.carryOwn(frame("g1", members: [alice, bob]), in: store, now: now)
        #expect(sync.missing(from: [], for: zed, in: store, now: now).isEmpty)
        #expect(ids(sync.missing(from: [], for: bob, in: store, now: now)) == ["g1"])
    }

    @Test func aReceiptFromTheRecipientPurgesAndTombstonesTheDM() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("m1", to: bob), in: store, now: now) { true }
        sync.acknowledge("m1", from: bob.string, in: store, now: now)
        #expect(!store.contains("m1"))
        #expect(sync.isTombstoned("m1", now: now))
        #expect(!sync.carry(frame("m1", to: bob), in: store, now: now) { true }, "the tombstone blocks a re-store")
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
