// Every file in KnitSpoolNet compiles into a debug build alone while the spool plane does (ADR 2026-11.adrq): a store build
// reaches none of it.
#if DEBUG
    public import KnitMesh
    public import KnitWire

    /// What opens a relay's WebSocket for ``Mesh`` (ADR 2026-11.adrq, P5): `URLSessionWebSocketTask` on Apple platforms, through
    /// one ephemeral `URLSession` per factory. Elsewhere it opens nothing: every dial fails as ``SpoolSocketFault/unreachable``,
    /// so no FoundationNetworking path is ever reached.
    ///
    /// Each dial first runs ``SpoolDialCheck`` on ``AcceptedSpoolURL/socketURLText``, the one place the plane's address leaves
    /// as text, and an address the check refuses fails as unreachable before any socket opens, with one constant line in the
    /// log (``refusedLine``) so the refusal reads apart from a relay that did not answer. The socket keeps every rule of
    /// ``SpoolSocket``: pulled reads, a message past ``SpoolRecordLayer/maxInboundRecord`` refused before it is buffered, a
    /// text message reported by its size, one send at a time, a close's reason dropped, and failures as fault words with no
    /// Foundation error, user info or URL in them.
    public final class URLSessionSpoolSocketFactory: SpoolSocketFactory {
        /// The line the factory logs as it is made. `scripts/check.sh release` fails a store build that holds it: it would
        /// mean the spool's sockets ship before the plane is approved.
        static let marker = "spool sockets are on in this debug build"
        /// The line a dial the address check refused logs: constant, so it carries no address, host or handle.
        static let refusedLine = "spool dial refused by the address check"

        /// Whether this build dials `ws://`: a debug build's alone (C-7.1-2). The flag is the compile-time one, so the rule
        /// holds unchanged once the module ships.
        static var dialsCleartext: Bool {
            #if DEBUG
                true
            #else
                false
            #endif
        }

        #if canImport(Darwin)
            private let dialer = SpoolSessionDialer()
        #endif
        private let log: any KnitLog

        /// A factory whose sockets log nothing; `log` takes the line that says the factory exists, and one constant line per
        /// dial the address check refuses.
        public init(log: any KnitLog) {
            self.log = log
            log.log(.info, Self.marker)
        }

        /// Opens a socket to `url`, or says why not in a fault word.
        public func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
            guard let target = SpoolDialCheck.target(for: url, cleartext: Self.dialsCleartext) else {
                log.log(.warning, Self.refusedLine)
                return .failed(SpoolDialFailure(.unreachable))
            }
            #if canImport(Darwin)
                return await dialer.open(target)
            #else
                // FoundationNetworking's WebSocket rides the system libcurl, which may be built without `ws` or `wss`
                // (`.agents/context/toolchain.md`); this port tests the plane on Linux through a test socket instead.
                _ = target
                return .failed(SpoolDialFailure(.unreachable))
            #endif
        }
    }
#endif
