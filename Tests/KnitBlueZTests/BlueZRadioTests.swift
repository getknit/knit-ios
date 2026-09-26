#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Synchronization
    import Testing

    /// The radio's public face: its own thread, driven only through the `Radio` calls, against the fake BlueZ.
    @Suite(.timeLimit(.minutes(1))) struct BlueZRadioTests {
        /// Collects a radio's events from its stream, so the test thread can keep the fake turning.
        private final class Collector: Sendable {
            private let events = Mutex<[RadioEvent]>([])
            private let finished = Mutex(false)

            var all: [RadioEvent] { events.withLock { $0 } }
            var isFinished: Bool { finished.withLock { $0 } }

            func take(_ stream: AsyncStream<RadioEvent>) async {
                for await event in stream {
                    events.withLock { $0.append(event) }
                }
                finished.withLock { $0 = true }
            }
        }

        private func radio(_ fake: FakeBlueZ, sockets: UnixSockets, profile: RadioProfile = .android) throws -> BlueZRadio {
            var configuration = BlueZRadio.Configuration(
                adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress),
                profile: profile,
                objectRoot: "/app/getknit/radio",
                log: CapturingLog()
            )
            configuration.bus = .peer(fake.address)
            configuration.sockets = sockets
            return BlueZRadio(configuration: configuration)
        }

        /// Turns the fake until `condition` holds, or two seconds pass.
        private func settle(_ fake: FakeBlueZ, until condition: () -> Bool) -> Bool {
            let deadline = Monotonic.milliseconds() + 2000
            while !condition(), Monotonic.milliseconds() < deadline {
                fake.iterate(waitMilliseconds: 2)
            }
            return condition()
        }

        @Test func theRadioRunsOnItsOwnThreadAndEndsWhenShutDown() async throws {
            let fake = try FakeBlueZ()
            let sockets = UnixSockets(directory: UnixSockets.temporaryDirectory())
            let radio = try radio(fake, sockets: sockets)
            #expect(radio.advertisesServiceData)
            #expect(!radio.dialsGattPeers)
            let collector = Collector()
            let listening = Task { await collector.take(radio.events) }
            radio.start()
            #expect(settle(fake) { collector.all.contains(.listening(psm: UnixSockets.psm)) })
            radio.advertise(LoopRig.ours)
            #expect(settle(fake) { fake.registered.count == 1 })
            let dialed = radio.dial(RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm)
            #expect(settle(fake) { collector.all.contains(.dialFailed(dialed)) })
            radio.write([1], to: dialed)
            radio.close(dialed)
            radio.stop()
            #expect(settle(fake) { fake.registered.isEmpty })
            let shutdown = Task { await radio.shutdown() }
            #expect(settle(fake) { collector.isFinished })
            await shutdown.value
            await listening.value
        }

        @Test func theIOSProfileAdvertisesNoServiceDataAndReadsGATTPayloads() throws {
            let fake = try FakeBlueZ()
            let radio = try radio(fake, sockets: UnixSockets(directory: UnixSockets.temporaryDirectory()), profile: .ios)
            #expect(!radio.advertisesServiceData)
            #expect(radio.dialsGattPeers)
        }

        @Test func aRadioReadsGATTPayloadsWhenToldWhateverItsProfile() throws {
            var configuration = BlueZRadio.Configuration(
                adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress),
                profile: .android,
                log: CapturingLog()
            )
            #expect(!configuration.readsGattPayloads)
            #expect(!configuration.loop.readsGattPayloads)
            configuration.readsGattPayloads = true
            #expect(configuration.loop.readsGattPayloads, "knit-peer scan lists iPhones")
        }

        @Test func theDefaultConfigurationUsesL2CAPOnTheSystemBus() throws {
            let configuration = BlueZRadio.Configuration(
                adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress),
                profile: .android,
                log: CapturingLog()
            )
            #expect(configuration.bus == .system)
            #expect(configuration.objectRoot == "/app/getknit/peer")
            #expect((configuration.sockets as? L2CAPSockets)?.adapter.description == FakeBlueZ.adapterAddress)
        }
    }
#endif
