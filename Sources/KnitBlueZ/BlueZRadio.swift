#if os(Linux)
    import Foundation
    public import KnitMesh
    public import KnitWire

    /// The BlueZ ``Radio`` for the headless Linux peer: an advert through `LEAdvertisingManager1`, a scan through
    /// `Adapter1`, and LE credit-based L2CAP sockets, all on one adapter, never the maintainer's unless it is shared
    /// (`.agents/context/linux-peer.md`). It decides nothing: who links to whom is the ``LinkManager``'s.
    ///
    /// Everything runs on the radio's own thread, in a ``BlueZLoop``; these methods only post to it. The thread
    /// lives until ``shutdown()``.
    public final class BlueZRadio: Radio {
        /// How the radio runs.
        public struct Configuration: Sendable {
            /// The adapter, checked against its expected address before anything is registered or opened.
            public var adapter: AdapterSelection
            /// How the peer shows itself.
            public var profile: RadioProfile
            /// Whether the radio reads the GATT payload of a peer that advertises only the `0xFE30` UUID, and so
            /// can find an iPhone. The `ios` profile does, as an iPhone does, and the `android` profile does not
            /// unless told to, as Android before knit-next `713b29d6` does not; `knit-peer scan` reads them whatever it
            /// advertises, to list iPhones too. The advert's `FLAG_DIALS_GATT_PEERS` follows it.
            public var readsGattPayloads: Bool
            /// Whether the `ios` profile's GATT application serves the payload characteristic. A test switch: without
            /// it the service holds the doorbell alone, and a reader files the peer as a stranger, so it never sights
            /// it (``GattApplication``).
            public var servesGattPayload = true
            /// Nodes whose adverts and GATT payloads the radio never reports, a test switch. The link manager then
            /// never dials them, and admits their dials as it admits a dialer it never sighted, which is how an
            /// interop run keeps the peer from dialing a phone whose own dial is under test (`--never-sight`).
            public var neverSighted: Set<NodeId> = []
            /// Where channels come from.
            public var sockets: any SocketProvider
            /// Where D-Bus objects of this process live.
            public var objectRoot: String
            /// Where the radio logs.
            public var log: any KnitLog
            var bus = BusConnection.Address.system

            /// A radio on `adapter`'s L2CAP sockets, on the system bus.
            public init(adapter: AdapterSelection, profile: RadioProfile, objectRoot: String = "/app/getknit/peer", log: any KnitLog) {
                self.adapter = adapter
                self.profile = profile
                readsGattPayloads = profile.readsGattPayloads
                sockets = L2CAPSockets(adapter: adapter.address)
                self.objectRoot = objectRoot
                self.log = log
            }

            var loop: BlueZLoop.Configuration {
                var configuration = BlueZLoop.Configuration(
                    bus: bus, adapter: adapter, profile: profile, sockets: sockets, objectRoot: objectRoot, log: log)
                configuration.readsGattPayloads = readsGattPayloads
                configuration.servesGattPayload = servesGattPayload
                configuration.neverSighted = neverSighted
                return configuration
            }
        }

        /// Only the `android` profile's advert carries service data.
        public let advertisesServiceData: Bool
        /// Whether the radio reads the GATT payload of a peer that advertises only the `0xFE30` UUID
        /// (``Configuration/readsGattPayloads``), so the advert says so and such a peer waits for us to dial it.
        public let dialsGattPeers: Bool
        /// Whether the radio serves the doorbell (``RadioProfile/servesDoorbell``): the `ios` profile only.
        public let servesDoorbell: Bool
        public let events: AsyncStream<RadioEvent>
        private let mailbox = Mailbox()
        private let finished: AsyncStream<Void>

        /// Starts the radio's thread. Nothing touches BlueZ or the adapter until ``start()``, except reading which
        /// objects exist.
        public init(configuration: Configuration) {
            advertisesServiceData = configuration.profile.advertisesServiceData
            dialsGattPeers = configuration.readsGattPayloads
            servesDoorbell = configuration.profile.servesDoorbell
            let (stream, continuation) = AsyncStream<RadioEvent>.makeStream()
            let (ended, done) = AsyncStream<Void>.makeStream()
            events = stream
            finished = ended
            let thread = Thread { [mailbox] in
                let loop = BlueZLoop(configuration: configuration.loop, mailbox: mailbox) { continuation.yield($0) }
                loop.run()
                continuation.finish()
                done.finish()
            }
            thread.name = "knit-bluez"
            thread.start()
        }

        deinit {
            mailbox.post(.shutdown)
        }

        public func start() {
            mailbox.post(.start)
        }

        public func stop() {
            mailbox.post(.stop)
        }

        public func advertise(_ payload: AdvertPayload) {
            mailbox.post(.advertise(payload))
        }

        public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
            let id = mailbox.nextChannel()
            mailbox.post(.dial(id, address, psm: psm))
            return id
        }

        public func write(_ bytes: [UInt8], to channel: ChannelID) {
            mailbox.post(.write(channel, bytes))
        }

        public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
            mailbox.post(.writeDigest(channel, record))
        }

        /// The loop reports each FILE record's last byte out of the channel's queue, so a file never fills it.
        public var reportsFileWrites: Bool { true }

        public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
            mailbox.post(.writeFileRecord(channel, record))
        }

        public func close(_ channel: ChannelID) {
            mailbox.post(.close(channel))
        }

        public func ring(_ channel: ChannelID) {
            mailbox.post(.ring(channel))
        }

        public func heardHello(from node: NodeId, on channel: ChannelID) {
            mailbox.post(.heardHello(channel, node))
        }

        /// Stops, withdraws the advert and the GATT application from BlueZ, closes the bus, and waits for the
        /// radio's thread to end. The events stream finishes with it.
        public func shutdown() async {
            mailbox.post(.shutdown)
            for await _ in finished {
                continue
            }
        }
    }
#endif
