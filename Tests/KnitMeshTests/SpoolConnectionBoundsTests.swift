import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The connection's bounds (ADR 2026-11.adrq, P4b1): the upload budget and memo, the write stall, a failed send, the inbound
/// budget and the relay cap.
@Suite struct SpoolConnectionBoundsTests {
    // MARK: Bounds

    /// Test 8's `forgetsAfterPush`, with the digests churning and no shed (the scope keeps the frames pushed before): what
    /// Alice uploads in an hour stays inside the push budget, and a blob the relay stored is not pushed again inside the hour.
    @Test func aSpoolThatForgetsWhatItStoredCostsAtMostTheHoursBudget() throws {
        let spool = FakeSpool(now: EngineFixture.start)
        let lab = try SpoolEngineLabTests.greeted(spool: spool)
        SpoolEngineLabTests.online(lab, [0])
        let scope = try #require(lab.scopes(0).first)
        #expect(!spool.liveIds(scope.id).isEmpty, "the scope holds the greeting")
        spool.forgetsAfterPush = true
        lab.forgetSent(0)
        let uploaded = spool.uploadedBytes
        for index in 0..<20 {
            try SpoolEngineLabTests.send(lab, 0, 1, "forgotten \(index)")
        }
        lab.run(Int(SpoolUpload.windowMilliseconds / ScopeHeal.tickMilliseconds) - 5, every: ScopeHeal.tickMilliseconds)
        let pushes = lab.sent[0].compactMap { record -> [UInt8]? in if case .push(let push) = record { push.blobId } else { nil } }
        #expect(!pushes.isEmpty && spool.uploadedBytes - uploaded <= SpoolUpload.maxPushedBytes)
        #expect(!spool.liveIds(scope.id).isEmpty, "never shed")
        #expect(Set(pushes).count == pushes.count, "nothing stored is pushed again inside the hour")
    }

    /// Test 8's `neverReads`, at the plane: bytes no send finishes end the session at the stall, unreached.
    @Test func bytesNoSendFinishesEndTheSessionAtTheStall() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let engine = lab[1].engine
        let token = try lab.dialed(1)
        let step2 = lab.planes[1].opened(lab.relay, token: token, engine: engine)

        #expect(step2)
        let connection = lab.spool.connect()
        for outgoing in lab.spool.take(connection) {
            if case .record(let bytes) = outgoing {
                _ = lab.planes[1].receive(.binary(bytes), from: lab.relay, token: token, engine: engine)
            }
        }
        let sends = lab.takeActions(1)
        #expect(sends.isEmpty, "the lab answers sends only on its own connections")
        let actions = lab.planes[1].takeActions()
        #expect(actions.isEmpty, "one send in flight, the rest queued")
        #expect((lab.link(1)?.queuedBytes ?? 0) > 0 && lab.link(1)?.sending != nil)
        lab[1].clock.advance(SpoolLink.writeStallMilliseconds)
        lab.planes[1].tick(engine: engine)
        #expect(lab.link(1)?.counts.writeStalls == 1 && lab.link(1)?.failures == 1, "a stall is unreached")
        #expect(lab.link(1)?.queuedBytes == 0 && lab.planes[1].relays[lab.relay]?.outgoing.isEmpty == true, "the queue went")
        lab.planes[1].sent(lab.relay, token: token, ok: true, engine: engine)
        #expect(lab.link(1)?.phase == .idle, "a late send answer changes nothing")
    }

    @Test func aFailedSendIsTheSocketsEnd() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let engine = lab[1].engine
        let token = try lab.dialed(1)
        let step3 = lab.planes[1].opened(lab.relay, token: token, engine: engine)

        #expect(step3)
        let connection = lab.spool.connect()
        for case .record(let bytes) in lab.spool.take(connection) {
            _ = lab.planes[1].receive(.binary(bytes), from: lab.relay, token: token, engine: engine)
        }
        _ = lab.planes[1].takeActions()
        lab.planes[1].sent(lab.relay, token: token, ok: false, engine: engine)
        #expect(lab.link(1)?.counts.sendFailures == 1 && lab.link(1)?.phase == .idle)
        let step4 = lab.planes[1].takeActions()

        #expect(step4.contains(.close(lab.relay, token, code: SpoolCloseCode.normal)))
    }

    /// Test 7's plane half: a flood of junk charges the inbound budget, which parks the reader until it refills.
    @Test func aFloodParksTheReaderUntilTheBudgetRefills() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let engine = lab[1].engine
        let token = try lab.dialed(1)
        let step5 = lab.planes[1].opened(lab.relay, token: token, engine: engine)

        #expect(step5)
        var parked = 0
        for index in 0..<200 {
            let message: SpoolSocketMessage = index.isMultiple(of: 3) ? .text(byteCount: 9) : .binary([0xA0, UInt8(index & 0xFF)])
            if lab.planes[1].receive(message, from: lab.relay, token: token, engine: engine) == .park {
                parked += 1
                let ready = try #require(lab.planes[1].nextDeadline)
                lab[1].clock.advance(max(ready - lab[1].clock.monotonicMilliseconds(), 0))
                lab.planes[1].tick(engine: engine)
                let step6 = lab.planes[1].takeActions()

                #expect(step6.contains(.resumeReader(lab.relay, token)), "the reader reads on at the deadline")
            }
        }
        #expect(parked >= 2 && lab.link(1)?.counts.inboundDeferred == parked)
        #expect(lab.link(1)?.counts.textDropped == 67)
        let status = lab.planes[1].status(inbound: lab[1].engine.spoolInbound.counts)
        let drops = status.relays.first?.counts.filter { $0.key.hasPrefix("dropped.") }.values.reduce(0, +) ?? 0
        #expect(status.relays.first?.counts["inboundDeferred"] == parked && drops == 200 - 67, "every junk record counted dropped")
    }

    @Test func postsUnderAnotherTokenAndForAnotherRelayAreDropped() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let engine = lab[1].engine
        let token = try lab.dialed(1)
        let stale = SpoolConnectionToken(value: 999)
        let opened = lab.planes[1].opened(lab.relay, token: stale, engine: engine)
        #expect(!opened, "an open under another token is refused")
        lab.planes[1].dialFailed(lab.relay, token: stale, SpoolDialFailure(.unreachable), engine: engine)
        if case .dialing(let current, _)? = lab.link(1)?.phase {
            #expect(current == token, "the dial in place stands")
        }
        #expect(lab.link(1)?.counts.dialFailures == 0, "a stale failure counts nothing")
        let request = SpoolMiningRequest(
            relay: SpoolRelayHandle(number: 9), scope: try #require(SpoolID([UInt8](repeating: 1, count: 32))), day: 1, bits: 8)
        lab.planes[1].stampMined(request, counter: 1, engine: engine)
        #expect(lab.planes[1].takeMining().isEmpty, "an answer for a relay not carried does nothing")
    }

    /// The heal holds its pushes while the send queue is at its cap and sends them once it drains, and the hour's upload
    /// budget, once spent, leaves the rest for a later hour.
    @Test func aFullQueueHoldsThePushesAndASpentHourDefersThem() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0])
        lab.planes[0].relays[lab.relay]?.link.queuedBytes = SpoolLink.maxQueuedBytes
        try SpoolEngineLabTests.send(lab, 0, 1, "held")
        lab.run(2)
        #expect(lab.heal(0)?.counts.outboundHeld ?? 0 > 0, "the pushes waited for the queue")
        // The lab's sends finish at once, so the queue drains under the held pushes and they go.
        #expect(lab.heal(0)?.counts.pushed ?? 0 > 0, "a drained queue lets them go")

        // The bytes this test made up were never queued: one send's end drains them, and the round goes on.
        let token = try #require(lab.tokens[0])
        lab.planes[0].relays[lab.relay]?.link.queuedBytes = 1
        lab.planes[0].relays[lab.relay]?.link.sending = 1
        lab.planes[0].sent(lab.relay, token: token, ok: true, engine: lab[0].engine)
        lab.run(2)

        lab.planes[0].relays[lab.relay]?.heal.upload.charge(SpoolUpload.maxPushedBytes, now: lab[0].clock.monotonicMilliseconds())
        try SpoolEngineLabTests.send(lab, 0, 1, "over the hour")
        lab.run(2)
        #expect(lab.heal(0)?.counts.pushBudgetDeferred ?? 0 > 0, "a spent hour defers the push")
    }

    @Test func pastEightRelaysAddingIsRefused() throws {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        var plane = SpoolPlane(me: fixture.me.nodeId)
        let url = try #require(SpoolLab.url)
        for number in 1...SpoolPlane.maxRelays {
            let step7 = plane.add(SpoolRelayHandle(number: number), url: url, engine: fixture.engine)

            #expect(step7)
        }
        let step8 = plane.add(SpoolRelayHandle(number: 99), url: url, engine: fixture.engine)

        #expect(!step8)
        plane.resume(engine: fixture.engine)
        let tokens = plane.takeActions().compactMap { action -> SpoolConnectionToken? in
            if case .dial(_, let token, _) = action { token } else { nil }
        }
        #expect(Set(tokens).count == SpoolPlane.maxRelays, "one engine-wide counter, a token a dial")
        plane.pause(engine: fixture.engine)
        let step9 = plane.takeActions()

        #expect(step9.count == SpoolPlane.maxRelays, "a pause closes every dial")
        #expect(plane.nextDeadline == nil)
    }
}
