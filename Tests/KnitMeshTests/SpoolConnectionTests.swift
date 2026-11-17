import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The plane's connections (ADR 2026-11.adrq, P4b1), through ``SpoolLab``'s synchronous driver: tokens, the one end, the
/// backoff, the bounds, and a stamp answered with no session.
@Suite struct SpoolConnectionTests {
    // MARK: Stamps

    /// Test 11: a stamp answered while the relay has no session reaches the heal, and the next connection's first `sub`
    /// carries it with no second search; the same across a pause and a resume; a removed and re-added relay still
    /// subscribes once a stamp is answered.
    @Test func aStampAnsweredWithNoSessionRidesTheNextSub() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.minesAtOnce = false
        lab.connect(1)
        lab.run(2)
        let asked = try #require(lab.pendingMining.first, "the spool asked a stamp")
        let scope = try #require(lab.scopes(1).first)
        lab.socketClosed(1)
        #expect(lab.planes[1].relays[lab.relay]?.session == nil, "no session")
        lab.answerMining(1)
        let heal = try #require(lab.heal(1))
        #expect(heal.mining.isEmpty && heal.state(scope.id)?.stamp != nil, "the heal took the stamp with no session")
        #expect(lab.link(1)?.counts.stampsAnsweredOffline == 1)
        lab.forgetSent(1)
        lab.connect(1)
        lab.run(2)
        let first = lab.sent[1].first { if case .sub = $0 { true } else { false } }
        guard case .sub(let sub)? = first else {
            Issue.record("no sub after the reconnect")
            return
        }
        #expect(sub.subs.contains { $0.scope == scope.id.bytes && $0.pow != nil }, "the first sub carries the stamp")
        #expect(lab.mined[1] == [asked], "no second search")
        #expect(lab.spool.scopes[scope.id] != nil, "the spool holds the scope")

        // Across a pause: the heal keeps its stamp, and the resume asks for nothing more.
        lab.disconnect(1)
        lab.connect(1)
        lab.run(2)
        #expect(lab.mined[1] == [asked] && lab.heal(1)?.state(scope.id)?.stamp != nil)
    }

    @Test func aRemovedAndReAddedRelayStartsAFreshHealThatStillSubscribes() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.minesAtOnce = false
        lab.connect(1)
        lab.run(2)
        let asked = try #require(lab.pendingMining.first)
        lab.planes[1].remove(lab.relay, engine: lab[1].engine)
        lab.takeActions(1)
        lab.pump()
        #expect(lab.cancelledMining.contains(asked), "the removal cancelled the search")
        SpoolLab.add(&lab.planes[1], lab.relay, engine: lab[1].engine)
        lab.connect(1)
        lab.run(2)
        #expect(lab.mined[1].count == 2, "the fresh heal asked again")
        lab.answerMining(1)
        lab.run(2)
        let scope = try #require(lab.scopes(1).first)
        #expect(lab.spool.scopes[scope.id] != nil && lab.heal(1)?.mining.isEmpty == true, "it subscribed once the stamp came")
    }

    // MARK: Sessions

    /// Test 2's plane half: a relay with no session reports its dial alone, whatever its heal holds.
    @Test func aRelayWithNoSessionReportsItsDialAlone() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        lab.planes[1].relays[lab.relay]?.link.failures = 6
        lab.socketClosed(1, SpoolSocketEnd(.closed, code: SpoolCloseCode.abuse))
        let redial = try #require(lab.link(1)?.nextDialAt, "a redial is set")
        let tick = try #require(lab.heal(1)?.nextTickAt)
        #expect(tick < redial, "the heal's tick falls before the redial")
        lab[1].clock.advance(ScopeHeal.tickMilliseconds + 1)
        #expect(lab.planes[1].nextDeadline == redial, "the dial alone, past the heal's tick")
        lab.disconnect(1)
        #expect(lab.planes[1].nextDeadline == nil, "paused: no timer at all")
    }

    /// Carries node `index`'s records by hand between its plane and `connection` until `stop` says so after a record sent.
    private func drive(
        _ lab: SpoolLab, _ index: Int, _ token: SpoolConnectionToken, _ connection: FakeSpool.Connection,
        until stop: (SpoolRecord) -> Bool
    ) {
        let engine = lab[index].engine
        for _ in 0..<200 {
            var moved = false
            for case .send(_, _, let bytes) in lab.planes[index].takeActions() {
                moved = true
                lab.spool.receive(bytes, from: connection)
                lab.planes[index].sent(lab.relay, token: token, ok: true, engine: engine)
                if let record = SpoolRecord(decoding: bytes), stop(record) {
                    return
                }
            }
            for case .record(let bytes) in lab.spool.take(connection) {
                moved = true
                _ = lab.planes[index].receive(.binary(bytes), from: lab.relay, token: token, engine: engine)
            }
            if !moved {
                lab[index].clock.advance(ScopeHeal.healFloorMilliseconds)
                lab.planes[index].tick(engine: engine)
            }
        }
        Issue.record("the record never went")
    }

    /// Test 3: a pause during a pull, then a resume; a second open with no close between; the stale socket's late close.
    @Test func aPauseMidPullAndASecondOpenBothEndInACompletedRound() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0])
        for index in 0..<5 {
            try SpoolEngineLabTests.send(lab, 0, 1, "queued \(index)")
        }
        lab.run(6)
        let stale = try lab.dialed(1)
        let step1 = lab.planes[1].opened(lab.relay, token: stale, engine: lab[1].engine)

        #expect(step1)
        drive(lab, 1, stale, lab.spool.connect()) { record in
            if case .pull = record { true } else { false }
        }
        var intake = try #require(lab.heal(1)?.intake)
        #expect(intake.room(now: lab[1].clock.monotonicMilliseconds()) < SpoolIntake.maxPulledBytes, "the pull's worst case is charged")
        lab.disconnect(1)
        intake = try #require(lab.heal(1)?.intake)
        #expect(intake.room(now: lab[1].clock.monotonicMilliseconds()) == SpoolIntake.maxPulledBytes, "a pause gives it back")
        lab.connect(1)
        lab.run(6)
        let rounds = lab.heal(1)?.counts.roundsCompared ?? 0
        #expect(rounds > 0, "a round completed on the new connection")
        #expect(lab.reopen(1), "a second open on the token")
        lab.run(14)
        #expect((lab.heal(1)?.counts.roundsCompared ?? 0) > rounds, "the second open still completes a round")
        let before = lab.link(1)?.counts
        lab.planes[1].socketClosed(lab.relay, token: stale, SpoolSocketEnd(.closed), engine: lab[1].engine)
        #expect(lab.link(1)?.counts == before && lab.planes[1].relays[lab.relay]?.session != nil, "the stale close changes nothing")
        let receive = lab.planes[1].receive(.binary([0xA0]), from: lab.relay, token: stale, engine: lab[1].engine)
        #expect(receive == .stop, "a stale record stops its reader")
    }

    // MARK: Backoff

    /// Test 9: a refused dial, `Retry-After` in every shape, a dial that never opens, a close 4003, an `unopenable` end,
    /// and a resume.
    @Test func theBackoffFollowsTheCurveAndRetryAfterIsAFloor() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let plane = { lab.planes[1] }
        let engine = lab[1].engine
        let shapes: [(String?, Int64)] = [
            (nil, 0), ("30", 30_000), ("+5", 0), ("-5", 0), ("Wed, 21 Oct 2026 07:28:00 GMT", 0), ("99999999999999999999", 60_000),
            ("", 0),
        ]
        var token = try lab.dialed(1)
        for (index, (header, floor)) in shapes.enumerated() {
            let failure = SpoolDialFailure(.http, status: 503, retryAfter: header.map { SpoolRetryAfter(header: Array($0.utf8)) })
            lab.planes[1].dialFailed(lab.relay, token: token, failure, engine: engine)
            let wait = lab.waited(1)
            let curve = max(SpoolBackoff.waitMilliseconds(failures: index + 1), floor)
            #expect(wait >= curve && wait < curve + SpoolBackoff.jitterMilliseconds, "\(header ?? "none"): waited \(wait)")
            lab.advance(wait)
            lab.takeActions(1)
            token = try #require(lab.pendingDials[1])
        }
        #expect(plane().relays[lab.relay]?.link.counts.dialFailures == shapes.count)

        // A dial that never opens: the open deadline drops it as a failure.
        let failures = lab.link(1)?.failures ?? 0
        lab.advance(SpoolLink.openMilliseconds)
        #expect(lab.link(1)?.counts.dialTimeouts == 1 && lab.link(1)?.failures == failures + 1)

        // A resume dials at once, its count reset.
        lab.planes[1].resume(engine: engine)
        lab.takeActions(1)
        #expect(lab.link(1)?.failures == 0 && lab.pendingDials[1] != nil, "an immediate dial")

        // A session that lasted but was closed 4003 is still a failure.
        lab.connect(1)
        lab.run(8)
        lab.socketClosed(1, SpoolSocketEnd(.closed, code: SpoolCloseCode.abuse))
        #expect(lab.link(1)?.failures == 1 && lab.link(1)?.counts.unreached ?? 0 > 0)
    }

    @Test func anUnopenableEndIsUnreachedAndAReachedSessionStartsTheCountOver() throws {
        let spool = FakeSpool(now: EngineFixture.start)
        spool.garblesServes = true
        let lab = try SpoolEngineLabTests.greeted(spool: spool)
        SpoolEngineLabTests.online(lab, [0])
        for index in 0..<40 {
            try SpoolEngineLabTests.send(lab, 0, 1, "garbled \(index)")
        }
        lab.run(6)
        lab.connect(1)
        lab.run(12)
        #expect(lab.heal(1)?.counts.faults ?? 0 > 0, "the session ended unopenable")
        #expect(lab.link(1)?.failures ?? 0 > 0, "and that is a failure, however long it lasted")
        let healthy = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(healthy, [1])
        healthy.advance(SpoolLink.reachedMilliseconds)
        healthy.socketClosed(1)
        #expect(healthy.link(1)?.failures == 0 && healthy.link(1)?.counts.reached == 1, "a session that lasted is reached")
        #expect(healthy.waited(1) < SpoolBackoff.minimumMilliseconds + SpoolBackoff.jitterMilliseconds)
    }

    /// Test 8's `closesAfterHello`: the redials follow the failure curve, never about a second.
    @Test func aSpoolThatClosesAfterTheHelloIsRedialledOnTheCurve() throws {
        let spool = FakeSpool(now: EngineFixture.start)
        spool.closesAfterHello = true
        let lab = try SpoolEngineLabTests.greeted(spool: spool)
        for attempt in 1...5 {
            lab.connect(1)
            #expect(lab.link(1)?.failures == attempt, "attempt \(attempt) unreached")
            let wait = lab.waited(1)
            #expect(wait >= SpoolBackoff.waitMilliseconds(failures: attempt), "attempt \(attempt) waited \(wait)")
            lab.advance(wait)
        }
    }
}

extension SpoolLab {
    /// Node `index`'s connection to the lab's relay.
    func link(_ index: Int) -> SpoolLink? {
        planes[index].relays[relay]?.link
    }

    /// Resumes node `index`'s plane and answers the dial it asks for.
    func dialed(_ index: Int) throws -> SpoolConnectionToken {
        planes[index].resume(engine: self[index].engine)
        takeActions(index)
        return try #require(pendingDials[index])
    }

    /// How long node `index` waits before its next dial.
    func waited(_ index: Int) -> Int64 {
        (link(index)?.nextDialAt ?? 0) - self[index].clock.monotonicMilliseconds()
    }
}
