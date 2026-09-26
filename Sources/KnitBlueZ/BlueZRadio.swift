#if os(Linux)
    import Foundation
    public import KnitMesh
    public import KnitWire

    /// The BlueZ ``Radio`` for the headless Linux peer: an advert through `LEAdvertisingManager1`, a scan through
    /// `Adapter1`, and LE credit-based L2CAP sockets, all on one adapter that is never `hci0`
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
                sockets = L2CAPSockets(adapter: adapter.address)
                self.objectRoot = objectRoot
                self.log = log
            }

            var loop: BlueZLoop.Configuration {
                BlueZLoop.Configuration(bus: bus, adapter: adapter, profile: profile, sockets: sockets, objectRoot: objectRoot, log: log)
            }
        }

        /// Only the `android` profile's advert carries service data.
        public let advertisesServiceData: Bool
        /// Reading a GATT payload from a peer that advertises only the `0xFE30` UUID is not built yet, so the advert
        /// never claims it and such a peer knows to dial us.
        public let dialsGattPeers = false
        public let events: AsyncStream<RadioEvent>
        private let mailbox = Mailbox()
        private let finished: AsyncStream<Void>

        /// Starts the radio's thread. Nothing touches BlueZ or the adapter until ``start()``, except reading which
        /// objects exist.
        public init(configuration: Configuration) {
            advertisesServiceData = configuration.profile == .android
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

        public func close(_ channel: ChannelID) {
            mailbox.post(.close(channel))
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
