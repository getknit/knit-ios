#if os(Linux)
    import Glibc

    /// The check `knit-peer` makes before it does anything else: some adapter has the address it was given, and which
    /// `hciN` that is this boot. If none has, the peer exits rather than wait, since another could be the maintainer's own.
    ///
    /// It blocks for one round trip to BlueZ, which is fine before the radio starts and nowhere else.
    public enum AdapterProbe {
        /// What BlueZ said about the adapter.
        public struct Status: Equatable, Sendable {
            /// The adapter, under the name the kernel gave it.
            public let adapter: AdapterSelection
            /// Whether it is powered.
            public let powered: Bool
        }

        /// Why the probe failed.
        public enum Failure: Error, Equatable, Sendable {
            /// The system bus could not be reached.
            case bus(String)
            /// BlueZ did not answer: bluetoothd is not running.
            case bluez(String)
            /// No adapter has the address, or it is the maintainer's and not shared.
            case refused(AdapterSelection.Refusal)
        }

        /// How long each wait for BlueZ's answer lasts.
        private static let pollMilliseconds: Int32 = 50

        /// Finds the adapter with `address` among those BlueZ lists.
        public static func select(address: String, shared: Bool, timeoutMilliseconds: Int64 = 5000) throws(Failure) -> Status {
            try select(address: address, shared: shared, on: .system, waiting: timeoutMilliseconds)
        }

        static func select(address: String, shared: Bool, on bus: BusConnection.Address, waiting: Int64) throws(Failure) -> Status {
            do {
                // Refuse the maintainer's adapter before asking BlueZ anything.
                _ = try AdapterSelection.admit(address, shared: shared)
            } catch {
                throw .refused(error)
            }
            let objects = try managedObjects(on: bus, waiting: waiting)
            let selection: AdapterSelection
            do {
                selection = try AdapterSelection.find(address, shared: shared, among: objects)
            } catch {
                throw .refused(error)
            }
            let adapter = objects.first { $0.path == selection.path }?.interfaces.first { $0.name == BlueZ.adapterInterface }
            return Status(adapter: selection, powered: adapter?.properties["Powered"]?.bool ?? false)
        }

        /// `GetManagedObjects`' answer, one blocking round trip.
        private static func managedObjects(
            on address: BusConnection.Address, waiting: Int64
        ) throws(Failure) -> [(path: String, interfaces: [(name: String, properties: DBusValue)])] {
            let bus: BusConnection
            do {
                bus = try BusConnection(address)
            } catch {
                throw .bus("\(error)")
            }
            guard
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: "/", interface: BlueZ.objectManager, member: "GetManagedObjects")
            else {
                throw .bluez("cannot ask")
            }
            var answer: Result<BusMessage, BusError>?
            let start = Monotonic.milliseconds()
            bus.call(call, now: start, timeoutMilliseconds: waiting) { answer = $0 }
            while answer == nil {
                var ready = pollfd(
                    fd: bus.fileDescriptor ?? -1, events: Int16(POLLIN) | (bus.wantsToWrite ? Int16(POLLOUT) : 0), revents: 0)
                _ = poll(&ready, 1, pollMilliseconds)
                bus.pump(now: Monotonic.milliseconds())
            }
            guard case .success(let reply) = answer, let objects = (try? reply.arguments())?.first else {
                throw .bluez("no answer to GetManagedObjects: \(answer.map { "\($0)" } ?? "")")
            }
            return BlueZ.objects(from: objects)
        }
    }
#endif
