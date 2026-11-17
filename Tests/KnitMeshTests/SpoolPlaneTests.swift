import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The plane's own bookkeeping (ADR 2026-11.adrq, P4a): stamps asked of its miner and cancelled with their scope, its relays,
/// and the table's activity input.
@Suite struct SpoolPlaneTests {
    @Test func aStampTheSpoolDemandsIsMinedAndTheScopeSubscribes() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        SpoolEngineLabTests.online(lab, [0, 1])
        let scope = try #require(lab.scopes(0).first)
        #expect(!lab.mined[0].isEmpty || !lab.mined[1].isEmpty, "a stamp was mined")
        #expect(lab.spool.scopes[scope.id] != nil, "the spool holds the scope")
        let toBob = try SpoolEngineLabTests.send(lab, 0, 1, "stamped")
        lab.run(12)
        #expect(lab[1].stores.messages.message(toBob) != nil)
    }

    @Test func aBlockOrADroppedRelayCancelsTheSearchInItsTurn() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.minesAtOnce = false
        lab.connect(1)
        lab.run(2)
        let asked = try #require(lab.pendingMining.first, "bob waits on a stamp")
        lab[1].engine.block(SpoolEngineLabTests.alice.nodeId)
        lab.markTableDirty(1)
        #expect(lab.cancelledMining.contains(asked), "the block's turn cancelled the search")

        lab.connect(0)
        lab.run(2)
        #expect(lab.mined[0].count == 1 && lab.pendingMining.count == 1, "alice waits on her own search")
        let cancelled = lab.cancelledMining.count
        lab.planes[0].remove(lab.relay, engine: lab[0].engine)
        lab.pump()
        #expect(lab.cancelledMining.count == cancelled + 1 && lab.pendingMining.isEmpty, "dropping the relay cancelled its search")
    }

    /// `aRelayThatDropsEverySocketReconvergesOnAFreshConnection` (`InternetPlaneLabTest.kt:771`), the DM half.
    @Test func aDroppedSocketReconvergesOnAFreshConnection() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0, 1])
        lab.disconnect(1)
        #expect(lab.planes[1].relays[lab.relay]?.session == nil, "the connection is gone")
        let toBob = try SpoolEngineLabTests.send(lab, 0, 1, "while bob was away")
        lab.run(3)
        #expect(lab[1].stores.messages.message(toBob) == nil)
        lab.connect(1)
        lab.run(6)
        #expect(lab[1].stores.messages.message(toBob) != nil, "a fresh connection pulls what it missed")
        let scope = try #require(lab.scopes(1).first)
        #expect(lab.heal(1)?.localFold(scope.id) == lab.spoolDigest(scope.id))
    }

    @Test func aRelayTheTableDoesNotCarryAnswersNothing() throws {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        var plane = SpoolPlane(me: fixture.me.nodeId)
        let unknown = SpoolRelayHandle(number: 9)
        #expect(plane.nextDeadline == nil, "no relay, no timer")
        let token = SpoolConnectionToken(value: 1)
        #expect(plane.receive(.binary([0xA0]), from: unknown, token: token, engine: fixture.engine) == .stop)
        plane.remove(unknown, engine: fixture.engine)
        let step1 = plane.takeActions()

        #expect(step1.isEmpty)
        let relay = SpoolRelayHandle(number: 1)
        let url = try #require(SpoolLab.url)
        let first = plane.add(relay, url: url, engine: fixture.engine)
        let second = plane.add(relay, url: url, engine: fixture.engine)
        #expect(first && !second, "a handle already carried is refused")
        #expect(plane.relays.count == 1 && plane.nextDeadline == nil, "a paused plane keeps no timer")
        plane.resume(engine: fixture.engine)
        let step2 = plane.takeActions()

        #expect(step2.count == 1, "a resume dials at once")
        #expect("\(plane)" == "spool plane: 0 scopes, 1 relays" && Mirror(reflecting: plane).children.isEmpty)
    }

    @Test func recentActivityIsOurOwnClockAndLeavesTheRoomOut() throws {
        let alice = SpoolEngineLabTests.alice
        let bob = SpoolEngineLabTests.bob
        let fixture = EngineFixture(bob)
        try fixture.pin(alice)
        let now = fixture.clock.wallMilliseconds()
        fixture.deliver(try alice.roomPost("in the room", id: frameIdOf("room-1"), sentAt: now - 5000), from: alice)
        let sent = try #require(fixture.engine.sendDirectMessage("to alice", to: alice.nodeId))
        let inputs = fixture.engine.spoolTableInputs(now: now)
        #expect(inputs.recent == [alice.nodeId: sent.sentAt], "our send to alice, and nothing of the room")
        #expect(inputs.accepted == [alice.nodeId] && inputs.blocked?.isEmpty == true && inputs.dmScopes?.isEmpty == true)
    }

    @Test func aBlockDropsThePeersScopesInItsTurnWhateverTheReadsAnswer() throws {
        let failable = FailableStores()
        let fixtures = [
            try EngineFixture.ratcheting(SpoolEngineLabTests.alice, seed: 11),
            try EngineFixture.ratcheting(SpoolEngineLabTests.bob, stores: failable.stores, seed: 12),
        ]
        let lab = SpoolLab(fixtures, spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        try SpoolEngineLabTests.send(lab, 1, 0, "hi")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        lab.minesAtOnce = false
        lab.connect(1)
        lab.run(2)
        let scope = try #require(lab.scopes(1).first)
        let asked = try #require(lab.pendingMining.first)
        failable.blocks.failsReads = true
        lab.forgetSent(1)
        let mined = lab.mined[1].count
        lab.block(1, SpoolEngineLabTests.alice.nodeId)
        #expect(lab.scopes(1).isEmpty, "the block's turn dropped the scope, though the blocked set could not be read")
        #expect(lab.cancelledMining.contains(asked), "and cancelled its search")
        #expect(lab.operations(1, on: scope.id) == 0 && lab.mined[1].count == mined, "no sub, pull or stamp for it")
        lab.run(2)
        #expect(lab.scopes(1).isEmpty, "a failed read keeps the table without it")
        failable.blocks.failsReads = false
        lab.advance(SpoolPlane.reconcileMilliseconds)
        #expect(lab.scopes(1).isEmpty && lab.operations(1, on: scope.id) == 0, "a read that succeeds decides: still blocked")
    }

    @Test func theTableIsReadAgainOnAGenerationBumpAlone() throws {
        let failable = FailableStores()
        let fixture = EngineFixture(SpoolEngineLabTests.bob, stores: failable.stores)
        var plane = SpoolPlane(me: fixture.me.nodeId)
        _ = plane.add(SpoolRelayHandle(number: 1), url: try #require(SpoolLab.url), engine: fixture.engine)
        failable.ratchet.failsSessionList = true
        let misses = plane.unreadableTables
        plane.refreshTable(engine: fixture.engine)
        #expect(plane.unreadableTables == misses, "not due: nothing read")
        fixture.engine.ratchet.settle(.forgotten(SpoolEngineLabTests.alice.nodeId))
        plane.refreshTable(engine: fixture.engine)
        #expect(plane.unreadableTables == misses + 1, "due after the bump, with no dirty mark")
    }
}
