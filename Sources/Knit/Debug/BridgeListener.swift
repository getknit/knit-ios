#if os(iOS) && DEBUG
    import Foundation
    import KnitMesh
    import Network

    /// A debug build's control channel: JSON lines over TCP on the phone's own loopback, which a computer reaches over
    /// USB through usbmuxd (`iproxy 5648:5648`). Nothing off the phone can reach a loopback listener, and a release
    /// build has no listener at all.
    ///
    /// Each connection hears the greeting, then one reply per line it sends, in order, and every line
    /// ``broadcast(_:)`` sends while it is open. iOS shuts an app's sockets when it suspends it (runningboardd logs
    /// "Shutdown sockets") and tells the listener nothing, so it still looks ready. ``start()`` therefore runs at every
    /// foreground and makes a new listener each time; connections already open are left as they are.
    internal final class BridgeListener: @unchecked Sendable {
        // @unchecked: `listener` and `connections` are touched on `queue` only, and the rest is immutable.
        /// What a line gets back, and whether the connection closes after it.
        typealias Answer = @Sendable (String) async -> (line: String, closes: Bool)

        static let port: NWEndpoint.Port = 5648
        private static let readSize = 65_536
        private static let newline = UInt8(ascii: "\n")
        /// How often a listener that failed is made again, a second apart, before the bridge gives up until the next
        /// foreground: the port can still be held for a moment by the listener just cancelled.
        private static let retries = 5

        private let queue = DispatchQueue(label: "app.getknit.knit.bridge")
        private let log: any KnitLog
        private let greeting: @Sendable () -> String
        private let answer: Answer
        private var listener: NWListener?
        private var attempts = 0
        private var connections: [ObjectIdentifier: NWConnection] = [:]

        /// A listener that greets each connection with `greeting` and hands each line it sends to `answer`.
        init(log: any KnitLog, greeting: @escaping @Sendable () -> String, answer: @escaping Answer) {
            self.log = log
            self.greeting = greeting
            self.answer = answer
        }

        /// Listens anew, in place of any listener from before.
        func start() {
            queue.async { [self] in
                listener?.cancel()
                listener = nil
                attempts = 0
                listen()
            }
        }

        private func listen() {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            do {
                let made = try NWListener(using: parameters, on: Self.port)
                made.stateUpdateHandler = { [self] state in changed(made, to: state) }
                made.newConnectionHandler = { [self] connection in serve(connection) }
                made.start(queue: queue)
                listener = made
            } catch {
                log.log(.warning, "bridge could not listen: \(error)")
                retry()
            }
        }

        private func retry() {
            guard attempts < Self.retries else {
                return
            }
            attempts += 1
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                if listener == nil {
                    listen()
                }
            }
        }

        /// Sends `line` to every open connection.
        func broadcast(_ line: String) {
            queue.async { [self] in
                for connection in connections.values {
                    send(line, on: connection)
                }
            }
        }

        private func changed(_ made: NWListener, to state: NWListener.State) {
            switch state {
            case .ready:
                log.log(.debug, "bridge listening on \(Self.port)")
            case .failed(let error):
                log.log(.debug, "bridge listener failed: \(error)")
                made.cancel()
                if made === listener {
                    listener = nil
                    retry()
                }
            default:
                break
            }
        }

        private func serve(_ connection: NWConnection) {
            let key = ObjectIdentifier(connection)
            log.log(.debug, "bridge connection from \(connection.endpoint)")
            connections[key] = connection
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .failed, .cancelled:
                    connections[key] = nil
                default:
                    break
                }
            }
            connection.start(queue: queue)
            send(greeting(), on: connection)
            receive(on: connection, pending: [])
        }

        private func send(_ line: String, on connection: NWConnection) {
            connection.send(content: Data((line + "\n").utf8), completion: .idempotent)
        }

        /// Reads lines until the far side closes, answering each in order: the next read waits for the last answer.
        private func receive(on connection: NWConnection, pending: [UInt8]) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [self] data, _, isComplete, error in
                var bytes = pending + (data.map { [UInt8]($0) } ?? [])
                var lines: [String] = []
                while let end = bytes.firstIndex(of: Self.newline) {
                    lines.append(String(bytes: bytes[..<end], encoding: .utf8) ?? "")
                    bytes.removeSubrange(...end)
                }
                let rest = bytes
                Task { [self] in
                    for line in lines {
                        let reply = await answer(line)
                        send(reply.line, on: connection)
                        if reply.closes {
                            connection.cancel()
                            return
                        }
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        receive(on: connection, pending: rest)
                    }
                }
            }
        }
    }
#endif
