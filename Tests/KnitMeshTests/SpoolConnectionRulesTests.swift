import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The connection rules the P4b1 reviews settled (ADR 2026-11.adrq, P4b1): the drop bound, the table read before a send's
/// end, an answered stamp counted once, the upload memo per session, and the spool's own seen set under a backlog past the
/// radios' set.
@Suite struct SpoolConnectionRulesTests {
    /// 256 blobs no pull named keep the connection; more than the window's bound inside a minute end it, unreached.
    @Test func droppedRecordsEndAConnectionOnlyPastTheBound() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let token = try #require(lab.tokens[1])
        let scope = try #require(lab.scopes(1).first)
        let engine = lab[1].engine
        func late(_ index: Int) -> SpoolSocketMessage {
            let id = [UInt8](repeating: 0, count: 28) + withUnsafeBytes(of: UInt32(index).bigEndian, Array.init)
            return .binary(SpoolBlob(scope: scope.id.bytes, blobId: id, data: [1, 2, 3]).encoded)
        }
        for index in 0..<SpoolLimits.maxPullCeiling {
            _ = lab.planes[1].receive(late(index), from: lab.relay, token: token, engine: engine)
        }
        #expect(lab.link(1)?.phase == .open(token), "a late pull's worth of blobs keeps the connection")
        #expect(lab.planes[1].relays[lab.relay]?.drops["unsolicited"] == SpoolLimits.maxPullCeiling)
        var ended = false
        for index in 0..<(SpoolDropWindow.maxRecords) where !ended {
            ended = lab.planes[1].receive(late(1000 + index), from: lab.relay, token: token, engine: engine) == .stop
        }
        #expect(ended && lab.link(1)?.counts.dropFaults == 1 && lab.link(1)?.failures == 1, "past the bound, unreached")
        var window = SpoolDropWindow()
        let bytes = window.note(bytes: SpoolDropWindow.maxBytes + 1, counted: true, now: 0)
        #expect(bytes, "the byte bound too")
        var later = SpoolDropWindow()
        for at in 0..<Int64(SpoolDropWindow.maxRecords) {
            _ = later.note(bytes: 1, counted: at.isMultiple(of: 2), now: at)
        }
        let rolled = later.note(bytes: 1, counted: true, now: SpoolDropWindow.windowMilliseconds + Int64(SpoolDropWindow.maxRecords))
        #expect(!rolled, "a minute on, the oldest have left the window")
    }

    /// Records of a type this build does not know are charged to the window's bytes alone: many small ones keep the
    /// connection, and past the bytes they end it.
    @Test func unknownRecordTypesCountByTheirBytesAlone() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let token = try #require(lab.tokens[1])
        let engine = lab[1].engine
        let small = SpoolErr(code: "x").cbor.replacingType(with: "x-future")
        for _ in 0...(2 * SpoolDropWindow.maxRecords) {
            _ = lab.planes[1].receive(.binary(small), from: lab.relay, token: token, engine: engine)
        }
        #expect(lab.link(1)?.phase == .open(token), "small records of a newer type keep the connection")
        #expect(lab.planes[1].relays[lab.relay]?.drops["unknown"] ?? 0 > 2 * SpoolDropWindow.maxRecords, "each counted by kind")
        let large = SpoolErr(code: "x", message: String(repeating: "m", count: 60_000)).cbor.replacingType(with: "x-future")
        var ended = false
        for _ in 0..<(SpoolDropWindow.maxBytes / large.count + 2) where !ended {
            ended = lab.planes[1].receive(.binary(large), from: lab.relay, token: token, engine: engine) == .stop
        }
        #expect(ended && lab.link(1)?.counts.dropFaults == 1, "past the bytes, the connection ends as dropped")
    }

    /// A step held on a full send queue meets the table before its pushes go on: a scope that left pushes and lists nothing.
    @Test(arguments: [true, false])
    func aSendsEndReadsTheTableFirst(forget: Bool) throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0])
        let scope = try #require(lab.scopes(0).first)
        let token = try #require(lab.tokens[0])
        lab.planes[0].relays[lab.relay]?.link.queuedBytes = 2 * SpoolLink.maxQueuedBytes
        try SpoolEngineLabTests.send(lab, 0, 1, "held")
        lab.run(2)
        #expect(lab.heal(0)?.step.map { if case .held = $0.phase { true } else { false } } == true, "the pushes wait")
        if forget {
            _ = lab[0].engine.ratchet.forget(SpoolEngineLabTests.bob.nodeId)
        } else {
            lab[0].engine.block(SpoolEngineLabTests.bob.nodeId)
            lab.planes[0].markTableDirty()
        }
        lab.forgetSent(0)
        lab.planes[0].relays[lab.relay]?.link.queuedBytes = 1
        lab.planes[0].relays[lab.relay]?.link.sending = 1
        lab.planes[0].sent(lab.relay, token: token, ok: true, engine: lab[0].engine)
        lab.pump()
        #expect(lab.scopes(0).isEmpty, "the scope left the table")
        #expect(lab.operations(0, on: scope.id) == 0, "no push or list for it")
    }

    /// A socket that never says `hello` ends at the tick that finds it, and the heal's timers in that tick meet no session.
    @Test func aSessionThatEndsInItsOwnTickLeavesTheHealNothingToRun() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let token = try lab.dialed(1)
        let opened = lab.planes[1].opened(lab.relay, token: token, engine: lab[1].engine)
        #expect(opened)
        lab[1].clock.advance(SpoolSession.handshakeMilliseconds)
        lab.planes[1].tick(engine: lab[1].engine)
        #expect(lab.link(1)?.phase == .idle && lab.link(1)?.failures == 1, "no hello is an unreached session")
        #expect(lab.planes[1].relays[lab.relay]?.session == nil)
    }

    /// An answer the heal no longer waits on, with no session open, counts nothing.
    @Test func aStaleStampAnswerCountsNothing() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.minesAtOnce = false
        lab.connect(1)
        lab.run(2)
        let request = try #require(lab.pendingMining.first)
        lab.socketClosed(1)
        let found = HealMember.found(request)
        lab.planes[1].stampMined(request, found, engine: lab[1].engine)
        #expect(lab.link(1)?.counts.stampsAnsweredOffline == 1)
        lab.planes[1].stampMined(request, found, engine: lab[1].engine)
        #expect(lab.link(1)?.counts.stampsAnsweredOffline == 1, "the second answer was stale")
    }

    /// The upload memo holds within a session; the next session's first `digest` lets a blob the spool lacks go up again.
    @Test func theUploadMemoLastsOneSession() throws {
        let spool = FakeSpool(now: EngineFixture.start)
        let lab = try SpoolEngineLabTests.greeted(spool: spool)
        SpoolEngineLabTests.online(lab, [0])
        let scope = try #require(lab.scopes(0).first)
        spool.forgetsAfterPush = true
        lab.forgetSent(0)
        try SpoolEngineLabTests.send(lab, 0, 1, "forgotten")
        lab.run(12)
        let first = lab.sent[0].compactMap { record -> [UInt8]? in if case .push(let push) = record { push.blobId } else { nil } }
        #expect(!first.isEmpty && Set(first).count == first.count, "pushed once within the session")
        #expect(!spool.liveIds(scope.id).isEmpty, "the digest stays non-zero")
        lab.disconnect(0)
        lab.forgetSent(0)
        lab.connect(0)
        lab.run(6)
        let again = Set(lab.sent[0].compactMap { record -> [UInt8]? in if case .push(let push) = record { push.blobId } else { nil } })
        #expect(Set(first).isSubset(of: again), "the next session pushes it again")
    }

    /// A spool backlog past the radios' set size never evicts a radio id: radio, then the backlog, then the same radio
    /// frames, all inside the window.
    @Test func aBacklogPastTheRadioSetNeverLetsARadioIdInTwice() throws {
        let me = ScopeFixture.bob
        let fixture = EngineFixture(me, wall: ScopeFixture.wall)
        let flooder = TestPeer(seed: 99)
        let flood = try (0..<1000).map { try flooder.profile(publishedAt: ScopeFixture.wall + Int64($0)) }
        let admitted = fixture.engine.routerCounters.admitted
        for frame in flood {
            fixture.deliver(frame, from: flooder)
        }
        #expect(fixture.engine.routerCounters.admitted - admitted == flood.count, "the first radio pass is new")
        let peers = (0..<17).map { TestPeer(seed: 200 + $0) }
        let wall = fixture.clock.wallMilliseconds()
        for (index, peer) in peers.enumerated() {
            try fixture.pin(peer)
            guard let scope = SpoolScope.of(ScopeFixture.keys(100 + index), peer: peer.nodeId, retiring: false, retiringUntil: nil) else {
                Issue.record("a scope")
                return
            }
            for number in 0..<CustodyLimits().maxPerSender {
                let frame = ScopeFixture.dm(number, from: peer, to: me, sentAt: wall, id: frameIdOf("backlog \(index).\(number)"))
                let sealed = try #require(ScopeFrames.seal(ScopeFixture.carried(frame), into: scope))
                let arrival = SpoolArrival(scope: scope.id, blobId: sealed.id, data: sealed.blob)
                let candidate = try #require(ScopeFrames.open(arrival, in: scope, me: me.nodeId, source: .pulled, now: wall))
                _ = fixture.engine.receiveFromSpool(candidate, relay: SpoolRelayHandle(number: 1))
            }
        }
        let spoolAdmitted = fixture.engine.routerCounters.spoolAdmitted
        let beforeSecond = fixture.engine.routerCounters.admitted
        #expect(spoolAdmitted >= SeenSet.defaultCapacity - flood.count, "the backlog alone would fill the radios' set")
        for frame in flood {
            fixture.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: flooder.nodeId))
        }
        #expect(fixture.engine.routerCounters.admitted == beforeSecond, "the second radio pass admits none of them again")
    }
}
