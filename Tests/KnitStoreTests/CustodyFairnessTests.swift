import KnitCrypto
import KnitStore
import KnitWire
import Testing

/// A group's roster as a current build of either platform writes it (`ForwardRepositoryTest.roster`): the members left,
/// who departed, and the id the two derive to, which custody's group gate checks (knit-next ADR 2026-10.7mqm).
func roster(_ members: [String], departed: [String] = []) -> GroupInfo {
    GroupInfo(
        id: GroupId.derive(members + departed),
        members: members,
        createdBy: (members + departed).first ?? "",
        departed: departed.isEmpty ? nil : departed
    )
}

/// A carried chat with an empty body (`ForwardRepositoryTest.frame`): a DM to `peer` with `recipient`, a group's with
/// `group`, else a room post. Unsigned, as the store tests' frames are.
private func frame(_ id: String, sender: String, sentAt: Int64, recipient: String? = nil, group: GroupInfo? = nil) -> CarriedFrame {
    let envelope = RelayEnvelope(
        type: .chat,
        id: id,
        senderId: sender,
        sentAt: sentAt,
        recipientId: recipient,
        group: group,
        payload: ChatContent(body: "").encoded
    )
    return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
}

/// A DM to `peer`.
private func dm(_ id: String, sender: String, sentAt: Int64) -> CarriedFrame {
    frame(id, sender: sender, sentAt: sentAt, recipient: "peer")
}

/// SplitMix64, so each seeded order is the same every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The global cap's fair trim and the group gate (knit-next ADR 2026-10.7mqm), ported from the cases `e0cbb842a` added to
/// `ForwardRepositoryTest`, run against every store.
@Suite struct CustodyFairnessTests {
    private static let kinds = CustodyStoreKind.allCases
    private static let now: Int64 = 1_000_000
    private static let edge = now + WireProtocol.maxFutureSkewMilliseconds - 1

    /// Five Sybils, ten frames each, stamped just inside the future window: the newest frames of all.
    private static func flood(_ store: some CustodyStore) {
        for sybil in 1...5 {
            for index in 1...10 {
                let id = "s\(sybil)-" + (index < 10 ? "0\(index)" : "\(index)")
                store.store(dm(id, sender: "sybil\(sybil)", sentAt: edge - Int64(index)), origin: .relayed, now: now)
            }
        }
    }

    @Test(arguments: kinds)
    func aSybilFloodAtTheWindowsEdgeEvictsNoneOfTheHonestFrames(kind: CustodyStoreKind) throws {
        // The malicious-fork review's C2 at a fiftieth of the field numbers. The old global rule took the globally oldest
        // frame, so every honest frame went, on every node alike.
        let store = try kind.make(CustodyLimits(maxFrames: 50, maxPerSender: 10))
        var honest: [String] = []
        for sender in 1...4 {
            for index in 1...3 {
                let id = "h\(sender)-\(index)"
                honest.append(id)
                #expect(
                    store.store(
                        dm(id, sender: "honest\(sender)", sentAt: Self.now - 60_000 * Int64(5 - index)), origin: .relayed, now: Self.now
                    ).held)
            }
        }
        Self.flood(store)
        let held = Set(store.liveIds(now: Self.now))
        #expect(held.isSuperset(of: honest), "missing \(Set(honest).subtracting(held).sorted())")
        #expect(held.count == 50)
        let perSybil = (1...5).map { sybil in held.count { $0.hasPrefix("s\(sybil)-") } }
        #expect(perSybil.reduce(0, +) == 38, "the flood's own buckets paid for the cap: \(perSybil)")
        #expect(perSybil.allSatisfy { (7...8).contains($0) }, "evenly: \(perSybil)")
    }

    @Test(arguments: kinds)
    func anHonestFrameStoredDuringTheFloodSurvivesItsOwnWrite(kind: CustodyStoreKind) throws {
        // For five minutes after the flood an honest frame is the oldest held, and the old rule evicted it in the very write
        // that stored it, after the router had marked it seen.
        let store = try kind.make(CustodyLimits(maxFrames: 50, maxPerSender: 10))
        Self.flood(store)
        #expect(store.store(dm("honest", sender: "alice", sentAt: Self.now), origin: .relayed, now: Self.now).held)
        #expect(store.contains("honest"))
        #expect(store.liveIds(now: Self.now).count == 50)
    }

    @Test(arguments: kinds)
    func aFrameItsOwnWriteEvictedIsNotHeld(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 5))
        for index in 1...5 {
            #expect(store.store(dm("f\(index)", sender: "peer", sentAt: 10 + Int64(index)), origin: .relayed, now: 0).held)
        }
        let late = store.store(dm("late", sender: "peer", sentAt: 1), origin: .relayed, now: 0)
        #expect(late == CustodyStoreResult(held: false, changed: true), "older than the newest five: kept nowhere")
        #expect(!store.contains("late"))
        let newer = dm("new", sender: "peer", sentAt: 99)
        #expect(store.store(newer, origin: .relayed, now: 0) == CustodyStoreResult(held: true, changed: true), "displaces the oldest")
        #expect(!store.contains("f1"))
        #expect(store.store(newer, origin: .relayed, now: 0) == .alreadyHeld, "already held reads as held and unchanged")
    }

    @Test(arguments: kinds)
    func theRoomQuotaKeepsItsNewestPostsWhoeverWroteThem(kind: CustodyStoreKind) throws {
        // Only the global cap went fair: shipped builds keep a room's newest N, and a fair room trim would split an old node
        // from a new one for good at a busy room's quota.
        let store = try kind.make(CustodyLimits(maxRoomChat: 3))
        for (id, sender, sentAt) in [("a1", "alice", 1), ("a2", "alice", 2), ("a3", "alice", 3), ("b1", "bob", 4)] {
            store.store(frame(id, sender: sender, sentAt: Int64(sentAt)), origin: .relayed, now: 0)
        }
        #expect(store.liveIds(now: 0).sorted() == ["a2", "a3", "b1"])
    }

    @Test(arguments: kinds)
    func theGroupQuotaKeepsItsNewestFramesWhoeverWroteThem(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerGroup: 3))
        let group = roster(["alice", "bob", "carol"])
        for (id, sender, sentAt) in [("a1", "alice", 1), ("b1", "bob", 2), ("b2", "bob", 3), ("c1", "carol", 4)] {
            store.store(frame(id, sender: sender, sentAt: Int64(sentAt), group: group), origin: .relayed, now: 0)
        }
        #expect(store.liveIds(now: 0).sorted() == ["b1", "b2", "c1"])
    }

    @Test(arguments: kinds)
    func withOneQuotaBindingAnyTwoArrivalOrdersKeepTheSameSet(kind: CustodyStoreKind) throws {
        // The global cap alone binds, then the sender quota alone. Two nodes holding the same frames must agree on a digest
        // whatever order the frames reached them in.
        for seed in UInt64(1)...8 {
            var random = SplitMix(state: seed)
            let frames = (1...40).map { index in
                let sender = "s\(Int.random(in: 0..<6, using: &random))"
                return dm(index < 10 ? "f0\(index)" : "f\(index)", sender: sender, sentAt: Int64.random(in: 1..<30, using: &random))
            }
            for (cap, perSender) in [(15, 1000), (1000, 3)] {
                var kept: [Set<String>] = []
                for orderSeed in [seed &* 31, seed &* 37] {
                    var shuffler = SplitMix(state: orderSeed)
                    let store = try kind.make(CustodyLimits(maxFrames: cap, maxPerSender: perSender))
                    for carried in frames.shuffled(using: &shuffler) {
                        store.store(carried, origin: .relayed, now: 0)
                    }
                    kept.append(Set(store.liveIds(now: 0)))
                }
                #expect(kept[0] == kept[1], "seed \(seed), cap \(cap), per sender \(perSender)")
            }
        }
    }

    @Test(arguments: kinds)
    func custodyRefusesAGroupFrameWhoseRosterIsNotItsOwn(kind: CustodyStoreKind) throws {
        let store = try kind.make()
        let group = roster(["alice", "bob", "carol"])
        #expect(store.store(frame("ok", sender: "bob", sentAt: 1, group: group), origin: .relayed, now: 0).held)
        #expect(
            store.store(frame("stranger", sender: "mallory", sentAt: 2, group: group), origin: .relayed, now: 0) == .refused(.foreignRoster)
        )
        var smuggled = group
        smuggled.members.append("mallory")
        #expect(
            store.store(frame("smuggled", sender: "mallory", sentAt: 3, group: smuggled), origin: .relayed, now: 0)
                == .refused(.foreignRoster))
        #expect(
            store.store(frame("own", sender: "mallory", sentAt: 4, group: smuggled), origin: .own, now: 0) == .refused(.foreignRoster),
            "our own frame is held to it too")
        #expect(store.liveIds(now: 0) == ["ok"])
    }
}
