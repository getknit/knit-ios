import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group facade over both store kinds (ADR 2026-10.5sk9, phase P6a1): a seal mints when the advance rules say and
/// persists before it answers, a seed adopts once per mint, an open commits with its caller's rows or not at all, the
/// outbox answers its rows, and the records go both ways. Kotlin has no `GroupRatchetSessions` test of its own; its
/// rules are `GroupRatchetSessions.kt`'s, cited case by case.
@Suite struct GroupRatchetSessionsTests {
    struct Unexpected: Error {}

    static let kinds = GroupSessionKind.allCases
    static let group = "g-0123456789abcdef01234567"
    static let now: Int64 = 1_700_000_000_000

    let alice = fixtureNodeId(1)
    let bob = fixtureNodeId(2)

    /// Alice seals and Bob opens: the first seal mints epoch 1 and hands back its seed, the next rides it, and Bob,
    /// having adopted the seed, opens the frames in any order, a re-serve as a duplicate.
    @Test(arguments: kinds)
    func aSealMintsOnceAndARecipientOpensWhatItAdopted(kind: GroupSessionKind) throws {
        let sending = try kind.make()
        let receiving = try kind.make()
        let aliceSessions = sending.sessions(alice)
        let bobSessions = receiving.sessions(bob)
        let (first, minted) = try seal(aliceSessions, "one", now: Self.now)
        let (second, again) = try seal(aliceSessions, "two", now: Self.now + 1)
        let seed = try #require(minted)
        #expect(again == nil, "the second seal rides the epoch the first minted")
        #expect(seed.epoch == 1 && seed.mintedAt == Self.now)
        #expect(first.version == EncEnvelope.Version.ratchet && first.keys.isEmpty && first.ratchet == nil)
        #expect(first.groupRatchet == GroupRatchetHeader(se: 1, n: 0) && second.groupRatchet == GroupRatchetHeader(se: 1, n: 1))
        #expect(first.nonce.count == RatchetCrypto.nonceByteCount)
        #expect(sending.store.sendChain(Self.group)?.count == 2, "each seal's advance is persisted")

        let adoption = bobSessions.adoptSeeds([seed], in: Self.group, from: alice, now: Self.now + 2)
        #expect(adoption == .settled(GroupRatchetSessions.Adoption(ackEpoch: 1, freshChains: 1, verdicts: [.adopted])))
        #expect(try open(bobSessions, second, from: alice, aad: "two", now: Self.now + 3) == .opened(plaintext: Array("two".utf8), work: 7))
        #expect(receiving.store.skippedKeys(Self.group, from: alice, epoch: 1, index: 0).count == 1, "n 0 was banked")
        #expect(try open(bobSessions, first, from: alice, aad: "one", now: Self.now + 4) == .opened(plaintext: Array("one".utf8), work: 7))
        #expect(try open(bobSessions, first, from: alice, aad: "one", now: Self.now + 5) == .refused(.duplicate))
        let held = receiving.store.holdings(of: Self.group)
        #expect(held.recvChains[alice]?.map(\.next) == [2] && held.skippedKeys.isEmpty)
    }

    @Test(arguments: kinds)
    func aFrameBeforeItsSeedIsNoKeyAndAnAlongsideThatAbandonsUndoesTheOpen(kind: GroupSessionKind) throws {
        let sending = try kind.make()
        let receiving = try kind.make()
        let bobSessions = receiving.sessions(bob)
        let (frame, minted) = try seal(sending.sessions(alice), "early", now: Self.now)
        #expect(try open(bobSessions, frame, from: alice, aad: "early", now: Self.now + 1) == .refused(.noKey))

        _ = bobSessions.adoptSeeds([try #require(minted)], in: Self.group, from: alice, now: Self.now + 2)
        let before = receiving.store.holdings(of: Self.group)
        let abandoned = bobSessions.open(
            try #require(GroupRatchetSessions.Frame(envelope: frame, aad: aad("early"))), in: Self.group, from: alice, now: Self.now + 3
        ) { _ -> Int? in nil }
        #expect(abandoned == .settled(.abandoned))
        #expect(receiving.store.holdings(of: Self.group) == before, "the chain did not move")
        #expect(
            try open(bobSessions, frame, from: alice, aad: "early", now: Self.now + 4) == .opened(plaintext: Array("early".utf8), work: 7))
    }

    /// The advance rules (`needsNewEpoch`, `GroupRatchetEngine.kt:168-178`): a chain at the cap and a chain a day old mint
    /// the next epoch, and a forced rekey's retired chain mints past its number (knit-next ADR 2026-10.xgwj).
    @Test(arguments: kinds)
    func aSealMintsAtTheCapAtADayAndPastARetiredChain(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(alice)
        made.store.commitSend(GroupSendChainRecord(epoch: 3, seed: [1], chainKey: [2], count: 200, mintedAt: Self.now), in: Self.group)
        #expect(try seal(sessions, "a", now: Self.now).minted?.epoch == 4, "the cap")
        #expect(try seal(sessions, "b", now: Self.now + GroupRatchetEngine.maxEpochAgeMilliseconds - 1).minted == nil)
        #expect(try seal(sessions, "c", now: Self.now + GroupRatchetEngine.maxEpochAgeMilliseconds).minted?.epoch == 5, "a day")
        made.store.retireSendChains(Self.group)
        #expect(try seal(sessions, "d", now: Self.now + GroupRatchetEngine.maxEpochAgeMilliseconds + 1).minted?.epoch == 6, "retired")
        #expect(made.store.holdings(of: Self.group).sendChains.map(\.epoch) == [6, 5])
    }

    /// Only a test's IV that is not 12 bytes makes the engine refuse a seal; then the unit is abandoned with the mint, and
    /// nothing is stored.
    @Test(arguments: kinds)
    func aSealTheEngineRefusesPersistsNothing(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let noIV: @Sendable () -> [UInt8] = { [] }
        let sessions = made.sessions(alice, engine: GroupRatchetEngine(iv: noIV))
        #expect(sessions.sealGroup(plaintext: [1], aad: aad("x"), in: Self.group, now: Self.now) == .settled(.unavailable))
        #expect(made.store.holdings(of: Self.group) == .empty)
    }

    /// The re-distribution payload (`currentSeeds`, `GroupRatchetSessions.kt:200-206`): the retained seeds newest first, and
    /// none at all right after a forced rekey, whose retired row has no seed to serve.
    @Test(arguments: kinds)
    func currentSeedsAreTheRetainedOnesNewestFirstAndNeverARetiredOne(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(alice)
        #expect(sessions.currentSeeds(of: Self.group) == .settled([]))
        let first = try #require(try seal(sessions, "a", now: Self.now).minted)
        made.store.commitSend(
            GroupSendChainRecord(epoch: 1, seed: first.seed, chainKey: [9], count: 200, mintedAt: first.mintedAt), in: Self.group)
        let second = try #require(try seal(sessions, "b", now: Self.now + 1).minted)
        #expect(sessions.currentSeeds(of: Self.group) == .settled([second, first]))
        made.store.retireSendChains(Self.group)
        #expect(sessions.currentSeeds(of: Self.group) == .settled([]))
    }

    /// The outbox's calls answer the row as it stands (`markKeySent`, `keySend` and `onKeyAck`, `GroupRatchetSessions.kt:150-216`):
    /// a send raises the sent epoch, an ack the acked one, and an ack with no row records nothing.
    @Test(arguments: kinds)
    func theOutboxCallsAnswerTheRowAsItStands(kind: GroupSessionKind) throws {
        let sessions = try kind.make().sessions(alice)
        #expect(sessions.keySend(to: bob, in: Self.group) == .settled(nil))
        let sent = GroupKeySendRecord(member: bob, sentEpoch: 2, sentAt: Self.now, ackedEpoch: 0, ackedAt: 0)
        #expect(sessions.markKeySent(2, to: bob, in: Self.group, now: Self.now) == .settled(sent))
        let acked = GroupKeySendRecord(member: bob, sentEpoch: 2, sentAt: Self.now, ackedEpoch: 2, ackedAt: Self.now + 1)
        #expect(sessions.onKeyAck(2, from: bob, in: Self.group, now: Self.now + 1) == .settled(acked))
        #expect(sessions.keySend(to: bob, in: Self.group) == .settled(acked))
        #expect(sessions.onKeyAck(1, from: fixtureNodeId(9), in: Self.group, now: Self.now + 2) == .settled(nil))
    }

    /// The re-serve is acknowledged again with no chain moved, and an older mint of a held epoch is stale and not
    /// acknowledged (`adoptSeeds`, `GroupRatchetSessions.kt:108-148`); the ack is the highest epoch worth one.
    @Test(arguments: kinds)
    func aReServedSeedIsAcknowledgedAgainAndAnOlderMintIsStale(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(bob)
        let newer = GroupSeed(epoch: 1, seed: fixtureBytes(32, seed: 1), mintedAt: Self.now)
        let older = GroupSeed(epoch: 1, seed: fixtureBytes(32, seed: 2), mintedAt: Self.now - 1)
        let other = GroupSeed(epoch: 2, seed: fixtureBytes(32, seed: 3), mintedAt: Self.now)
        #expect(sessions.adoptSeeds([newer], in: Self.group, from: alice, now: Self.now).freshChains == 1)
        let chain = made.store.recvChains(Self.group, from: alice, epoch: 1)
        let answer = sessions.adoptSeeds([older, newer, other], in: Self.group, from: alice, now: Self.now + 1)
        #expect(
            answer == .settled(GroupRatchetSessions.Adoption(ackEpoch: 2, freshChains: 1, verdicts: [.stale, .alreadyKnown, .adopted])))
        #expect(made.store.recvChains(Self.group, from: alice, epoch: 1) == chain, "the re-serve moved nothing")
        #expect(sessions.adoptSeeds([older], in: Self.group, from: alice, now: Self.now + 2).ackEpoch == .some(nil), "stale: no ack")
    }

    /// A wiped sender's two eras of one epoch, both held because Bob adopted the old seed first, bank keys at the indices
    /// they share. A spend takes its own era's key alone, in either store, so the old era's frame at that index still
    /// opens: old n 5, new n 5, new n 3, then old n 3 (knit-next #177, where Kotlin's store spends both keys and the old
    /// era's frame drops as `DUPLICATE` at every re-serve).
    @Test(arguments: kinds)
    func aSpendLeavesTheOtherErasKeyAtTheIndexTheyShare(kind: GroupSessionKind) throws {
        let receiving = try kind.make()
        let bobSessions = receiving.sessions(bob)
        // Alice before her wipe and after it: a store of her own each.
        let before = try kind.make().sessions(alice)
        let after = try kind.make().sessions(alice)
        let old = try (0...5).map { try seal(before, "old \($0)", now: Self.now) }
        let new = try (0...5).map { try seal(after, "new \($0)", now: Self.now + 10) }
        let seeds = try [old[0].minted, new[0].minted].map { try #require($0) }
        #expect(seeds.map(\.epoch) == [1, 1] && seeds[0].mintedAt < seeds[1].mintedAt)
        for seed in seeds {
            #expect(bobSessions.adoptSeeds([seed], in: Self.group, from: alice, now: Self.now + 20).ackEpoch == .some(1))
        }

        for (sealed, body) in [(old[5], "old 5"), (new[5], "new 5"), (new[3], "new 3"), (old[3], "old 3")] {
            let opening = try open(bobSessions, sealed.envelope, from: alice, aad: body, now: Self.now + 30)
            #expect(opening == .opened(plaintext: Array(body.utf8), work: 7), "\(body) opens")
        }
        #expect(try open(bobSessions, old[3].envelope, from: alice, aad: "old 3", now: Self.now + 31) == .refused(.duplicate))
        let keys = receiving.store.holdings(of: Self.group).skippedKeys[alice] ?? []
        #expect(keys.count == 8 && keys.allSatisfy { $0.index != 3 }, "each era keeps its keys 0, 1, 2 and 4")
    }

    /// Every field of every record goes both ways through the mapping, and through either store and back: a minted chain,
    /// and the deltas of two real opens, one that advances a chain and banks a key and one that spends it.
    @Test(arguments: kinds)
    func theRecordsGoBothWaysThroughEitherStore(kind: GroupSessionKind) throws {
        let store = try kind.make().store
        let engine = GroupRatchetEngine()
        let minted = engine.mint(groupId: Self.group, selfId: alice, previousEpoch: 6, now: -5)
        store.commitSend(GroupRatchetRecords.record(minted), in: Self.group)
        #expect(store.sendChain(Self.group).map(GroupRatchetRecords.sendChain) == minted)
        let firstSeal = try engine.seal(minted, plaintext: [1], aad: [])
        let first = try #require(firstSeal)
        let secondSeal = try engine.seal(first.chain, plaintext: [2], aad: [])
        let second = try #require(secondSeal)
        let adopted = engine.adoptSeed(
            existing: nil, groupId: Self.group, senderId: alice, epoch: 7, seed: minted.seed, mintedAt: -5, now: 11)
        guard case .adopt(let chain) = adopted else {
            Issue.record("a fresh seed adopts: \(adopted)")
            return
        }
        let context = GroupRatchetEngine.OpenContext(chains: [chain], skippedKeys: [])
        guard case .opened(let opened) = engine.open(context, header: second.header, nonce: second.nonce, ct: second.ct, aad: [], now: 12)
        else {
            Issue.record("the second frame opens, banking a key for the first")
            return
        }
        let advanced = try #require(opened.delta.recvChain)
        store.applyOpen(GroupRatchetRecords.record(opened.delta), in: Self.group, from: alice, se: 7, n: 1)
        #expect(store.recvChains(Self.group, from: alice, epoch: 7).map(GroupRatchetRecords.recvChain) == [advanced])
        #expect(
            store.skippedKeys(Self.group, from: alice, epoch: 7, index: 0).map(GroupRatchetRecords.skippedKey)
                == opened.delta.skippedInserts)
        let banked = GroupRatchetEngine.OpenContext(chains: [], skippedKeys: opened.delta.skippedInserts)
        guard case .opened(let late) = engine.open(banked, header: first.header, nonce: first.nonce, ct: first.ct, aad: [], now: 13) else {
            Issue.record("the first frame opens on its banked key")
            return
        }
        #expect(GroupRatchetRecords.record(late.delta) == GroupOpenDelta(recvChain: nil, consumedSkippedMintedAt: -5))
        store.applyOpen(GroupRatchetRecords.record(late.delta), in: Self.group, from: alice, se: 7, n: 0)
        #expect(store.skippedKeys(Self.group, from: alice, epoch: 7, index: 0).isEmpty, "the spend names the key by its mint")
        // The store's retired row is the engine's, and its count is the engine's cap.
        #expect(GroupRatchetRetention.retiredCount == GroupRatchetEngine.maxEpochMessages)
        #expect(GroupRatchetRecords.record(minted.retired()) == GroupRatchetRetention.retired(GroupRatchetRecords.record(minted)))
    }

    /// `aSkippedKeyIsSpentByItsMintAndTheSiblingEraStillOpens` (knit-next #177, `GroupRatchetRepositoryTest.kt` at
    /// `4f3cd995`), over both store kinds: a receiver holding two mints of epoch 1 banks a key per mint at index 3, and
    /// spending the new mint's leaves the old mint's. Kotlin's delete ignored `mintedAt`, so the old era's n = 3 found no
    /// key, both chains were past it, and it dropped as `DUPLICATE` on every re-serve. No A9 transcript holds two mints'
    /// keys at one index, so this pins it.
    @Test(arguments: kinds)
    func aSkippedKeyIsSpentByItsMintAndTheSiblingEraStillOpens(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let receiver = made.sessions(bob)
        let engine = GroupRatchetEngine()
        let oldMint = engine.mint(groupId: Self.group, selfId: alice, previousEpoch: 0, now: Self.now - 10)
        let newMint = engine.mint(groupId: Self.group, selfId: alice, previousEpoch: 0, now: Self.now)
        func frames(_ mint: GroupRatchetEngine.SendChain) throws -> [GroupRatchetSessions.Frame] {
            var chain = mint
            return try (0...5).map { index in
                let sealing = try engine.seal(chain, plaintext: Array("\(mint.mintedAt):\(index)".utf8), aad: aad("frame"))
                let sealed = try #require(sealing)
                chain = sealed.chain
                return GroupRatchetSessions.Frame(header: sealed.header, nonce: sealed.nonce, ct: sealed.ct, aad: aad("frame"))
            }
        }
        let old = try frames(oldMint)
        let new = try frames(newMint)
        for mint in [oldMint, newMint] {
            let seed = GroupSeed(epoch: 1, seed: mint.seed, mintedAt: mint.mintedAt)
            #expect(receiver.adoptSeeds([seed], in: Self.group, from: alice, now: Self.now).freshChains == 1)
        }
        func opens(_ frame: GroupRatchetSessions.Frame) -> Bool {
            guard case .settled(.opened) = receiver.open(frame, in: Self.group, from: alice, now: Self.now, alongside: { _ in 7 }) else {
                return false
            }
            return true
        }

        #expect(opens(old[5]) && opens(new[5]) && opens(new[3]))
        #expect(made.store.skippedKeys(Self.group, from: alice, epoch: 1, index: 3).map(\.mintedAt) == [Self.now - 10])
        #expect(opens(old[3]), "the old era's n = 3 opens on its own key")
        #expect(made.store.skippedKeys(Self.group, from: alice, epoch: 1, index: 3).isEmpty)
    }

    /// The frame a group envelope carries: a v2 envelope with a group header, and nothing else.
    @Test func aGroupEnvelopeIsAFrameAndNoOtherIs() {
        let header = GroupRatchetHeader(se: 1, n: 2)
        let grouped = EncEnvelope(version: EncEnvelope.Version.ratchet, nonce: [1], ct: [2], keys: [], groupRatchet: header)
        #expect(
            GroupRatchetSessions.Frame(envelope: grouped, aad: [3])
                == GroupRatchetSessions.Frame(header: header, nonce: [1], ct: [2], aad: [3]))
        let compact = EncEnvelope(version: EncEnvelope.Version.compactRatchet, nonce: [], ct: [2], keys: [], groupRatchet: header)
        #expect(GroupRatchetSessions.Frame(envelope: compact, aad: [3]) == nil, "the group form is v2 alone")
        #expect(GroupRatchetSessions.Frame(envelope: EncEnvelope(nonce: [1], ct: [2], keys: []), aad: [3]) == nil)
    }
}

// The helpers, apart from the suite only to keep its body inside the lint's length.
extension GroupRatchetSessionsTests {
    func aad(_ id: String) -> [UInt8] {
        MessageCrypto.header(id: id, senderId: alice.string, sentAt: 1, thread: Self.group)
    }

    /// One frame of `body`, which must seal and settle.
    func seal(_ sessions: GroupRatchetSessions, _ body: String, now: Int64) throws -> (envelope: EncEnvelope, minted: GroupSeed?) {
        let answer = sessions.sealGroup(plaintext: Array(body.utf8), aad: aad(body), in: Self.group, now: now)
        guard case .settled(.sealed(let envelope, let minted)) = answer else {
            Issue.record("expected a sealed frame, got \(answer)")
            throw Unexpected()
        }
        return (envelope, minted)
    }

    /// `envelope`'s open by `sessions`, from `sender`, its body's AAD, the work 7 when it opens.
    func open(
        _ sessions: GroupRatchetSessions,
        _ envelope: EncEnvelope,
        from sender: NodeId,
        aad id: String,
        now: Int64
    ) throws -> GroupRatchetSessions.Opening<Int> {
        let frame = try #require(GroupRatchetSessions.Frame(envelope: envelope, aad: aad(id)))
        let answer = sessions.open(frame, in: Self.group, from: sender, now: now) { _ in 7 }
        guard case .settled(let opening) = answer else {
            Issue.record("expected an open of its own, got \(answer)")
            throw Unexpected()
        }
        return opening
    }
}

extension GroupRatchetSessions.Answer {
    /// The settled result, or `nil` for a joined or failed answer.
    var settledValue: Result? {
        guard case .settled(let result) = self else {
            return nil
        }
        return result
    }
}

extension GroupRatchetSessions.Answer<GroupRatchetSessions.Adoption> {
    /// The adoption's count of fresh chains when it settled, else -1.
    var freshChains: Int {
        settledValue?.freshChains ?? -1
    }

    /// The adoption's ack when it settled: `.some(nil)` for none, `nil` for an answer that did not settle.
    var ackEpoch: Int?? {
        settledValue.map(\.ackEpoch)
    }
}
