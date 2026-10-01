#if os(iOS) && DEBUG
    import Foundation
    import KnitControl
    import KnitMesh
    import Network

    /// A debug build's control channel: JSON lines over TCP. It always listens on the phone's own loopback, which a
    /// computer reaches over USB through usbmuxd (`iproxy 5648:5648`) and nothing off the phone can reach. While
    /// ``WiFiGate`` finds the phone on a network pinned over USB, it also listens on the phone's Wi-Fi address and lets
    /// in only addresses from the pinned subnet. A release build has no listener at all.
    ///
    /// Each connection hears the greeting, then one reply per line it sends, in order, and every line
    /// ``broadcast(_:)`` sends while it is open. iOS shuts an app's sockets when it suspends it (runningboardd logs
    /// "Shutdown sockets") and tells the listener nothing, so it still looks ready. ``start()`` therefore runs at every
    /// foreground and makes each listener anew; connections already open are left as they are.
    internal final class BridgeListener: @unchecked Sendable {
        // @unchecked: the listeners, the Wi-Fi target and `connections` are touched on `queue` only, and the rest is
        // immutable.
        /// What a line gets back, and whether the connection closes after it.
        typealias Answer = @Sendable (String, BridgeOrigin) async -> (line: String, closes: Bool)

        /// Where the Wi-Fi listener listens, and which far ends it lets in.
        private struct WiFiTarget {
            let address: String
            let admits: @Sendable (String) -> Bool
        }

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
        private var listeners: [BridgeOrigin: NWListener] = [:]
        private var ready: Set<BridgeOrigin> = []
        private var attempts: [BridgeOrigin: Int] = [:]
        private var wifi: WiFiTarget?
        private var connections: [ObjectIdentifier: (connection: NWConnection, origin: BridgeOrigin)] = [:]

        /// A listener that greets each connection with `greeting` and hands each line it sends to `answer`.
        init(log: any KnitLog, greeting: @escaping @Sendable () -> String, answer: @escaping Answer) {
            self.log = log
            self.greeting = greeting
            self.answer = answer
        }

        /// Listens anew, in place of the listeners from before.
        func start() {
            queue.async { [self] in
                relisten(.usb)
                if wifi != nil {
                    relisten(.wifi)
                }
            }
        }

        /// Listens on Wi-Fi at `address` too, letting in only the far ends `admits` passes. Given the address it already
        /// listens on, it keeps the listener and its connections and changes only who gets in next.
        func openWiFi(on address: String, admitting admits: @escaping @Sendable (String) -> Bool) {
            queue.async { [self] in
                let moved = wifi?.address != address
                wifi = WiFiTarget(address: address, admits: admits)
                if moved {
                    drop(.wifi)
                }
                if moved || listeners[.wifi] == nil {
                    relisten(.wifi)
                }
            }
        }

        /// Stops listening on Wi-Fi and closes every connection that came that way.
        func closeWiFi(_ why: String) {
            queue.async { [self] in
                guard wifi != nil else {
                    return
                }
                log.log(.debug, "bridge stopped listening on Wi-Fi: \(why)")
                wifi = nil
                drop(.wifi)
            }
        }

        /// The address the bridge listens on over Wi-Fi, if it does.
        func wifiAddress() async -> String? {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: ready.contains(.wifi) ? wifi?.address : nil)
                }
            }
        }

        /// Sends `line` to every open connection.
        func broadcast(_ line: String) {
            queue.async { [self] in
                for open in connections.values {
                    send(line, on: open.connection)
                }
            }
        }

        private func relisten(_ origin: BridgeOrigin) {
            listeners[origin]?.cancel()
            listeners[origin] = nil
            ready.remove(origin)
            attempts[origin] = 0
            listen(origin)
        }

        private func listen(_ origin: BridgeOrigin) {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            do {
                let made: NWListener
                switch origin {
                case .usb:
                    parameters.requiredInterfaceType = .loopback
                    made = try NWListener(using: parameters, on: Self.port)
                case .wifi:
                    guard let wifi, let address = IPv4Address(wifi.address) else {
                        return
                    }
                    // Bound to this one address, so it never answers on another interface or on IPv6.
                    parameters.requiredInterfaceType = .wifi
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: Self.port)
                    made = try NWListener(using: parameters)
                }
                made.stateUpdateHandler = { [self] state in changed(made, origin, to: state) }
                made.newConnectionHandler = { [self] connection in serve(connection, from: origin) }
                made.start(queue: queue)
                listeners[origin] = made
            } catch {
                log.log(.warning, "bridge could not listen on \(origin): \(error)")
                retry(origin)
            }
        }

        private func retry(_ origin: BridgeOrigin) {
            let tried = attempts[origin, default: 0]
            guard tried < Self.retries else {
                return
            }
            attempts[origin] = tried + 1
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                if listeners[origin] == nil, origin == .usb || wifi != nil {
                    listen(origin)
                }
            }
        }

        /// Closes the listener for `origin` and every connection that came through it.
        private func drop(_ origin: BridgeOrigin) {
            listeners[origin]?.cancel()
            listeners[origin] = nil
            ready.remove(origin)
            for open in connections.values where open.origin == origin {
                open.connection.cancel()
            }
        }

        private func changed(_ made: NWListener, _ origin: BridgeOrigin, to state: NWListener.State) {
            guard made === listeners[origin] else {
                return
            }
            switch state {
            case .ready:
                ready.insert(origin)
                let place = origin == .usb ? "\(Self.port)" : "Wi-Fi at \(wifi?.address ?? "an unknown address")"
                log.log(.debug, "bridge listening on \(place)")
            case .failed(let error):
                log.log(.debug, "bridge listener on \(origin) failed: \(error)")
                made.cancel()
                listeners[origin] = nil
                ready.remove(origin)
                retry(origin)
            default:
                break
            }
        }

        private func serve(_ connection: NWConnection, from origin: BridgeOrigin) {
            if origin == .wifi {
                guard let wifi, let remote = Self.ipv4(of: connection.endpoint), wifi.admits(remote) else {
                    log.log(.debug, "bridge refused \(connection.endpoint) on Wi-Fi")
                    connection.cancel()
                    return
                }
            }
            let key = ObjectIdentifier(connection)
            log.log(.debug, "bridge connection from \(connection.endpoint)")
            connections[key] = (connection, origin)
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
            receive(on: connection, from: origin, pending: [])
        }

        /// The dotted IPv4 address a connection came from, if it came over IPv4.
        private static func ipv4(of endpoint: NWEndpoint) -> String? {
            guard case .hostPort(host: .ipv4(let address), port: _) = endpoint else {
                return nil
            }
            return address.rawValue.map(String.init).joined(separator: ".")
        }

        private func send(_ line: String, on connection: NWConnection) {
            connection.send(content: Data((line + "\n").utf8), completion: .idempotent)
        }

        /// Reads lines until the far side closes, answering each in order: the next read waits for the last answer.
        private func receive(on connection: NWConnection, from origin: BridgeOrigin, pending: [UInt8]) {
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
                        let reply = await answer(line, origin)
                        send(reply.line, on: connection)
                        if reply.closes {
                            connection.cancel()
                            return
                        }
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        receive(on: connection, from: origin, pending: rest)
                    }
                }
            }
        }
    }
#endif
