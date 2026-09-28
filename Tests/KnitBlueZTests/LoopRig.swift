#if os(Linux)
    import Foundation
    @testable import KnitBlueZ
    import KnitMesh
    import KnitTestSupport
    import KnitWire
    import KnitSync
    import Testing

    /// A log that keeps its lines, for tests that check what was said.
    final class CapturingLog: KnitLog {
        private let lines = Lock<[String]>([])

        var all: [String] { lines.withLock { $0 } }

        func log(_: LogLevel, _ message: @autoclosure () -> String) {
            let line = message()
            lines.withLock { $0.append(line) }
        }
    }

    /// What the loop emitted, in order.
    final class EventBox {
        var events: [RadioEvent] = []
    }

    /// A ``BlueZLoop`` driven by hand on the test's thread, against a ``FakeBlueZ`` and ``UnixSockets``.
    final class LoopRig {
        static let peerAddress = "4A:00:00:00:00:EF"
        static let peerPath = FakeBlueZ.adapter + "/dev_4A_00_00_00_00_EF"
        /// A device of the maintainer's adapter, which the radio must never report.
        static let otherPath = FakeBlueZ.otherAdapter + "/dev_11_22_33_44_55_66"
        /// Our own advert.
        static let ours = AdvertPayload(capabilities: .local, nodeId: fixtureNodeId(3), digestCue: 5, psm: UnixSockets.psm)

        let fake: FakeBlueZ
        let mailbox = Mailbox()
        let sockets: UnixSockets
        let log = CapturingLog()
        let loop: BlueZLoop
        private let box = EventBox()

        /// GATT reads for the tests: a short deadline, and waits long enough that a test sees no second read unless
        /// it asks for a shorter one.
        static let gattPacing = GattPayloads.Configuration(
            readTimeoutMilliseconds: 300, retryMilliseconds: 60_000, strangerRetryMilliseconds: 60_000)

        init(
            profile: RadioProfile = .android,
            expectedAddress: String = FakeBlueZ.adapterAddress,
            sharedAdapter: Bool = false,
            failsToListen: Bool = false,
            limit: Int = 100,
            acceptedPeer: DialTarget? = nil,
            readsGattPayloads: Bool = false,
            gatt: GattPayloads.Configuration = LoopRig.gattPacing,
            forgetQuietDevicesAfter quiet: Int64 = 60_000
        ) throws {
            fake = try FakeBlueZ()
            sockets = UnixSockets(
                directory: UnixSockets.temporaryDirectory(), limit: limit, failsToListen: failsToListen, acceptedPeer: acceptedPeer)
            var configuration = BlueZLoop.Configuration(
                bus: .peer(fake.address),
                adapter: try AdapterSelection(name: "hci1", expectedAddress: expectedAddress, shared: sharedAdapter),
                profile: profile,
                sockets: sockets,
                objectRoot: "/app/getknit/test",
                log: log
            )
            configuration.readvertiseDelayMilliseconds = 20
            configuration.retryDelayMilliseconds = 20
            configuration.readsGattPayloads = readsGattPayloads
            configuration.gatt = gatt
            configuration.forgetQuietDevicesMilliseconds = quiet
            configuration.forgetSweepMilliseconds = min(quiet, 30_000) / 2
            let recorder = box
            loop = BlueZLoop(configuration: configuration, mailbox: mailbox) { recorder.events.append($0) }
        }

        deinit {
            try? FileManager.default.removeItem(atPath: sockets.directory)
        }

        /// What the loop reported, in order.
        var events: [RadioEvent] { box.events }

        /// The peer's dial target.
        static func target() throws -> DialTarget {
            DialTarget(address: try #require(BluetoothAddress(peerAddress)), isRandom: true)
        }

        /// A peer's advert.
        static func advert(_ seed: Int = 7) -> AdvertPayload {
            AdvertPayload(capabilities: 0xFFF, nodeId: fixtureNodeId(seed), digestCue: 9, psm: UnixSockets.psm)
        }

        /// A peer's advert as its GATT characteristic serves it: the digest cue at 0.
        static func gattAdvert(_ seed: Int = 7) -> AdvertPayload {
            var advert = advert(seed)
            advert.digestCue = 0
            return advert
        }

        /// A device that advertises the `0xFE30` UUID and no service data, as an iPhone does.
        static func uuidOnlyDevice(address: String = peerAddress, rssi: Int16 = -55) -> DBusValue {
            FakeBlueZ.device(address: address, rssi: rssi, advert: nil, uuids: ["0000FE30-0000-1000-8000-00805F9B34FB"])
        }

        /// Turns the loop and the fake until `condition` holds, or two seconds pass.
        @discardableResult
        func settle(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool) -> Bool {
            let deadline = Monotonic.milliseconds() + 2000
            while !condition() {
                guard Monotonic.milliseconds() < deadline else {
                    Issue.record(comment ?? "never settled", sourceLocation: sourceLocation)
                    return false
                }
                loop.iterate(maximumWaitMilliseconds: 1)
                fake.iterate(waitMilliseconds: 1)
            }
            return true
        }

        /// Turns both a few times, for a test that checks something does not happen.
        func turn(_ times: Int = 30) {
            for _ in 0..<times {
                loop.iterate(maximumWaitMilliseconds: 1)
                fake.iterate(waitMilliseconds: 1)
            }
        }

        func post(_ command: RadioCommand) {
            mailbox.post(command)
        }

        /// Connects and starts, and waits for the listener.
        func start() {
            loop.connect(now: Monotonic.milliseconds())
            post(.start)
            settle("never listened") { events.contains(.listening(psm: UnixSockets.psm)) }
        }

        /// Starts and advertises `payload`, and waits for BlueZ to hold it.
        func startAdvertising(_ payload: AdvertPayload = LoopRig.ours) {
            start()
            post(.advertise(payload))
            settle("never advertised") { fake.registered.count == 1 }
        }

        /// Sights the peer and dials it, and waits for the dial to land on `listener`.
        func dialPeer(_ listener: RemoteListener) throws -> (ChannelID, RemoteEnd) {
            try fake.add(device: Self.peerPath, FakeBlueZ.device(address: Self.peerAddress, advert: Self.advert()))
            settle { events.contains { if case .sighted = $0 { true } else { false } } }
            let id = mailbox.nextChannel()
            post(.dial(id, RadioAddress(Self.peerPath), psm: UnixSockets.psm))
            settle("never connected") { events.contains(.connected(id)) }
            return (id, try #require(listener.accept()))
        }

        /// The channel of the last `accepted` event.
        var lastAccepted: ChannelID? {
            events.compactMap { if case .accepted(let id) = $0 { id } else { nil } }.last
        }

        /// Everything received on `id`, joined.
        func received(on id: ChannelID) -> [UInt8] {
            events.flatMap { event -> [UInt8] in
                if case .received(id, let bytes) = event { bytes } else { [] }
            }
        }
    }
#endif
