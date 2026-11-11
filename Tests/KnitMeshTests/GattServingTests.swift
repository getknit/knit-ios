import KnitMesh
import Testing

/// The peripheral manager as the steps leave it, and every step asked of it.
private final class Server {
    var serving = GattServing()
    /// The services the manager holds, by serial.
    var held: [UInt64: GattServing.Service] = [:]
    /// The adds asked for and not yet answered, oldest first.
    var owed: [GattServing.Service] = []
    /// The adds a later removal of every service overtook: answered, they leave nothing held.
    var overtaken: Set<UInt64> = []
    var advertising = false
    var steps: [GattServing.Step] = []
    var starts = 0
    var now: Int64 = 1_000_000

    /// What the manager held before the process started: a restoration hands it back.
    init(restored: [GattServing.Service] = []) {
        for service in restored {
            held[service.serial] = service
        }
        advertising = !restored.isEmpty
    }

    func serve(_ wanted: GattServing.Wanted?) {
        apply(serving.serve(wanted, now: now))
    }

    /// Answers the oldest add owed, as the manager would.
    func answer(ok: Bool = true, wanted: GattServing.Wanted?) {
        guard !owed.isEmpty else {
            Issue.record("no add owed")
            return
        }
        let service = owed.removeFirst()
        if ok, !overtaken.contains(service.serial) {
            held[service.serial] = service
        }
        apply(serving.added(service.serial, ok: ok, wanted: wanted, now: now))
    }

    /// Answers every add owed, and those they lead to.
    func answerAll(wanted: GattServing.Wanted?) {
        while !owed.isEmpty {
            answer(wanted: wanted)
        }
    }

    private func apply(_ asked: [GattServing.Step]) {
        steps += asked
        for step in asked {
            switch step {
            case .stopAdvertising:
                advertising = false
            case .removeAll:
                held.removeAll()
                overtaken.formUnion(owed.map(\.serial))
            case .add(let service):
                owed.append(service)
            case .remove(let service):
                #expect(held.removeValue(forKey: service.serial) != nil, "a removal names a service the server holds")
            case .startAdvertising:
                #expect(!advertising, "advertising starts only when it is not running")
                advertising = true
                starts += 1
            }
        }
    }

    var roles: [GattServing.Role] { held.values.sorted { $0.serial < $1.serial }.map(\.role) }
    var payloadValues: [[UInt8]] { held.values.sorted { $0.serial < $1.serial }.compactMap(\.value) }
    var doorbellSerial: UInt64? { held.values.first { $0.role == .doorbell }?.serial }
}

/// The iPhone's GATT server through ``GattServing``'s steps, against a model of CoreBluetooth's peripheral manager that
/// answers each add in the order asked (ADR 2026-11.prsp): today's combined service while clear, the doorbell's and the
/// payload's while blinding, a rotation that replaces only the payload's, a flip that rebuilds, a failed add, a restoration
/// relaunch, and advertising started once.
@Suite struct GattServingTests {
    private static func clear(_ byte: UInt8) -> GattServing.Wanted { GattServing.Wanted(value: [0x00, byte], blinded: false) }

    @Test func theRetryWaitsASecond() {
        #expect(GattServing.retryMilliseconds == 1000)
        #expect(GattServing.Wanted(value: [1], blinded: true).layout == .split)
        #expect(GattServing.Wanted(value: [1], blinded: false).layout == .combined)
    }

    /// As `BLECore.serve()` did before the split: stop advertising, remove every service, add the new one, and advertise
    /// at its `didAdd`; each new value the same again.
    @Test func aClearFormIsTodaysCombinedServiceReplacedWhole() {
        let server = Server()
        server.serve(nil)
        #expect(server.steps == [.stopAdvertising, .removeAll], "the process's first power-on clears the server")
        #expect(server.serving.mayPublish, "nothing to wait for while clear")
        server.steps = []
        server.serve(Self.clear(1))
        guard case .add(let first) = server.steps.last else {
            Issue.record("no add")
            return
        }
        #expect(server.steps == [.stopAdvertising, .removeAll, .add(first)])
        #expect(first.role == .combined && first.value == [0x00, 1])
        server.answer(wanted: Self.clear(1))
        #expect(server.advertising && server.roles == [.combined])
        server.serve(Self.clear(1))
        #expect(server.owed.isEmpty, "the same value serves nothing new")
        server.steps = []
        server.serve(Self.clear(2))
        #expect(server.steps.prefix(2) == [.stopAdvertising, .removeAll])
        server.answer(wanted: Self.clear(2))
        #expect(server.roles == [.combined] && server.payloadValues == [[0x00, 2]])
        #expect(server.starts == 2 && server.advertising)
        #expect(server.serving.combinedUp)
    }

    /// While a clear add is in flight a new value replaces it at once, as before: the old one's late answer changes nothing.
    @Test func aClearValueDoesNotWaitForTheLastAdd() {
        let server = Server()
        server.serve(Self.clear(1))
        server.serve(Self.clear(2))
        #expect(server.owed.count == 2)
        server.answer(wanted: Self.clear(2))
        #expect(!server.advertising, "the replaced add's answer starts nothing")
        server.answer(wanted: Self.clear(2))
        #expect(server.advertising && server.payloadValues == [[0x00, 2]])
    }

    /// A failed combined add is tried again by the next serve, as `servedValue = nil` had it.
    @Test func aFailedCombinedAddIsAddedAgainAtTheNextServe() {
        let server = Server()
        server.serve(Self.clear(1))
        server.answer(ok: false, wanted: Self.clear(1))
        #expect(server.serving.combined == nil && !server.serving.wantsRetry && !server.advertising)
        server.serve(Self.clear(1))
        server.answer(wanted: Self.clear(1))
        #expect(server.advertising && server.roles == [.combined])
    }
}

/// The blinding layout through ``GattServing``'s steps (ADR 2026-11.prsp): the doorbell's service first and kept, the payload's
/// replaced at each rotation, a failed add retried at the next event, a flip that rebuilds, and a restoration that clears once.
@Suite struct GattServingBlindedTests {
    private static func clear(_ byte: UInt8) -> GattServing.Wanted { GattServing.Wanted(value: [0x00, byte], blinded: false) }
    private static func tag(_ byte: UInt8) -> GattServing.Wanted { GattServing.Wanted(value: [0x08, byte], blinded: true) }

    /// D first, then P with the payload alone, and advertising once P is served.
    @Test func aBlindedFormServesTheDoorbellAndThePayloadApart() {
        let server = Server()
        server.serve(Self.tag(1))
        guard case .add(let doorbell) = server.steps.last else {
            Issue.record("no add")
            return
        }
        #expect(doorbell.role == .doorbell && doorbell.value == nil)
        #expect(server.owed.count == 1, "one split add at a time")
        server.serve(Self.tag(1))
        #expect(server.owed.count == 1, "nothing more while it is in flight")
        server.answer(wanted: Self.tag(1))
        #expect(!server.advertising, "the doorbell alone starts no advert: a reader would find no payload")
        #expect(server.owed.map(\.role) == [.payload])
        server.answer(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload] && server.payloadValues == [[0x08, 1]])
        #expect(server.advertising && server.starts == 1)
    }

    /// The new P goes up beside the old, the old one is removed by reference, and D, its handle and the advert stay.
    @Test func aRotationReplacesThePayloadAloneAndKeepsAdvertising() {
        let server = Server()
        server.serve(Self.tag(1))
        server.answerAll(wanted: Self.tag(1))
        let doorbell = server.doorbellSerial
        for byte in UInt8(2)...11 {
            server.steps = []
            server.serve(Self.tag(byte))
            #expect(server.steps.count == 1, "an add, and no stop, no removal of everything")
            #expect(server.roles == [.doorbell, .payload], "the old payload serves until the new one lands")
            server.answer(wanted: Self.tag(byte))
            #expect(server.steps.contains { if case .remove(let old) = $0 { old.role == .payload } else { false } })
            #expect(server.roles == [.doorbell, .payload] && server.payloadValues == [[0x08, byte]])
        }
        #expect(server.doorbellSerial == doorbell, "ten rotations, one doorbell")
        #expect(server.starts == 1 && server.advertising)
        #expect(!server.steps.contains(.removeAll) && !server.steps.contains(.stopAdvertising))
    }

    /// A value that changes while its P is in flight is served once that one lands.
    @Test func aValueWantedWhileAPayloadIsInFlightFollowsIt() {
        let server = Server()
        server.serve(Self.tag(1))
        server.answerAll(wanted: Self.tag(1))
        server.serve(Self.tag(2))
        server.serve(Self.tag(3))
        server.answer(wanted: Self.tag(3))
        #expect(server.owed.map(\.value) == [[0x08, 3]])
        server.answer(wanted: Self.tag(3))
        #expect(server.payloadValues == [[0x08, 3]] && server.roles == [.doorbell, .payload])
    }

    /// A failed P keeps the old one on the air, and the first radio event a second later tries again.
    @Test func aFailedPayloadKeepsTheOldOneAndRetriesAtTheNextEvent() {
        let server = Server()
        server.serve(Self.tag(1))
        server.answerAll(wanted: Self.tag(1))
        server.serve(Self.tag(2))
        server.answer(ok: false, wanted: Self.tag(2))
        #expect(server.payloadValues == [[0x08, 1]] && server.advertising, "the old form stays served")
        #expect(server.serving.wantsRetry)
        server.now += GattServing.retryMilliseconds - 1
        server.serve(Self.tag(2))
        #expect(server.owed.isEmpty, "not before the wait")
        server.now += 1
        server.serve(Self.tag(2))
        server.answer(wanted: Self.tag(2))
        #expect(server.payloadValues == [[0x08, 2]] && !server.serving.wantsRetry)
    }

    /// A failed D is tried again too, and does not hold the listener back meanwhile.
    @Test func aFailedDoorbellIsRetriedAndLetsTheListenerPublish() {
        let server = Server()
        server.serving.restored(knitServices: 2)
        server.serve(nil)
        #expect(!server.serving.mayPublish)
        server.answer(ok: false, wanted: nil)
        #expect(server.serving.mayPublish && server.serving.wantsRetry)
        server.now += GattServing.retryMilliseconds
        server.serve(nil)
        server.answer(wanted: nil)
        #expect(server.roles == [.doorbell] && server.serving.mayPublish && !server.serving.wantsRetry)
    }

    /// Clear to blinding: advertising stops, the combined service goes by reference, then D, then P.
    @Test func aFlipToBlindingRebuilds() {
        let server = Server()
        server.serve(Self.clear(1))
        server.answer(wanted: Self.clear(1))
        server.steps = []
        server.serve(Self.tag(1))
        guard case .add(let doorbell) = server.steps.last else {
            Issue.record("no add")
            return
        }
        #expect(server.steps.prefix(2).first == .stopAdvertising)
        #expect(server.steps.contains { if case .remove(let old) = $0 { old.role == .combined } else { false } })
        #expect(doorbell.role == .doorbell && !server.steps.contains(.removeAll))
        server.answerAll(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload] && server.advertising && server.starts == 2)
    }

    /// A flip asked while the combined add is in flight waits for its answer, so the removal names a service held.
    @Test func aFlipToBlindingWaitsForTheCombinedAdd() {
        let server = Server()
        server.serve(Self.clear(1))
        server.serve(Self.tag(1))
        #expect(server.owed.map(\.role) == [.combined])
        server.answerAll(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload] && server.advertising)
    }

    /// A flip asked while the combined add is in flight and then fails goes on at once.
    @Test func aFlipToBlindingAfterAFailedCombinedAddGoesOn() {
        let server = Server()
        server.serve(Self.clear(1))
        server.serve(Self.tag(1))
        server.answer(ok: false, wanted: Self.tag(1))
        #expect(server.owed.map(\.role) == [.doorbell])
        server.answerAll(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload])
    }

    /// Blinding to clear: today's combined service, after the split add in flight lands.
    @Test func aFlipToClearRebuilds() {
        let server = Server()
        server.serve(Self.tag(1))
        server.answer(wanted: Self.tag(1))
        server.serve(Self.clear(1))
        #expect(server.owed.map(\.role) == [.payload], "the P in flight lands first")
        server.answer(wanted: Self.clear(1))
        #expect(server.owed.map(\.role) == [.combined])
        server.answer(wanted: Self.clear(1))
        #expect(server.roles == [.combined] && server.advertising)
        #expect(server.serving.doorbell == nil && server.serving.payload == nil)
    }

    /// A restoration hands back the last process's D and P, perhaps from before a flip: the first power-on stops their
    /// advert and removes them, once, then D comes up before the listener, and P once the link manager says.
    @Test func aRestorationClearsOnceAndBringsUpTheDoorbellBeforeTheListener() {
        let old = [
            GattServing.Service(serial: 900, role: .doorbell, value: nil),
            GattServing.Service(serial: 901, role: .payload, value: [0x00, 9]),
        ]
        let server = Server(restored: old)
        server.serving.restored(knitServices: old.count + 1)
        #expect(server.serving.layout == .split, "two or more, the three of a rotation's moment included")
        server.serve(nil)
        #expect(Array(server.steps.prefix(2)) == [.stopAdvertising, .removeAll])
        #expect(!server.advertising && !server.serving.mayPublish, "the listener waits for D")
        #expect(server.owed.map(\.role) == [.doorbell])
        server.answer(wanted: nil)
        #expect(server.serving.mayPublish && server.roles == [.doorbell])
        server.serve(nil)
        #expect(server.steps.filter { $0 == .removeAll }.count == 1, "once a process")
        server.serve(Self.tag(1))
        server.answer(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload] && server.advertising && server.starts == 1)
    }

    /// A restoration of a clear process's one service brings up nothing early.
    @Test func aRestorationOfOneServiceKeepsTheClearOrder() {
        let server = Server(restored: [GattServing.Service(serial: 900, role: .combined, value: [0x00, 9])])
        server.serving.restored(knitServices: 1)
        server.serve(nil)
        #expect(server.held.isEmpty && server.owed.isEmpty && server.serving.mayPublish)
        #expect(server.serving.layout == nil, "the clear order, as today")
    }

    /// A cold launch whose persisted switch blinds brings D up before the listener, as a restoration's two services do.
    @Test func aRadioThatExpectsBlindingBringsUpTheDoorbellFirst() {
        let server = Server()
        server.serving = GattServing(expectsBlinding: true)
        #expect(server.serving.layout == .split && !server.serving.mayPublish)
        server.serve(nil)
        #expect(server.owed.map(\.role) == [.doorbell])
        server.answer(wanted: nil)
        #expect(server.serving.mayPublish)
        server.serve(Self.tag(1))
        server.answer(wanted: Self.tag(1))
        #expect(server.roles == [.doorbell, .payload] && server.advertising && server.starts == 1)
    }

    /// The link manager's clear advert still decides: the expected D gives way to today's combined service.
    @Test func aRadioThatExpectsBlindingStillServesAClearAdvertCombined() {
        let server = Server()
        server.serving = GattServing(expectsBlinding: true)
        server.serve(nil)
        server.answer(wanted: nil)
        server.serve(Self.clear(1))
        server.answer(wanted: Self.clear(1))
        #expect(server.roles == [.combined] && server.advertising)
    }

    /// A restoration only ever upgrades to the split layout: one restored service says only that the last process was
    /// clear, and a radio that expects blinding still brings D up first.
    @Test func aRestorationOnlyUpgradesWhatTheRadioExpected() {
        let server = Server(restored: [GattServing.Service(serial: 900, role: .combined, value: [0x00, 9])])
        server.serving = GattServing(expectsBlinding: true)
        server.serving.restored(knitServices: 1)
        server.serve(nil)
        #expect(server.held.isEmpty && server.owed.map(\.role) == [.doorbell] && !server.serving.mayPublish, "cleared, then D")
        server.serving.restored(knitServices: 0)
        #expect(server.serving.layout == .split, "no services say nothing")
    }

    /// The oldest add still owed: the split add in flight, or the combined one before its answer, so a fallback match
    /// drops every older answer.
    @Test func theOldestOwedIsTheAddInFlight() {
        let server = Server()
        #expect(server.serving.oldestOwed == nil)
        server.serve(Self.clear(1))
        server.serve(Self.clear(2))
        let newest = server.owed.last?.serial
        #expect(server.serving.oldestOwed == newest, "the overtaken add is owed nothing")
        server.answerAll(wanted: Self.clear(2))
        #expect(server.serving.oldestOwed == nil)
        server.serve(Self.tag(1))
        #expect(server.serving.oldestOwed == server.owed.first?.serial)
    }

    /// A stop or a power-off forgets what was served; the next bring-up clears again and starts with D, from the last
    /// layout, and a late answer to an add from before changes nothing.
    @Test func aStopForgetsWhatWasServedAndTheNextBringUpStartsWithTheDoorbell() {
        let server = Server()
        server.serve(Self.tag(1))
        server.answerAll(wanted: Self.tag(1))
        server.serve(Self.tag(2))
        let late = server.owed.removeFirst()
        server.held.removeAll()
        server.advertising = false
        server.serving.forgetServices()
        #expect(!server.serving.cleared && !server.serving.advertising && server.serving.payload == nil)
        #expect(server.serving.added(late.serial, ok: true, wanted: Self.tag(2), now: server.now).isEmpty)
        server.steps = []
        server.serve(nil)
        #expect(Array(server.steps.prefix(2)) == [.stopAdvertising, .removeAll])
        #expect(server.owed.map(\.role) == [.doorbell] && !server.serving.mayPublish)
        server.answer(wanted: nil)
        server.serve(Self.tag(2))
        server.answer(wanted: Self.tag(2))
        #expect(server.roles == [.doorbell, .payload] && server.advertising)
    }

    /// Nothing wanted and no layout known: only the first clear.
    @Test func nothingWantedServesNothing() {
        let server = Server()
        server.serve(nil)
        server.serve(nil)
        #expect(server.steps == [.stopAdvertising, .removeAll])
        #expect(server.serving.added(42, ok: true, wanted: nil, now: 0).isEmpty, "an answer to nothing asked")
    }
}
