import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The pure pieces of the spool's connections (ADR 2026-11.adrq, P4b1): `Retry-After`, the inbound and upload budgets, the
/// reached rule, the spool's own seen set and the log book.
@Suite struct SpoolBoundsTests {
    private func other(_ byte: UInt8) throws -> SpoolID {
        try #require(SpoolID([UInt8](repeating: byte, count: 32)))
    }

    private func retry(_ header: String) -> Int64? {
        SpoolRetryAfter(header: Array(header.utf8)).milliseconds
    }

    @Test func retryAfterIsDeltaSecondsHeldToAMinute() {
        #expect(retry("5") == 5000)
        #expect(retry(" 12\t") == 12_000, "spaces around the digits are no part of them")
        #expect(retry("0") == 0)
        #expect(retry("60") == 60_000)
        #expect(retry("61") == 60_000, "held to the cap")
        #expect(retry("9999999999999999") == 60_000, "a product past Int64 is the cap, not a trap")
        #expect(retry("99999999999999999999") == 60_000, "digits past the cut read as the cap")
        #expect(retry("+5") == nil && retry("-5") == nil, "no sign")
        #expect(retry("Wed, 21 Oct 2026 07:28:00 GMT") == nil, "an HTTP-date is no floor")
        #expect(retry("") == nil && retry("   ") == nil)
        #expect(retry("1 2") == nil && retry("5s") == nil)
        #expect(retry("1               x") == nil, "a header past the cut that is not digits is unread")
        let cut = SpoolRetryAfter(header: Array(String(repeating: "7", count: 40).utf8))
        #expect(cut.truncated && cut.bytes.count == SpoolRetryAfter.keptBytes && "\(cut)" == "retry-after(16 bytes)")
    }

    @Test func theInboundBudgetIsABurstThatRefillsInASecond() {
        var budget = SpoolInboundBudget(now: 0)
        for _ in 0..<(SpoolInboundBudget.records - 1) {
            let room = budget.charge(bytes: 10, now: 0)
            #expect(room)
        }
        let last = budget.charge(bytes: 10, now: 0)
        #expect(!last, "the burst's last record leaves no room")
        #expect(budget.readyAt > 0 && budget.readyAt <= SpoolInboundBudget.refillMilliseconds)
        let ready = budget.readyAt
        let early = budget.hasRoom(now: ready - 1)
        let due = budget.hasRoom(now: ready)
        #expect(!early && due)
        var bytes = SpoolInboundBudget(now: 100)
        let debt = bytes.charge(bytes: SpoolInboundBudget.bytes + 1000, now: 100)
        #expect(!debt, "a byte debt waits")
        #expect(bytes.readyAt <= 100 + SpoolInboundBudget.refillMilliseconds)
        let paid = bytes.hasRoom(now: 100 + SpoolInboundBudget.refillMilliseconds)
        #expect(paid)
        var backwards = SpoolInboundBudget(now: 1000)
        _ = backwards.charge(bytes: 1, now: 500)
        let back = backwards.hasRoom(now: 500)
        let end = backwards.hasRoom(now: .max)
        #expect(back && end, "a clock that went back refills nothing and traps on nothing")
        var wide = SpoolInboundBudget(now: .min)
        _ = wide.charge(bytes: 10, now: .min)
        let refilled = wide.hasRoom(now: .max)
        #expect(refilled, "a span past Int64 refills in full")
    }

    @Test func theUploadBudgetIsTheHoursAndRemembersWhatWasStored() throws {
        var upload = SpoolUpload()
        let whole = upload.fits(SpoolUpload.maxPushedBytes, now: 0)
        upload.charge(SpoolUpload.maxPushedBytes - 10, now: 0)
        let ten = upload.fits(10, now: 1)
        let eleven = upload.fits(11, now: 1)
        let nextHour = upload.fits(SpoolUpload.maxPushedBytes, now: SpoolUpload.windowMilliseconds)
        #expect(whole && ten && !eleven && nextHour, "only the hour starts it over")
        let id = try #require(SpoolID([UInt8](repeating: 7, count: 32)))
        upload.stored(id, in: id, now: 100)
        upload.forget(scope: try other(1))
        #expect(upload.storedRecently(id, now: 100 + SpoolUpload.windowMilliseconds - 1))
        #expect(!upload.storedRecently(id, now: 100 + SpoolUpload.windowMilliseconds))
        #expect(!upload.storedRecently(id, now: 50), "a clock that went back remembers nothing")
        for index in 0..<SpoolUpload.maxRemembered {
            let other = try #require(SpoolID([UInt8](repeating: 0, count: 28) + withUnsafeBytes(of: UInt32(index).bigEndian, Array.init)))
            upload.stored(other, in: other, now: 200)
        }
        #expect(!upload.storedRecently(id, now: 200), "the oldest goes at the bound")
        let shed = try #require(SpoolID([UInt8](repeating: 0, count: 28) + [0, 0, 0, 5]))
        upload.forget(scope: shed)
        #expect(!upload.storedRecently(shed, now: 200), "a shed scope forgets what it stored")
    }

    @Test func aSessionIsReachedByLastingOrByARoundAndNeverByAFault() {
        var link = SpoolLink()
        link.openedAt = 0
        link.roundsAtOpen = 2
        let closed = SpoolSessionEnd.socket(SpoolSocketEnd(.closed, code: SpoolCloseCode.goingAway))
        #expect(!link.reached(closed, rounds: 2, now: SpoolLink.reachedMilliseconds - 1), "a hello and a close is a failure")
        #expect(link.reached(closed, rounds: 2, now: SpoolLink.reachedMilliseconds))
        #expect(link.reached(closed, rounds: 3, now: 1), "a compared round reaches it")
        #expect(!link.reached(.fault(.unopenable), rounds: 9, now: .max))
        #expect(!link.reached(.writeStall, rounds: 9, now: .max))
        #expect(!link.reached(.socket(SpoolSocketEnd(.closed, code: SpoolCloseCode.abuse)), rounds: 9, now: .max))
        #expect(SpoolSocketEnd(.closed, code: 70_000).code == SpoolSocketEnd.maxCode && SpoolSocketEnd(.tls, code: 5).code == 1000)
        #expect(SpoolDialFailure(.http, status: 9999).status == 599 && "\(SpoolDialFailure(.http, status: 503))" == "http 503")
        #expect("\(SpoolDialFailure(.tls))" == "tls")
        #expect("\(SpoolSocketEnd(.closed, code: 4003))" == "closed 4003" && "\(SpoolSocketEnd(.tls))" == "tls")
        #expect(
            "\(SpoolSocketMessage.binary([1, 2]))" == "binary(2 bytes)" && "\(SpoolSocketMessage.text(byteCount: 3))" == "text(3 bytes)")
        #expect("\(SpoolSocketMessage.closed(SpoolSocketEnd(.cancelled)))" == "closed(cancelled)")
        #expect(link.state == "idle" && "\(SpoolConnectionToken(value: 4))" == "#4")
    }

    @Test func aPulledIdAndARadioIdShareNoSetAndDedupeEachOther() throws {
        var router = Router()
        let peer = TestPeer(seed: 41)
        let pulled = try peer.profile(publishedAt: 1)
        let heard = try peer.profile(publishedAt: 2)
        let answer1 = router.admitPulled(envelope: pulled.envelope, now: 0)

        #expect(answer1 == .new)
        let answer2 = router.admit(InboundFrame(wire: pulled.wire, envelope: pulled.envelope, from: peer.nodeId), now: 1)

        #expect(answer2 == .duplicate)
        let answer3 = router.admit(InboundFrame(wire: heard.wire, envelope: heard.envelope, from: peer.nodeId), now: 1)

        #expect(answer3 == .new)
        let answer4 = router.admitPulled(envelope: heard.envelope, now: 2)

        #expect(answer4 == .duplicate)
        #expect(router.seenCount == 1 && router.spoolSeenCount == 1, "each door fills its own set")
        router.reopenPulled(pulled.envelope.id)
        #expect(router.spoolSeenCount == 0)
        let answer5 = router.admitPulled(envelope: pulled.envelope, now: 3)

        #expect(answer5 == .new)
        let reopened = router.reopen(pulled.envelope.id, now: 4)
        #expect(reopened, "a reopen finds the id in the spool's set")
        let answer6 = router.admit(InboundFrame(wire: pulled.wire, envelope: pulled.envelope, from: peer.nodeId), now: 5)

        #expect(answer6 == .new)
    }

    @Test func aSpoolBacklogNeverEvictsARadioId() throws {
        var router = Router()
        let peer = TestPeer(seed: 42)
        let radio = try peer.profile(publishedAt: 1)
        let answer7 = router.admit(InboundFrame(wire: radio.wire, envelope: radio.envelope, from: peer.nodeId), now: 0)

        #expect(answer7 == .new)
        for index in 0..<(SeenSet.defaultCapacity + 10) {
            let id = frameIdOf("backlog-\(index)")
            let answer8 = router.admitPulled(
                envelope: RelayEnvelope(type: .chat, id: id, senderId: peer.nodeId.string, payload: []), now: 1)

            #expect(answer8 == .new)
        }
        let answer9 = router.admit(InboundFrame(wire: radio.wire, envelope: radio.envelope, from: peer.nodeId), now: 2)

        #expect(answer9 == .duplicate)
    }

    @Test func theLogBookWritesOneLinePerKindPerIntervalOfWhatMoved() {
        var book = SpoolLogBook()
        let line10 = book.line("spool relay 1", kind: "link", ["dials": 0], now: 0)

        #expect(line10.isEmpty, "nothing moved")
        let line11 = book.line("spool relay 1", kind: "link", ["dials": 2, "sessions": 1], now: 0)

        #expect(line11 == ["spool relay 1 link: dials 2, sessions 1"])
        let line12 = book.line("spool relay 1", kind: "link", ["dials": 5], now: 1)

        #expect(line12.isEmpty, "inside the interval")
        let line13 = book.line("spool relay 1", kind: "heal", ["parks": 1], now: 1)

        #expect(line13.count == 1, "another kind has its own")
        let later = SpoolLogBook.intervalMilliseconds
        let line14 = book.line("spool relay 1", kind: "link", ["dials": 5, "sessions": 1], now: later)

        #expect(line14 == ["spool relay 1 link: dials 3"])
        let words = [
            SpoolDrop.undecodable, .unknown(SpoolText("x")), .beforeHello, .lateHello, .malformed, .unsubscribed, .unsolicited,
            .oversize, .unmatched,
        ].map(SpoolLogBook.word)
        #expect(Set(words).count == words.count)
    }
}
