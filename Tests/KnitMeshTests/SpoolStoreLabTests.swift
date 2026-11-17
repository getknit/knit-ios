import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The spool plane against its stores (ADR 2026-11.adrq, P4a), over ``SpoolLab``: a store that fails takes nothing and
/// strands nothing, the gate reads its inputs in units of their own, and a restart or a reinstall re-pulls once.
@Suite struct SpoolStoreLabTests {
    @Test func aFailingCustodyTakesNothingAndTheNextRoundCarriesTheFrame() throws {
        let failable = FailableStores()
        let fixtures = [
            try EngineFixture.ratcheting(SpoolEngineLabTests.alice, seed: 11),
            try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12),
        ]
        let lab = SpoolLab(fixtures)
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        try SpoolEngineLabTests.send(lab, 1, 0, "hi")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        SpoolEngineLabTests.online(lab, [0, 1])
        for failing in [\FailingCustody.failsReads, \FailingCustody.failsWrites] {
            failable.custody[keyPath: failing] = true
            let id = try SpoolEngineLabTests.send(lab, 0, 1, "while bob's store fails")
            lab.run(6)
            #expect(lab[1].stores.messages.message(id) == nil, "not taken")
            #expect(lab.heal(1)?.counts.quarantined == 0, "nothing quarantined")
            failable.custody[keyPath: failing] = false
            lab.advance(ScopeHeal.tickMilliseconds)
            lab.run(6)
            #expect(lab[1].stores.messages.message(id) != nil, "the next round carries it")
            #expect(failable.custody.held.frame(id, now: lab[1].clock.wallMilliseconds()) != nil, "into custody")
        }
    }

    @Test func theGateKeepsAnUnacceptedPeerOutAndABlockDropsTheScopeInItsTurn() throws {
        let failable = FailableStores()
        let fixtures = [
            try EngineFixture.ratcheting(SpoolEngineLabTests.alice, seed: 11),
            try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12),
        ]
        let lab = SpoolLab(fixtures)
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        SpoolEngineLabTests.online(lab, [0, 1])
        let scope = try #require(lab.scopes(0).first, "alice wrote, so alice carries the scope")
        #expect(lab.scopes(1).isEmpty && lab.operations(1, on: scope.id) == 0, "bob never accepted alice: no subscription")

        lab[1].engine.accept(SpoolEngineLabTests.alice.nodeId.string)
        lab.markTableDirty(1)
        lab.run(2)
        #expect(lab.scopes(1).map(\.id) == [scope.id], "accepted, bob carries it")

        lab.forgetSent(1)
        lab[1].engine.block(SpoolEngineLabTests.alice.nodeId)
        lab.markTableDirty(1)
        #expect(lab.scopes(1).isEmpty, "the block's commit dropped the scope in its turn")
        #expect(lab.operations(1, on: scope.id) == 0 && lab.mined[1].isEmpty, "no sub, pull or stamp for it")

        // A fresh plane whose block read fails keeps the blocked peer's scope out, and so does the recovery.
        failable.blocks.failsReads = true
        lab.replace(1, with: try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12))
        lab.connect(1)
        lab.run(2)
        #expect(lab.scopes(1).isEmpty && lab.operations(1, on: scope.id) == 0, "a failed block read keeps the scope out")
        failable.blocks.failsReads = false
        lab.run(2)
        #expect(lab.scopes(1).isEmpty, "still blocked")
    }

    @Test func aColdLaunchRePullsHeldDMsOnceAndMintsNoReceipt() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0, 1])
        let ids = try (0..<3).map { try SpoolEngineLabTests.send(lab, 0, 1, "kept \($0)") }
        lab.run(12)
        // Custody lets the DMs go while their rows stay, then a fresh process starts over the same stores.
        func dropDMs() {
            for id in ids {
                lab[1].stores.custody.remove(id)
            }
        }
        func bobsReceipts() -> Int {
            lab[1].stores.custody.liveFrames(now: lab[1].clock.wallMilliseconds()).count { frame in
                frame.envelope.senderId == SpoolEngineLabTests.bob.nodeId.string && frame.envelope.type == .chat
            }
        }
        dropDMs()
        let beforeRestart = bobsReceipts()
        let stores = lab[1].stores
        lab.replace(
            1, with: try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: stores, wall: lab[1].clock.wallMilliseconds(), seed: 14))
        lab.connect(1)
        lab.forgetSent(1)
        lab.run(6)
        let pulled = lab.sent[1].flatMap { record -> [[UInt8]] in
            if case .pull(let pull) = record { pull.blobIds } else { [] }
        }
        #expect(pulled.count == Set(pulled).count && pulled.count >= ids.count, "each re-pulled once")
        lab.forgetSent(1)
        lab.advance(ScopeHeal.tickMilliseconds)
        #expect(!lab.sent[1].contains { if case .pull = $0 { true } else { false } }, "the next round pulls nothing")
        let afterFirst = bobsReceipts()
        #expect(afterFirst == beforeRestart, "the cold launch's re-pull mints no receipt")
        // Past the router's memory, another relay serves the same blobs in the same process: each held DM is re-pulled once
        // more.
        lab.advance(SeenSet.defaultWindowMilliseconds + 1)
        dropDMs()
        let scope = try #require(lab.scopes(1).first)
        let wall = lab[1].clock.wallMilliseconds()
        var again = 0
        for blob in lab.spool.scopes[scope.id]?.live ?? [] {
            let arrival = SpoolArrival(scope: scope.id, blobId: blob.id, data: blob.data)
            guard
                let candidate = ScopeCandidate(opening: arrival, in: scope, me: SpoolEngineLabTests.bob.nodeId, source: .pulled, now: wall),
                ids.contains(candidate.frameId)
            else {
                continue
            }
            again += 1
            #expect(lab.deliver(candidate, to: 1, relay: SpoolRelayHandle(number: 2)) == .delivered(keptLive: true))
        }
        lab.run(6)
        #expect(again == ids.count)
        #expect(bobsReceipts() == afterFirst, "a second re-pull mints no receipt")
    }

    @Test func aReinstallPullsItsOwnFramesBackAndVerifiesThemWithItsOwnKey() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0, 1])
        try SpoolEngineLabTests.send(lab, 1, 0, "mine")
        lab.run(12)
        let old = lab[1].stores
        let wiped = old.replacing(custody: MemoryCustodyStore())
        lab.replace(
            1, with: try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: wiped, wall: lab[1].clock.wallMilliseconds(), seed: 15))
        lab.connect(1)
        lab.run(12)
        #expect(lab[1].engine.spoolInbound.counts.unopenable == 0, "its own frames verify with its own key")
        #expect(lab.pairIds(1, with: 0) == lab.pairIds(0, with: 1), "its live ids equal alice's")
    }

    @Test func aFailedScopeReadKeepsTheTableAndTheNextTurnReadsAgain() throws {
        let failable = FailableStores()
        let fixtures = [
            try EngineFixture.ratcheting(SpoolEngineLabTests.alice, seed: 11),
            try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12),
        ]
        let lab = SpoolLab(fixtures)
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        try SpoolEngineLabTests.send(lab, 1, 0, "hi")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        SpoolEngineLabTests.online(lab, [0, 1])
        let scopes = lab.scopes(1)
        #expect(scopes.count == 1)
        failable.ratchet.failsSessionList = true
        lab.markTableDirty(1)
        lab.advance(SpoolPlane.reconcileMilliseconds)
        #expect(lab.scopes(1) == scopes, "a failed read keeps the table")
        let misses = lab.planes[1].unreadableTables
        #expect(misses > 0)
        failable.ratchet.failsSessionList = false
        lab.advance(1)
        #expect(lab.scopes(1) == scopes && lab.planes[1].unreadableTables == misses, "the next turn read it again")
    }

    @Test func aKeyReadThatFailsForARoundTakesNothingAndTheNextRoundDelivers() throws {
        let failable = FailableStores()
        let fixtures = [
            try EngineFixture.ratcheting(SpoolEngineLabTests.alice, seed: 11),
            try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12),
        ]
        let lab = SpoolLab(fixtures)
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        try SpoolEngineLabTests.send(lab, 1, 0, "hi")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        SpoolEngineLabTests.online(lab, [0, 1])
        failable.peers.failsReads = true
        let id = try SpoolEngineLabTests.send(lab, 0, 1, "while bob's key read fails")
        lab.run(2)
        #expect(lab[1].stores.messages.message(id) == nil, "not taken")
        failable.peers.failsReads = false
        lab.advance(ScopeHeal.tickMilliseconds)
        lab.run(6)
        #expect(lab[1].stores.messages.message(id) != nil, "the next round delivers")
        #expect(lab.heal(1)?.counts.quarantined == 0, "nothing quarantined")
    }

    @Test func aColdLaunchAfterCustodysDayKeepsOurOwnFramesAndMintsNoReceipts() throws {
        let lab = try SpoolEngineLabTests.greeted(withCarol: true)
        lab.radio.link(1, 2)
        lab.radio.unlink(1, 2)
        SpoolEngineLabTests.online(lab, [0, 1])
        var ids: [String] = []
        for batch in 0..<10 {
            ids += try (0..<25).map { try SpoolEngineLabTests.send(lab, 0, 1, "dm \(batch).\($0)") }
            lab.run(2)
        }
        lab.run(12)
        #expect(ids.allSatisfy { lab[1].stores.messages.message($0) != nil }, "the 250 crossed the relay")
        let scope = try #require(lab.scopes(1).first)
        #expect(lab.heal(1)?.localFold(scope.id) == lab.spoolDigest(scope.id), "converged")
        // Custody's day passes; the relay still holds the tail. Bob writes Carol, who is out of reach.
        lab.advance(30 * 60 * SpoolEngineLabTests.minute)
        let toCarol = try SpoolEngineLabTests.send(lab, 1, 2, "for carol")
        func bobsOwn() -> Set<String> {
            let wall = lab[1].clock.wallMilliseconds()
            return Set(
                lab[1].stores.custody.liveFrames(now: wall).filter { $0.envelope.senderId == SpoolEngineLabTests.bob.nodeId.string }.map(
                    \.envelope.id))
        }
        let before = bobsOwn()
        #expect(before.contains(toCarol))
        let wall = lab[1].clock.wallMilliseconds()
        lab.replace(1, with: try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: lab[1].stores, wall: wall, seed: 16))
        lab.connect(1)
        lab.run(6)
        #expect(lab[1].engine.spoolInbound.counts.delivered >= ids.count, "the cold launch re-pulled alice's tail")
        #expect(bobsOwn() == before, "the re-pulled tail minted no receipt, and bob's DM to carol is still held")
        lab.radio.link(1, 2)
        #expect(lab[2].stores.messages.message(toCarol)?.body == "for carol", "carol receives it")
    }
}
