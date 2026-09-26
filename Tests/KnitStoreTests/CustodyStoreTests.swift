import KnitStore
import KnitStoreSQL
import KnitWire
import Testing

/// Every custody store implementation. Each runs the whole ``CustodyStoreTests`` suite, so the SQL store is held to
/// exactly the rules the memory store keeps.
enum CustodyStoreKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case sql

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .sql:
            "sql"
        }
    }

    func make() throws -> any CustodyStore {
        try make(CustodyLimits())
    }

    func make(_ limits: CustodyLimits) throws -> any CustodyStore {
        switch self {
        case .memory:
            MemoryCustodyStore(limits: limits)
        case .sql:
            SQLCustodyStore(try KnitDatabase.inMemory(failures: recordFailure), limits: limits)
        }
    }
}

/// Fails the test that met a database error: the stores would otherwise answer as if nothing were there.
@Sendable func recordFailure(_ error: any Error) {
    Issue.record("the database failed: \(error)")
}

/// A carried frame with knit-next's test shapes (`ForwardRepositoryTest.dm` and `chat`): a DM to `bob` unless
/// told otherwise, unsigned, with whatever payload the case needs.
private func carried(
    _ id: String,
    sender: String = "peer",
    sentAt: Int64 = 1,
    recipient: String? = "bob",
    group: String? = nil,
    type: FrameType = .chat,
    payload: [UInt8] = ChatContent().encoded
) -> CarriedFrame {
    let envelope = RelayEnvelope(
        type: type,
        id: id,
        senderId: sender,
        sentAt: sentAt,
        recipientId: recipient,
        group: group.map { GroupInfo(id: $0, members: [sender], createdBy: sender) },
        payload: payload
    )
    return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
}

/// A Nearby room post: chat with no recipient and no group.
private func roomPost(_ id: String, sender: String = "peer", sentAt: Int64 = 1) -> CarriedFrame {
    carried(id, sender: sender, sentAt: sentAt, recipient: nil, payload: ChatContent(body: "hi").encoded)
}

/// The live ids, sorted, for comparing sets.
private func liveSet(_ store: some CustodyStore, now: Int64) -> [String] {
    store.liveIds(now: now).sorted()
}

/// Custody's law, ported from knit-next's `ForwardRepositoryTest` and `ForwardDaoTest`, run against every store.
@Suite struct CustodyStoreTests {
    private static let kinds = CustodyStoreKind.allCases

    @Test(arguments: kinds)
    func aHeldIdIsNeverStoredTwice(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        #expect(store.store(carried("f1", sender: "first"), origin: .relayed, now: 0))
        #expect(store.store(carried("f1", sender: "second"), origin: .relayed, now: 0), "already held still answers true")
        #expect(store.liveFrames(now: 0).map(\.envelope.senderId) == ["first"])
    }

    @Test(arguments: kinds)
    func aPayloadThatDoesNotDecodeIsStillCarried(kind: CustodyStoreKind) throws {
        // The id set is what the digests compare, so nothing about the payload may gate the insert.
        let store = try kind.make()
        #expect(store.store(carried("d3", payload: [0xFF, 0xFF, 0xFF]), origin: .relayed, now: 0))
        #expect(store.contains("d3"))
    }

    @Test(arguments: kinds)
    func ourOwnFramesCountAgainstTheSenderQuota(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 5))
        for index in 1...8 {
            store.store(carried("f0\(index)", sender: "self", sentAt: Int64(index)), origin: .own, now: 0)
        }
        #expect(liveSet(store, now: 0) == ["f04", "f05", "f06", "f07", "f08"], "the newest five by sentAt")
    }

    @Test(arguments: kinds)
    func arrivalOrderDoesNotChangeWhatIsKept(kind: CustodyStoreKind) throws {
        let frames = (1...8).map { carried("f0\($0)", sentAt: Int64($0)) }
        let ascending = try kind.make(CustodyLimits(maxPerSender: 5))
        let descending = try kind.make(CustodyLimits(maxPerSender: 5))
        for frame in frames {
            ascending.store(frame, origin: .relayed, now: 0)
        }
        for frame in frames.reversed() {
            descending.store(frame, origin: .relayed, now: 0)
        }
        #expect(liveSet(ascending, now: 0) == liveSet(descending, now: 0))
        #expect(ascending.fingerprint(now: 0) == descending.fingerprint(now: 0))
        #expect(descending.fingerprint(now: 0) == StoreDigest.fingerprint(of: ["f04", "f05", "f06", "f07", "f08"]))
    }

    @Test(arguments: kinds)
    func removeForgetsTheFrame(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        store.store(carried("keep", sentAt: 1), origin: .relayed, now: 0)
        store.store(carried("gone", sentAt: 2), origin: .relayed, now: 0)
        store.remove("gone")
        store.remove("never-held")
        #expect(!store.contains("gone"))
        #expect(store.liveIds(now: 0) == ["keep"])
        #expect(store.fingerprint(now: 0) == StoreDigest.fingerprint(of: ["keep"]))
    }

    @Test(arguments: kinds)
    func aFrameIsServedVerbatimWhileLiveAndNotOnceExpired(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        let frame = carried("f1", sentAt: 1000)
        store.store(frame, origin: .relayed, now: 1000)
        let back = try #require(store.frame("f1", now: 1000))
        #expect(back.signed == frame.signed, "a re-encode would break the signature")
        #expect(back.reserved == WireEnvelope(sig: frame.sig, signed: frame.signed))
        let ttl = CustodyLimits().ttlMilliseconds
        #expect(store.frame("f1", now: 1000 + ttl) != nil, "expiry is inclusive")
        #expect(store.frame("f1", now: 1000 + ttl + 1) == nil)
        #expect(store.frame("unknown", now: 1000) == nil)
    }

    @Test(arguments: kinds)
    func expiryIsFrameGlobalNotFromArrival(kind: CustodyStoreKind) throws {
        let limits = CustodyLimits(ttlMilliseconds: 1000)
        let early = try kind.make(limits)
        let late = try kind.make(limits)
        early.store(carried("d1", sentAt: 500), origin: .relayed, now: 600)
        late.store(carried("d1", sentAt: 500), origin: .relayed, now: 1400)
        for store in [early, late] {
            #expect(store.liveIds(now: 1500) == ["d1"])
            #expect(store.liveIds(now: 1501).isEmpty, "a late joiner must not extend the frame's life")
        }
    }

    @Test(arguments: kinds)
    func aFramePastItsExpiryIsRefused(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(ttlMilliseconds: 1000))
        #expect(!store.store(carried("dead", sentAt: 500), origin: .relayed, now: 2000))
        #expect(!store.contains("dead"))
        #expect(store.fingerprint(now: 2000) == 0)
        #expect(store.store(carried("live", sentAt: 1900), origin: .relayed, now: 2000))
    }

    @Test(arguments: kinds)
    func aFrameWithNoSentAtIsRefused(kind: CustodyStoreKind) throws {
        // A custodial frame whose sender forgot `sentAt` expired in 1970, so nobody carries it (work item #16).
        let store = try kind.make()
        #expect(!store.store(carried("r1", sentAt: 0, type: .receipt), origin: .own, now: 1_756_200_000_000))
    }

    @Test(arguments: kinds)
    func aFutureDatedFrameIsRefusedAndEvictsNothing(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 5))
        for index in 1...5 {
            store.store(carried("h\(index)", sentAt: 1000 + Int64(index)), origin: .relayed, now: 1000)
        }
        let window = WireProtocol.maxFutureSkewMilliseconds
        #expect(!store.store(carried("evil", sentAt: 1000 + window + 60_000), origin: .relayed, now: 1000))
        #expect(!store.store(carried("edge", sentAt: 1000 + window + 1), origin: .relayed, now: 1000))
        #expect(liveSet(store, now: 1000) == ["h1", "h2", "h3", "h4", "h5"])
        #expect(store.store(carried("skewed", sender: "other", sentAt: 1000 + window), origin: .relayed, now: 1000))
    }

    @Test(arguments: kinds)
    func sweepingIsHousekeepingOnly(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(ttlMilliseconds: 1000))
        store.store(carried("dies", sentAt: 0), origin: .relayed, now: 0)
        store.store(carried("lives", sentAt: 5000), origin: .relayed, now: 0)
        let atBoundary = store.fingerprint(now: 2000)
        #expect(atBoundary == StoreDigest.fingerprint(of: ["lives"]))
        #expect(store.contains("dies"), "expired, not swept yet")
        #expect(store.sweepExpired(now: 2000) == 1)
        #expect(store.fingerprint(now: 2000) == atBoundary, "the sweep must not move the digest")
        #expect(!store.contains("dies"))
    }

    @Test(arguments: kinds)
    func theSweepKeepsAFrameOnItsLastLiveMillisecond(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(ttlMilliseconds: 1000))
        store.store(carried("gone", sentAt: 0), origin: .relayed, now: 0)
        store.store(carried("keep", sentAt: 1), origin: .relayed, now: 0)
        #expect(store.sweepExpired(now: 1001) == 1)
        #expect(store.liveIds(now: 1001) == ["keep"])
    }

    @Test(arguments: kinds)
    func unsweptResidueDoesNotChangeWhichLiveFramesAreEvicted(kind: CustodyStoreKind) throws {
        // An expired room post is newer by sentAt than two live DMs. One node swept it and one has not; when a
        // fourth frame arrives at both, counting the residue would evict a live DM on the unswept node only.
        let limits = CustodyLimits(ttlMilliseconds: 10_000, roomChatTTLMilliseconds: 1000, maxPerSender: 3)
        let swept = try kind.make(limits)
        let unswept = try kind.make(limits)
        let frames = [
            carried("dm_old", sender: "S", sentAt: 100),
            carried("dm_mid", sender: "S", sentAt: 200),
            roomPost("bc_new", sender: "S", sentAt: 5000),
        ]
        for frame in frames {
            swept.store(frame, origin: .relayed, now: 5500)
            unswept.store(frame, origin: .relayed, now: 5500)
        }
        swept.sweepExpired(now: 7000)
        let fresh = carried("dm_new", sender: "S", sentAt: 6000)
        swept.store(fresh, origin: .relayed, now: 7000)
        unswept.store(fresh, origin: .relayed, now: 7000)
        #expect(liveSet(swept, now: 7000) == liveSet(unswept, now: 7000))
        #expect(liveSet(unswept, now: 7000) == ["dm_mid", "dm_new", "dm_old"])
        #expect(unswept.contains("bc_new"), "the residue is the sweep's to reclaim, not the quota's")
    }

    @Test(arguments: kinds)
    func theSenderBucketEvictsTheOldestThenTheSmallestId(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 2))
        store.store(carried("a0", sender: "A", sentAt: 1), origin: .relayed, now: 0)
        store.store(carried("a1", sender: "A", sentAt: 5), origin: .relayed, now: 0)
        store.store(carried("b0", sender: "B", sentAt: 1), origin: .relayed, now: 0)
        store.store(carried("a2", sender: "A", sentAt: 5), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["a1", "a2", "b0"], "the oldest sentAt goes first")
        store.store(carried("a3", sender: "A", sentAt: 5), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["a2", "a3", "b0"], "a tie on sentAt breaks on the id")
    }

    @Test(arguments: kinds)
    func groupAndRoomBucketsTrimOnlyThemselves(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerGroup: 1, maxRoomChat: 1))
        store.store(carried("g_old", sender: "a", sentAt: 1, recipient: nil, group: "g1"), origin: .relayed, now: 0)
        store.store(carried("g_other", sender: "b", sentAt: 1, recipient: nil, group: "g2"), origin: .relayed, now: 0)
        store.store(carried("g_new", sender: "c", sentAt: 9, recipient: nil, group: "g1"), origin: .relayed, now: 0)
        store.store(roomPost("bc_old", sender: "d", sentAt: 1), origin: .relayed, now: 0)
        store.store(roomPost("bc_new", sender: "e", sentAt: 9), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["bc_new", "g_new", "g_other"])
    }

    @Test(arguments: kinds)
    func theGlobalCapEvictsTheOldestAcrossSenders(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 2))
        store.store(carried("x2", sender: "A", sentAt: 2), origin: .relayed, now: 0)
        store.store(carried("x1", sender: "B", sentAt: 1), origin: .relayed, now: 0)
        store.store(carried("x3", sender: "A", sentAt: 3), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["x2", "x3"])
        store.store(carried("x0", sender: "C", sentAt: 0), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["x2", "x3"], "a frame older than the newest two is evicted on arrival")
    }

    @Test(arguments: kinds)
    func onlyRoomPostsCountTowardTheRoomQuota(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxRoomChat: 1))
        store.store(roomPost("bc", sender: "a", sentAt: 1), origin: .relayed, now: 0)
        store.store(carried("dm", sender: "b", sentAt: 2), origin: .relayed, now: 0)
        store.store(carried("gp", sender: "c", sentAt: 3, recipient: nil, group: "g1"), origin: .relayed, now: 0)
        store.store(carried("rx", sender: "d", sentAt: 4, recipient: nil, type: .receipt), origin: .relayed, now: 0)
        store.store(carried("pf", sender: "e", sentAt: 5, recipient: nil, type: .profile), origin: .relayed, now: 0)
        #expect(store.liveIds(now: 0).count == 5)
        store.store(roomPost("bc2", sender: "f", sentAt: 6), origin: .relayed, now: 0)
        #expect(liveSet(store, now: 0) == ["bc2", "dm", "gp", "pf", "rx"])
    }

    @Test(arguments: kinds)
    func roomMetadataKeepsTheFullTTL(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        let sixHours = CustodyLimits().roomChatTTLMilliseconds
        store.store(roomPost("post", sentAt: 0), origin: .relayed, now: 0)
        store.store(carried("tick", sentAt: 0, recipient: nil, type: .receipt), origin: .relayed, now: 0)
        store.store(carried("me", sentAt: 0, recipient: nil, type: .profile), origin: .relayed, now: 0)
        #expect(liveSet(store, now: sixHours) == ["me", "post", "tick"])
        #expect(liveSet(store, now: sixHours + 1) == ["me", "tick"])
    }

    @Test(arguments: kinds)
    func liveFramesComeMostRecentlyReceivedFirst(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(ttlMilliseconds: 1000))
        store.store(carried("dead", sentAt: 0), origin: .relayed, now: 1)
        store.store(carried("edge", sentAt: 1), origin: .relayed, now: 2)
        store.store(carried("tie", sentAt: 900), origin: .relayed, now: 7)
        store.store(carried("live", sentAt: 900), origin: .relayed, now: 7)
        #expect(store.liveFrames(now: 1001).map(\.envelope.id) == ["live", "tie", "edge"])
        #expect(Set(store.liveIds(now: 1001)) == ["edge", "tie", "live"])
    }

    @Test(arguments: kinds)
    func recipientAndContainsAddressRowsById(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        store.store(carried("dm", recipient: "bob"), origin: .relayed, now: 0)
        store.store(roomPost("bc"), origin: .relayed, now: 0)
        #expect(store.recipient(of: "dm") == "bob")
        #expect(store.recipient(of: "bc") == nil)
        #expect(store.recipient(of: "missing") == nil)
        store.remove("dm")
        #expect(!store.contains("dm"))
        #expect(store.contains("bc"))
    }

    @Test(arguments: kinds)
    func idsThatSwiftCallsEqualAreTwoFrames(kind: CustodyStoreKind) throws {
        // Kotlin compares code units, so the Kelvin sign is not a "K" and these are two frames on Android.
        let store = try kind.make()
        store.store(carried("idK"), origin: .relayed, now: 0)
        store.store(carried("id\u{212A}"), origin: .relayed, now: 0)
        #expect(store.liveIds(now: 0).count == 2)
        store.remove("id\u{212A}")
        #expect(store.contains("idK"))
        #expect(!store.contains("id\u{212A}"))
    }

    @Test(arguments: kinds)
    func concurrentStoresAndSweepsLeaveAConsistentSet(kind: CustodyStoreKind) async throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 5))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<300 {
                    store.store(carried("f\(index)", sentAt: Int64(index + 1)), origin: .relayed, now: 0)
                }
            }
            group.addTask {
                for _ in 0..<300 {
                    store.sweepExpired(now: 0)
                }
            }
        }
        #expect(liveSet(store, now: 0) == ["f295", "f296", "f297", "f298", "f299"])
    }
}

/// Ids key rows by their exact bytes in every store (ADR 2026-09.jc2x): a C string, or Swift's `String` equality,
/// would make two of Android's frames one.
@Suite struct CustodyStoreByteKeyTests {
    @Test(arguments: CustodyStoreKind.allCases)
    func anIdWithANulIsNotItsOwnPrefix(kind: CustodyStoreKind) throws {
        // A C string ends at the NUL, which would make these one row; on Android they are two frames.
        let store = try kind.make()
        store.store(carried("a"), origin: .relayed, now: 0)
        store.store(carried("a\u{0}b"), origin: .relayed, now: 0)
        #expect(Set(store.liveIds(now: 0).map { Array($0.utf8) }) == [Array("a".utf8), [0x61, 0, 0x62]])
        #expect(store.frame("a\u{0}b", now: 0)?.envelope.id.utf8.count == 3)
        store.remove("a")
        #expect(store.contains("a\u{0}b"))
        #expect(!store.contains("a"))
    }
}

/// What only the memory store says about itself.
@Suite struct MemoryCustodyStoreTests {
    @Test func itRemembersWhereEachFrameCameFrom() {
        let store = MemoryCustodyStore()
        store.store(carried("mine"), origin: .own, now: 0)
        store.store(carried("theirs"), origin: .relayed, now: 0)
        #expect(store.origin(of: "mine") == .own)
        #expect(store.origin(of: "theirs") == .relayed)
        #expect(store.origin(of: "neither") == nil)
    }

    @Test func allIdsIncludesExpiredResidue() {
        let store = MemoryCustodyStore(limits: CustodyLimits(ttlMilliseconds: 10))
        store.store(carried("old", sentAt: 0), origin: .relayed, now: 0)
        store.store(carried("new", sentAt: 100), origin: .relayed, now: 100)
        #expect(store.allIds() == ["new", "old"])
        #expect(store.liveIds(now: 100) == ["new"])
    }
}
