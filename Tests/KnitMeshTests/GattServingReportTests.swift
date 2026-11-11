import Testing

@testable import KnitMesh

/// The radio's half of the bridge's `advert blind` verdict (``GattServingReport``; ADR 2026-11.prsp): the layout a form asks
/// for, up with the wanted value, and advertising started, read from ``GattServing`` as KnitBLE steps it.
@Suite struct GattServingReportTests {
    private static let clear = GattServing.Wanted(value: [1, 2, 3], blinded: false)
    private static let tag = GattServing.Wanted(value: [4, 5, 6], blinded: true)
    private static let nextTag = GattServing.Wanted(value: [7, 8, 9], blinded: true)

    private func report(_ serving: GattServing, _ wanted: GattServing.Wanted?, poweredOn: Bool = true) -> GattServingReport {
        GattServingReport(
            serving: serving,
            wanted: wanted,
            listenerPSM: 192,
            wantedPSM: 192,
            expectsBlinding: false,
            restoredServices: nil,
            matchedByOrder: 0,
            poweredOn: poweredOn
        )
    }

    /// The service the steps add.
    private func added(_ steps: [GattServing.Step]) throws -> GattServing.Service {
        try #require(
            steps.compactMap { step -> GattServing.Service? in
                if case .add(let service) = step {
                    return service
                }
                return nil
            }.last)
    }

    @Test func theCombinedServiceAppliesTheClearFormOnceItsAddLands() throws {
        var serving = GattServing()
        let combined = try added(serving.serve(Self.clear, now: 0))
        #expect(!report(serving, Self.clear).applied(blinded: false), "its add has not landed")
        _ = serving.added(combined.serial, ok: true, wanted: Self.clear, now: 1)
        let up = report(serving, Self.clear)
        #expect(up.applied(blinded: false))
        #expect(!up.applied(blinded: true), "a clear advert is no tag on the air")
        #expect(up.servesWanted && up.combinedUp && up.combinedSerial == combined.serial)
        #expect(up.layout == .combined && up.payloadSerial == nil && up.doorbellSerial == nil)
        #expect(!report(serving, Self.clear, poweredOn: false).applied(blinded: false))
        #expect(!report(serving, nil).applied(blinded: false), "nothing wanted is nothing applied")
    }

    @Test func theSplitLayoutAppliesATagOnceTheDoorbellAndThePayloadAreServed() throws {
        var serving = GattServing(expectsBlinding: true)
        let doorbell = try added(serving.serve(Self.tag, now: 0))
        #expect(report(serving, Self.tag).pendingSerial == doorbell.serial)
        let payload = try added(serving.added(doorbell.serial, ok: true, wanted: Self.tag, now: 1))
        #expect(!report(serving, Self.tag).applied(blinded: true), "the payload's add is in flight")
        _ = serving.added(payload.serial, ok: true, wanted: Self.tag, now: 2)
        let up = report(serving, Self.tag)
        #expect(up.applied(blinded: true))
        #expect(up.doorbellSerial == doorbell.serial && up.payloadSerial == payload.serial && up.advertising)
        // A rotation: the new tag is wanted, the old one served until the new payload's add lands.
        _ = serving.serve(Self.nextTag, now: 3)
        let rotating = report(serving, Self.nextTag)
        #expect(!rotating.servesWanted)
        #expect(!rotating.applied(blinded: true))
    }

    @Test func aFailedDoorbellIsReportedAndTheRetryAwaited() throws {
        var serving = GattServing(expectsBlinding: true)
        let doorbell = try added(serving.serve(Self.tag, now: 0))
        _ = serving.added(doorbell.serial, ok: false, wanted: Self.tag, now: 10)
        let failed = report(serving, Self.tag)
        #expect(failed.doorbellFailed)
        #expect(failed.retryAt == 10 + GattServing.retryMilliseconds)
        #expect(!failed.applied(blinded: true))
    }
}
