#if os(Linux)
    import Glibc

    /// The check `knit-peer` makes before it does anything else: the adapter is there, with the address it must have.
    /// If not, the peer exits rather than wait, since the wrong adapter could be the maintainer's own.
    ///
    /// It blocks for one round trip to BlueZ, which is fine before the radio starts and nowhere else.
    public enum AdapterProbe {
        /// What BlueZ said about the adapter.
        public struct Status: Equatable, Sendable {
            /// Whether it is powered.
            public let powered: Bool
        }

        /// Why the probe failed.
        public enum Failure: Error, Equatable, Sendable {
            /// The system bus could not be reached.
            case bus(String)
            /// BlueZ did not answer: bluetoothd is not running.
            case bluez(String)
            /// The adapter is absent or has another address.
            case refused(AdapterSelection.Refusal)
        }

        /// How long each wait for BlueZ's answer lasts.
        private static let pollMilliseconds: Int32 = 50

        /// Checks `selection` against what BlueZ reports.
        public static func check(_ selection: AdapterSelection, timeoutMilliseconds: Int64 = 5000) throws(Failure) -> Status {
            try check(selection, on: .system, waiting: timeoutMilliseconds)
        }

        static func check(_ selection: AdapterSelection, on address: BusConnection.Address, waiting: Int64) throws(Failure) -> Status {
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
            let object = BlueZ.objects(from: objects).first { $0.path == selection.path }
            let adapter = object?.interfaces.first { $0.name == BlueZ.adapterInterface }
            do {
                try selection.check(reportedAddress: adapter?.properties["Address"]?.text)
            } catch {
                throw .refused(error)
            }
            return Status(powered: adapter?.properties["Powered"]?.bool ?? false)
        }
    }
#endif
