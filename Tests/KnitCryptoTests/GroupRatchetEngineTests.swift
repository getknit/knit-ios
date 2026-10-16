import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// The group form's engine, knit-next's `GroupRatchetEngineTest` case by case (at `cbf2a487`, 15 cases): real seals,
/// seed adoptions and opens among N members (``GroupRatchetMember``, the Kotlin `Member`) through the mesh's delivery
/// pathology, loss, reordering, duplication, a forced rekey and a wiped sender's re-mint. Then what this port adds: the
/// engine reads only the header's rows, a spend names its key's mint so a wiped sender's two eras keep their own keys,
/// a nonce of the wrong length fails the AEAD, and an IV source that is not 12 bytes throws out of the seal.
@Suite struct GroupRatchetEngineTests {
    struct Unopened: Error {}

    private let engine = GroupRatchetEngine()

    @Test func sealAndOpenRoundTripAcrossThreeParties() throws {
        let (alice, bob, carol) = (GroupRatchetMember(1), GroupRatchetMember(2), GroupRatchetMember(3))
        let seed = alice.mint(now: 1)
        bob.adopt(from: alice, seed, now: 2)
        carol.adopt(from: alice, seed, now: 2)

        let frames = try (0...2).map { try alice.seal("m\($0)", "hello \($0)", now: 3) }

        for (index, frame) in frames.enumerated() {
            #expect(try bob.openedText(frame, now: 4) == "hello \(index)")
            #expect(try carol.openedText(frame, now: 4) == "hello \(index)")
        }
    }

    @Test func outOfOrderFramesGapFillAndSkippedKeysConsumeOnce() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frames = try (0...3).map { try alice.seal("m\($0)", "msg \($0)", now: 2) }

        // Newest first: indices 0 to 2 are banked as skipped keys.
        #expect(try bob.openedText(frames[3], now: 3) == "msg 3")
        // A banked index opens from its stored key, exactly once: the re-served copy is a benign duplicate.
        #expect(try bob.openedText(frames[1], now: 4) == "msg 1")
        #expect(bob.open(frames[1], now: 5).failure == .duplicate)
        #expect(try bob.openedText(frames[0], now: 6) == "msg 0")
        #expect(try bob.openedText(frames[2], now: 7) == "msg 2")
    }

    @Test func aReDeliveredInOrderFrameIsDuplicate() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frame = try alice.seal("m0", "hi", now: 2)

        #expect(try bob.openedText(frame, now: 3) == "hi")
        #expect(bob.open(frame, now: 4).failure == .duplicate)
    }

    @Test func aFrameBeforeItsSeedIsNoKey() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        alice.mint(now: 1)
        let frame = try alice.seal("m0", "early", now: 2)

        #expect(bob.open(frame, now: 3).failure == .noKey)
    }

    @Test func aWhollyLostEpochNeverWedgesLaterEpochs() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        let epoch1 = alice.mint(now: 1)
        _ = try alice.seal("lost0", "never arrives", now: 2)
        _ = try alice.seal("lost1", "never arrives", now: 2)
        let epoch2 = alice.mint(now: 3)
        // Bob never got epoch 1's seed nor its frames; only epoch 2 reaches him.
        bob.adopt(from: alice, epoch2, now: 4)

        let frame = try alice.seal("m0", "fresh epoch", now: 5)

        #expect(epoch2.epoch == 2)
        #expect(epoch1.seed != epoch2.seed)
        #expect(try bob.openedText(frame, now: 6) == "fresh epoch")
    }

    @Test func adoptionIsIdempotentAndNeverRewindsTheChain() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        let seed = alice.mint(now: 1)
        #expect(bob.adopt(from: alice, seed, now: 2).isAdopt)
        let frame0 = try alice.seal("m0", "one", now: 3)
        #expect(try bob.openedText(frame0, now: 4) == "one")

        // A custody re-serve of the same distribution: recognized, the chain's position untouched.
        #expect(bob.adopt(from: alice, seed, now: 5) == .alreadyKnown)
        #expect(bob.open(frame0, now: 6).failure == .duplicate)
    }

    @Test func anOlderMintOfAHeldEpochIsStale() {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        let old = alice.mint(now: 10)
        alice.wipe()
        let remint = alice.mint(now: 20)
        bob.adopt(from: alice, remint, now: 21)

        #expect(bob.adopt(from: alice, old, now: 22) == .stale)
    }

    @Test func aWipedSendersReMintDrainsTheOldEraInsteadOfBreakingIt() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let preWipe = try (0...1).map { try alice.seal("old\($0)", "old \($0)", now: 2) }
        #expect(try bob.openedText(preWipe[0], now: 3) == "old 0")

        alice.wipe()
        bob.adopt(from: alice, alice.mint(now: 10), now: 11) // epoch 1 again, a newer mintedAt
        let postWipe = try alice.seal("new0", "new 0", now: 12)

        // The new era opens on the newer chain; the old era's frame in flight still opens on the draining row.
        #expect(try bob.openedText(postWipe, now: 13) == "new 0")
        #expect(try bob.openedText(preWipe[1], now: 14) == "old 1")
    }

    @Test func advanceRulesFireAtCountAndAge() {
        var chain = GroupRatchetMember(1).mint(now: 0)

        #expect(!GroupRatchetEngine.needsNewEpoch(chain, now: 1))
        #expect(GroupRatchetEngine.needsNewEpoch(nil, now: 1))
        #expect(GroupRatchetEngine.needsNewEpoch(chain, now: GroupRatchetEngine.maxEpochAgeMilliseconds))
        chain.count = GroupRatchetEngine.maxEpochMessages
        #expect(GroupRatchetEngine.needsNewEpoch(chain, now: 1))
    }

    /// #167 (knit-next ADR 2026-10.xgwj): a forced rekey keeps the epoch's number and drops its keys, so the next mint is a
    /// new number and its seed adopts beside the earlier one in either order. When the rekey deleted the chain, the
    /// re-mint reused epoch 1 under a newer stamp, the earlier seed arriving second was stale, and the frame sealed under
    /// it failed the AEAD for good.
    @Test func aRetiredChainMintsPastItSoBothSeedsAdoptInEitherOrder() throws {
        let (carol, bob) = (GroupRatchetMember(3), GroupRatchetMember(2))
        let before = try carol.seal("m0", "before the leave", now: 1)
        let seedA = try #require(carol.send)

        carol.retire()
        let retired = try #require(carol.send)
        #expect(retired.isRetired)
        #expect(retired.epoch == seedA.epoch)
        #expect(retired.mintedAt == seedA.mintedAt)
        #expect(retired.seed.count + retired.chainKey.count == 0)
        #expect(GroupRatchetEngine.needsNewEpoch(retired, now: 2))
        #expect(
            try engine.seal(retired, plaintext: Array("x".utf8), aad: GroupRatchetMember.aad("mx")) == nil, "a retired chain never seals")

        let after = try carol.seal("m1", "after the leave", now: 2)
        let seedB = try #require(carol.send)
        #expect(seedB.epoch == seedA.epoch + 1)

        // The re-mint's seed reaches Bob first; the earlier one is still a fresh epoch to him.
        #expect(bob.adopt(sender: carol.nodeId, epoch: seedB.epoch, seed: seedB.seed, mintedAt: seedB.mintedAt, now: 3).isAdopt)
        #expect(bob.adopt(sender: carol.nodeId, epoch: seedA.epoch, seed: seedA.seed, mintedAt: seedA.mintedAt, now: 4).isAdopt)
        #expect(try bob.openedText(before, now: 5) == "before the leave")
        #expect(try bob.openedText(after, now: 6) == "after the leave")
    }

    @Test func anExhaustedLiveChainIsNotRetired() {
        // Rule 2 keeps the seed: the frames sealed under it may still need it re-served.
        var chain = GroupRatchetMember(1).mint(now: 0)
        chain.count = GroupRatchetEngine.maxEpochMessages
        #expect(!chain.isRetired)
        #expect(chain.retired().retired().isRetired)
    }

    @Test func sealRefusesAnExhaustedChain() throws {
        var chain = GroupRatchetMember(1).mint(now: 0)
        chain.count = GroupRatchetEngine.maxEpochMessages

        #expect(try engine.seal(chain, plaintext: Array("over".utf8), aad: GroupRatchetMember.aad("m0")) == nil)
    }

    @Test func malformedHeadersAreRefused() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frame = try alice.seal("m0", "hi", now: 2)

        func tamper(se: Int, n: Int) -> GroupRatchetEngine.OpenOutcome.Failed? {
            let header = GroupRatchetHeader(se: se, n: n)
            return bob.open(
                GroupRatchetMember.Frame(id: frame.id, sender: frame.sender, header: header, nonce: frame.nonce, ct: frame.ct), now: 3
            )
            .failure
        }

        #expect(tamper(se: 0, n: 0) == .badHeader)
        #expect(tamper(se: 1, n: -1) == .badHeader)
        #expect(tamper(se: 1, n: GroupRatchetEngine.maxEpochMessages) == .badHeader)
        #expect(tamper(se: GroupRatchetEngine.maxEpochNumber + 1, n: 0) == .badHeader)
    }

    @Test func aTamperedIndexFailsTheAeadNotTheLadder() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frame = try alice.seal("m0", "hi", now: 2)

        // Claiming a later index derives another message key: the AEAD refuses, and nothing advances.
        let header = GroupRatchetHeader(se: 1, n: 5)
        let tampered = GroupRatchetMember.Frame(id: frame.id, sender: frame.sender, header: header, nonce: frame.nonce, ct: frame.ct)
        #expect(bob.open(tampered, now: 3).failure == .aeadFail)
        // The genuine frame still opens.
        #expect(try bob.openedText(frame, now: 4) == "hi")
    }

    @Test func crossSenderChainsAreIndependent() throws {
        let (alice, bob, carol) = (GroupRatchetMember(1), GroupRatchetMember(2), GroupRatchetMember(3))
        alice.adopt(from: bob, bob.mint(now: 1), now: 1)
        alice.adopt(from: carol, carol.mint(now: 1), now: 1)

        let fromBob = try bob.seal("b0", "from bob", now: 2)
        let fromCarol = try carol.seal("c0", "from carol", now: 2)

        #expect(try alice.openedText(fromBob, now: 3) == "from bob")
        #expect(try alice.openedText(fromCarol, now: 3) == "from carol")
        #expect(fromBob.header == fromCarol.header)
    }
}

// What this port adds, apart from the suite's body only to keep it inside the lint's length.
extension GroupRatchetEngineTests {
    /// Kotlin trusts its caller to pass only the header's chains and keys; this engine reads only those. The group AAD
    /// does not bind the header, so a frame relabelled to another epoch would open on a key of the epoch it was sealed
    /// under, and bank or spend keys under the epoch it names. Handed every row Bob holds, the relabelled frame fails its
    /// AEAD on the epoch it names, and a frame with only another index's key held has no key at all.
    @Test func theEngineReadsOnlyTheHeadersChainsAndKeys() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frames = try (0...2).map { try alice.seal("m\($0)", "msg \($0)", now: 2) }
        #expect(try bob.openedText(frames[2], now: 3) == "msg 2")
        bob.adopt(from: alice, alice.mint(now: 4), now: 5)
        let everything = GroupRatchetEngine.OpenContext(chains: Array(bob.recv.values), skippedKeys: Array(bob.skipped.values.joined()))
        let aad = GroupRatchetMember.aad("m1")

        let relabelled = engine.open(
            everything, header: GroupRatchetHeader(se: 2, n: 1), nonce: frames[1].nonce, ct: frames[1].ct, aad: aad, now: 6)
        #expect(relabelled.failure == .aeadFail, "epoch 1's key at index 1 never opens a frame that names epoch 2")
        let genuine = engine.open(everything, header: frames[1].header, nonce: frames[1].nonce, ct: frames[1].ct, aad: aad, now: 7)
        guard case .opened(let banked) = genuine else {
            Issue.record("frame 1 opens on its own stored key: \(genuine)")
            return
        }
        #expect(banked.delta.consumedSkippedMintedAt == 1 && banked.delta.recvChain == nil, "the key spent is named by its mint")

        let onlyZero = GroupRatchetEngine.OpenContext(chains: [], skippedKeys: bob.skipped.values.joined().filter { $0.index == 0 })
        let missing = engine.open(onlyZero, header: frames[1].header, nonce: frames[1].nonce, ct: frames[1].ct, aad: aad, now: 8)
        #expect(missing.failure == .noKey, "another index's key is no key for this one")
    }

    /// A carried nonce that is not 12 bytes fails the AEAD and never trips the header's bounds: `AEAD_FAIL` may feed the
    /// key-request heuristic, which costs at most a request an hour. Kotlin's JVM GCM fails these too, a 12-byte frame's
    /// nonce cut or lengthened, though it would open a frame sealed under such an IV, which no Kotlin sender makes.
    @Test func aNonceOfTheWrongLengthFailsTheAead() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let frame = try alice.seal("m0", "hi", now: 2)

        for nonce in [[], Array(frame.nonce.prefix(11)), frame.nonce + [0]] {
            let wrong = GroupRatchetMember.Frame(id: frame.id, sender: frame.sender, header: frame.header, nonce: nonce, ct: frame.ct)
            #expect(bob.open(wrong, now: 3).failure == .aeadFail)
        }
        #expect(try bob.openedText(frame, now: 4) == "hi")
    }

    /// An IV source that is not 12 bytes, which only a test passes, throws out of the seal: this port's 12-byte guard
    /// refuses it, where the JVM's GCM seals under any IV that is not empty and a JVM receiver opens the frame with the
    /// IV it carries. Nothing comes back to persist.
    @Test func anIVSourceOfTheWrongLengthThrowsOutOfTheSeal() {
        let threeBytes: @Sendable () -> [UInt8] = { [1, 2, 3] }
        let short = GroupRatchetEngine(iv: threeBytes)
        let chain = short.mint(groupId: GroupRatchetMember.group, selfId: fixtureNodeId(1), previousEpoch: 0, now: 1)
        #expect(throws: RatchetCryptoError.sealing) {
            try short.seal(chain, plaintext: Array("hi".utf8), aad: GroupRatchetMember.aad("m0"))
        }
    }

    /// The mint draws its seed from the engine's source, numbers one past the previous epoch, and derives the chain the
    /// receiver's adoption derives from the same seed, bound to the sender.
    @Test func aMintDrawsItsSeedAndDerivesTheChainItsReceiversDerive() {
        let seed = fixtureBytes(32, seed: 9)
        let fixed = GroupRatchetEngine { seed }
        let alice = fixtureNodeId(1)
        let chain = fixed.mint(groupId: GroupRatchetMember.group, selfId: alice, previousEpoch: 4, now: 77)
        #expect(
            chain
                == GroupRatchetEngine.SendChain(
                    epoch: 5,
                    seed: seed,
                    chainKey: GroupRatchetCrypto.deriveEpoch(
                        seed: seed, groupId: GroupRatchetMember.group, senderId: alice.string, epoch: 5
                    ).chainKey,
                    count: 0,
                    mintedAt: 77
                ))
        let adopted = engine.adoptSeed(
            existing: nil, groupId: GroupRatchetMember.group, senderId: alice, epoch: 5, seed: seed, mintedAt: 77, now: 80)
        #expect(adopted == .adopt(GroupRatchetEngine.RecvChain(epoch: 5, mintedAt: 77, chainKey: chain.chainKey, next: 0, lastUsedAt: 80)))
        let elsewhere = engine.adoptSeed(
            existing: nil, groupId: GroupRatchetMember.group, senderId: fixtureNodeId(2), epoch: 5, seed: seed, mintedAt: 77, now: 80)
        #expect(elsewhere != adopted, "the seed binds its sender")
    }

    /// A wiped sender's two eras of one epoch, both held because Bob adopted the old seed first, bank keys at the indices
    /// they share. A spend names the mint of the key it spent, so the other era's key at that index stays and its frame
    /// opens (knit-next #177: Kotlin's delta names the index alone, its store spends both keys, and the old era's frame
    /// then drops as `DUPLICATE` at every re-serve).
    @Test func bothErasOfAWipedSenderKeepTheirOwnKeysAtAnIndexTheyShare() throws {
        let (alice, bob) = (GroupRatchetMember(1), GroupRatchetMember(2))
        bob.adopt(from: alice, alice.mint(now: 1), now: 1)
        let old = try (0...5).map { try alice.seal("old\($0)", "old \($0)", now: 2) }
        alice.wipe()
        bob.adopt(from: alice, alice.mint(now: 10), now: 11)
        let new = try (0...5).map { try alice.seal("new\($0)", "new \($0)", now: 12) }

        #expect(try bob.openedText(old[5], now: 13) == "old 5")
        #expect(try bob.openedText(new[5], now: 14) == "new 5")
        guard case .opened(let spent) = bob.open(new[3], now: 15) else {
            Issue.record("the new era's frame 3 opens on its stored key")
            return
        }
        #expect(spent.delta.consumedSkippedMintedAt == 10, "the spend names the new era's key")
        #expect(try bob.openedText(old[3], now: 16) == "old 3", "the old era's key at 3 outlived the new era's spend")
        #expect(bob.open(old[3], now: 17).failure == .duplicate)
    }
}

extension GroupRatchetEngine.OpenOutcome {
    /// The typed failure, or `nil` for a frame that opened.
    var failure: Failed? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }
}

extension GroupRatchetEngine.AdoptOutcome {
    /// Whether the seed adopted.
    var isAdopt: Bool {
        guard case .adopt = self else {
            return false
        }
        return true
    }
}
