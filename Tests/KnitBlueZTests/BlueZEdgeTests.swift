#if os(Linux)
    import Foundation
    import Glibc
    @testable import KnitBlueZ
    import KnitSync
    import Testing

    /// One result, handed from the probe's thread to the test's.
    private final class Handoff: Sendable {
        let result = Lock<Result<AdapterProbe.Status, AdapterProbe.Failure>?>(nil)
    }

    /// The probe `knit-peer` runs first, and the socket calls where they fail.
    @Suite(.timeLimit(.minutes(1))) struct BlueZEdgeTests {
        /// Probes on a thread of its own: the probe blocks, and the fake must keep answering on this one.
        private func probe(
            _ fake: FakeBlueZ, for address: String, shared: Bool = false, reserved: [String] = []
        ) throws -> Result<AdapterProbe.Status, AdapterProbe.Failure> {
            let handoff = Handoff()
            let bus = fake.address
            let thread = Thread {
                let outcome = Result { () throws(AdapterProbe.Failure) in
                    try AdapterProbe.select(address: address, shared: shared, reserved: reserved, on: .peer(bus), waiting: 2000)
                }
                handoff.result.withLock { $0 = outcome }
            }
            thread.start()
            let deadline = Monotonic.milliseconds() + LoopRig.settleMilliseconds
            while handoff.result.withLock({ $0 }) == nil, Monotonic.milliseconds() < deadline {
                fake.iterate(waitMilliseconds: 2)
            }
            return try #require(handoff.result.withLock { $0 })
        }

        @Test func theProbeFindsThePoweredAdapter() throws {
            let fake = try FakeBlueZ()
            let status = try probe(fake, for: FakeBlueZ.adapterAddress).get()
            #expect(
                status
                    == AdapterProbe.Status(
                        adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress), powered: true))
        }

        /// The fake's other adapter is `hci0`: found by its address, it is taken under that name.
        @Test func theProbeFindsAnAdapterUnderWhateverNameItHas() throws {
            let fake = try FakeBlueZ()
            #expect(try probe(fake, for: "AA:AA:AA:AA:AA:AA").get().adapter.name == "hci0")
        }

        @Test func theProbeRefusesAnAddressNoAdapterHas() throws {
            let fake = try FakeBlueZ()
            guard case .failure(.refused(.absent("00:11:22:33:44:55"))) = try probe(fake, for: "00:11:22:33:44:55") else {
                Issue.record("expected a refusal")
                return
            }
        }

        @Test func theProbeRefusesAReservedAdapterBeforeAskingBlueZ() throws {
            let fake = try FakeBlueZ()
            fake.adapterAddress = "A0:00:00:00:00:01"
            let reserved = ["a0:00:00:00:00:01"]
            guard case .failure(.refused(.reservedAdapter)) = try probe(fake, for: "A0:00:00:00:00:01", reserved: reserved) else {
                Issue.record("expected a refusal")
                return
            }
            #expect(fake.calls.isEmpty, "BlueZ was never asked")
            #expect(try probe(fake, for: "A0:00:00:00:00:01", shared: true, reserved: reserved).get().adapter.shared)
            guard case .failure(.refused(.notAnAddress("nope"))) = try probe(fake, for: FakeBlueZ.adapterAddress, reserved: ["nope"]) else {
                Issue.record("expected a reserved list that does not parse to be refused")
                return
            }
        }

        @Test func theProbeSaysWhenBlueZDoesNotAnswer() throws {
            let fake = try FakeBlueZ()
            fake.refusesInventory = true
            guard case .failure(.bluez) = try probe(fake, for: FakeBlueZ.adapterAddress) else {
                Issue.record("expected BlueZ to be missing")
                return
            }
        }

        @Test func theProbeSaysWhenThereIsNoBus() {
            #expect(throws: AdapterProbe.Failure.self) {
                try AdapterProbe.select(
                    address: FakeBlueZ.adapterAddress, shared: false, reserved: [], on: .peer("unix:path=/nonexistent/knit"), waiting: 100)
            }
        }

        /// No test opens a Bluetooth socket: the kernel binds and even listens on an address no adapter has, so
        /// only the check against BlueZ keeps the peer on its own adapter (``AdapterProbe``). What is left to test
        /// without a socket is the fallback when the kernel will not say a channel's MTU.
        @Test func aChannelWhoseMTUIsUnknownWritesTheSmallestSDU() throws {
            let sockets = L2CAPSockets(adapter: try #require(BluetoothAddress("00:00:00:00:00:01")))
            #expect(sockets.sendLimit(of: -1) == L2CAPSockets.fallbackSendMTU)
            #expect(sockets.peer(of: -1) == nil)
            #expect(sockets.sendMTU == 247, "the SDU the Moto G needed")
        }

        @Test func aClosedDescriptorFailsEveryCall() {
            var buffer = [UInt8](repeating: 0, count: 8)
            #expect(Descriptor.read(-1, into: &buffer) == .failed(EBADF))
            #expect(Descriptor.write(-1, [1, 2]) == .failed(EBADF))
            #expect(Descriptor.accept(-1) == nil)
            #expect(Descriptor.pendingError(-1) == EBADF)
        }
    }
#endif
