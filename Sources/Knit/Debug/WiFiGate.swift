#if os(iOS) && DEBUG
    import Foundation
    import KnitControl
    import KnitMesh
    import Network

    /// Decides whether a debug build's bridge listens on Wi-Fi: only while the phone is on a network pinned over USB
    /// (``RouterPin``), so on any other network, a café's or a hotspot's, nothing on Wi-Fi can reach it. It watches the
    /// Wi-Fi path, keeps the pins in the app's defaults, and answers ``WiFiCommand``.
    ///
    /// The router's values come from the path and the interface's own address, so iOS asks for no permission: the SSID
    /// would need the Access Wi-Fi Information entitlement and precise location. Listening for incoming TCP needs no
    /// Local Network permission either (Apple's TN3179); advertising over Bonjour or dialing out would.
    @MainActor
    internal final class WiFiGate {
        private static let pinsKey = "debug.bridge.routerPins"

        private let log: any KnitLog
        private let defaults: UserDefaults
        private weak var listener: BridgeListener?
        private var monitor: NWPathMonitor?
        private var pins: RouterPins
        private var facts: RouterFacts?

        /// A gate with the pins saved in `defaults`, none if they do not load.
        init(log: any KnitLog, defaults: UserDefaults) {
            self.log = log
            self.defaults = defaults
            guard let saved = defaults.data(forKey: Self.pinsKey) else {
                pins = RouterPins()
                return
            }
            do {
                pins = try JSONDecoder().decode(RouterPins.self, from: saved)
            } catch {
                log.log(.warning, "bridge could not read its Wi-Fi pins, so it pins none: \(error)")
                pins = RouterPins()
            }
        }

        /// The listener this gate opens and closes on Wi-Fi.
        func attach(_ listener: BridgeListener) {
            self.listener = listener
        }

        /// Reads the Wi-Fi path afresh and opens or closes the listener to match; called at launch and at every
        /// foreground, after the listener makes its sockets anew. The first call starts watching the path.
        func refresh() {
            guard let monitor else {
                let made = NWPathMonitor(requiredInterfaceType: .wifi)
                made.pathUpdateHandler = { [weak self] path in
                    let read = WiFiPath.facts(of: path)
                    MainActor.assumeIsolated { self?.changed(to: read) }
                }
                made.start(queue: .main)
                monitor = made
                return
            }
            changed(to: WiFiPath.facts(of: monitor.currentPath))
        }

        /// Answers `command`, which came from `origin`, on the network the phone is on now.
        func answer(_ command: WiFiCommand, from origin: BridgeOrigin) async -> String {
            let listening = await listener?.wifiAddress()
            if let monitor {
                facts = WiFiPath.facts(of: monitor.currentPath)
            }
            var next = pins
            let line = command.answer(from: origin, facts: facts, pins: &next, listening: listening)
            if next != pins {
                pins = next
                save()
            }
            decide()
            return line
        }

        private func changed(to facts: RouterFacts?) {
            self.facts = facts
            decide()
        }

        private func decide() {
            guard let facts else {
                listener?.closeWiFi("not on Wi-Fi")
                return
            }
            guard let pin = pins.match(facts) else {
                listener?.closeWiFi("\(facts.gateway ?? "a network without a gateway") is not pinned")
                return
            }
            listener?.openWiFi(on: facts.address) { remote in pin.admits(remote) }
        }

        private func save() {
            do {
                defaults.set(try JSONEncoder().encode(pins), forKey: Self.pinsKey)
            } catch {
                log.log(.warning, "bridge could not save its Wi-Fi pins: \(error)")
            }
        }
    }

    /// What a Wi-Fi path says about the network: the interface's IPv4 address and prefix length, the IPv4 gateway, and
    /// the IPv6 router's link-local address.
    internal enum WiFiPath {
        /// The facts of `path`, or nil when it is not a working Wi-Fi path with an IPv4 address.
        static func facts(of path: NWPath) -> RouterFacts? {
            guard path.status == .satisfied, let wifi = path.availableInterfaces.first(where: { $0.type == .wifi }),
                let own = ipv4(on: wifi.name)
            else {
                return nil
            }
            var gateway: String?
            var router6: String?
            for case .hostPort(host: let host, port: _) in path.gateways {
                switch host {
                case .ipv4(let found):
                    gateway = gateway ?? dotted(found.rawValue)
                case .ipv6(let found) where found.isLinkLocal:
                    router6 = router6 ?? "\(found)"
                default:
                    break
                }
            }
            return RouterFacts(
                interface: wifi.name, address: own.address, prefixLength: own.prefixLength, gateway: gateway, router6: router6)
        }

        /// The IPv4 address and prefix length on the interface named `name`. The name comes from the path, since the
        /// Wi-Fi interface is not always `en0` (TN3179).
        private static func ipv4(on name: String) -> (address: String, prefixLength: Int)? {
            var first: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&first) == 0, let first else {
                return nil
            }
            defer { freeifaddrs(first) }
            for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let item = entry.pointee
                guard let address = item.ifa_addr, let mask = item.ifa_netmask, address.pointee.sa_family == sa_family_t(AF_INET),
                    String(cString: item.ifa_name) == name
                else {
                    continue
                }
                // Both in network order: the bytes read out as written, and a mask's bit count is the same either way.
                let bytes = withUnsafeBytes(of: inet(address).s_addr) { Data($0) }
                return (dotted(bytes), inet(mask).s_addr.nonzeroBitCount)
            }
            return nil
        }

        private static func inet(_ address: UnsafeMutablePointer<sockaddr>) -> in_addr {
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }

        /// Four bytes in network order as a dotted address.
        private static func dotted(_ bytes: Data) -> String {
            bytes.map(String.init).joined(separator: ".")
        }
    }
#endif
