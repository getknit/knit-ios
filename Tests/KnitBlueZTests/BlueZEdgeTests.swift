#if os(Linux)
    import Foundation
    import Glibc
    @testable import KnitBlueZ
    import Synchronization
    import Testing

    /// One result, handed from the probe's thread to the test's.
    private final class Handoff: Sendable {
        let result = Mutex<Result<AdapterProbe.Status, AdapterProbe.Failure>?>(nil)
    }

    /// The probe `knit-peer` runs first, and the socket calls where they fail.
    @Suite(.timeLimit(.minutes(1))) struct BlueZEdgeTests {
        /// Probes on a thread of its own: the probe blocks, and the fake must keep answering on this one.
        private func probe(_ fake: FakeBlueZ, expecting address: String) throws -> Result<AdapterProbe.Status, AdapterProbe.Failure> {
            let selection = try AdapterSelection(name: "hci1", expectedAddress: address)
            let handoff = Handoff()
            let bus = fake.address
            let thread = Thread {
                let outcome = Result { () throws(AdapterProbe.Failure) in
                    try AdapterProbe.check(selection, on: .peer(bus), waiting: 2000)
                }
                handoff.result.withLock { $0 = outcome }
            }
            thread.start()
            let deadline = Monotonic.milliseconds() + 3000
            while handoff.result.withLock({ $0 }) == nil, Monotonic.milliseconds() < deadline {
                fake.iterate(waitMilliseconds: 2)
            }
            return try #require(handoff.result.withLock { $0 })
        }

        @Test func theProbeFindsThePoweredAdapter() throws {
            let fake = try FakeBlueZ()
            #expect(try probe(fake, expecting: FakeBlueZ.adapterAddress).get() == AdapterProbe.Status(powered: true))
        }

        @Test func theProbeRefusesAnAdapterWithAnotherAddress() throws {
            let fake = try FakeBlueZ()
            guard case .failure(.refused(.wrongAddress)) = try probe(fake, expecting: "00:11:22:33:44:55") else {
                Issue.record("expected a refusal")
                return
            }
        }

        @Test func theProbeSaysWhenBlueZDoesNotAnswer() throws {
            let fake = try FakeBlueZ()
            fake.refusesInventory = true
            guard case .failure(.bluez) = try probe(fake, expecting: FakeBlueZ.adapterAddress) else {
                Issue.record("expected BlueZ to be missing")
                return
            }
        }

        @Test func theProbeSaysWhenThereIsNoBus() throws {
            let selection = try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress)
            #expect(throws: AdapterProbe.Failure.self) {
                try AdapterProbe.check(selection, on: .peer("unix:path=/nonexistent/knit"), waiting: 100)
            }
        }

        /// No test opens a Bluetooth socket: the kernel binds and even listens on an address no adapter has, so
        /// only the check against BlueZ keeps the peer on its own adapter (``AdapterProbe``). What is left to test
        /// without a socket is the fallback when the kernel will not say a channel's MTU.
        @Test func aChannelWhoseMTUIsUnknownWritesTheSmallestSDU() throws {
            let sockets = L2CAPSockets(adapter: try #require(BluetoothAddress("00:00:00:00:00:01")))
            #expect(sockets.sendLimit(of: -1) == L2CAPSockets.fallbackSendMTU)
            #expect(sockets.peer(of: -1) == nil)
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
