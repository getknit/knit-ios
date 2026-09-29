#if os(Linux)
    import KnitMesh
    import KnitWire

    /// The loop's side of BlueZ: finding and checking the adapter, following its devices, and scanning.
    extension BlueZLoop {
        // MARK: Connecting

        func connect(now: Int64) {
            let connection: BusConnection
            do {
                connection = try BusConnection(configuration.bus)
            } catch {
                log.log(.warning, "bluez bus unreachable: \(error)")
                report(.unsupported)
                reconnectAt = now + configuration.retryDelayMilliseconds
                return
            }
            bus = connection
            connection.onDisconnect = { [weak self] in self?.busLost() }
            subscribe(connection)
            if case .system = configuration.bus {
                askForBlueZOwner(now: now)
            }
            takeInventory(now: now)
        }

        private func busLost() {
            log.log(.warning, "bluez bus connection closed")
            forgetBlueZ()
            bus = nil
            report(.off)
            reconnectAt = Monotonic.milliseconds() + configuration.retryDelayMilliseconds
        }

        /// BlueZ, or the adapter, or the bus went away, and with it everything we had registered.
        private func forgetBlueZ() {
            adapterPresent = false
            doorbells.removeAll()
            ringsWaiting.removeAll()
            activeAdvert = nil
            pendingAdvert = nil
            gattRegistered = false
            bringDown()
        }

        /// Signals about this adapter and its devices only: another adapter's never reach this process.
        private func subscribe(_ connection: BusConnection) {
            let adapter = configuration.adapter.path
            let fromBlueZ = "type='signal',sender='\(BlueZ.service)'"
            for member in ["InterfacesAdded", "InterfacesRemoved"] {
                for path in [adapter, adapter + "/"] {
                    connection.addMatch(fromBlueZ + ",interface='\(BlueZ.objectManager)',member='\(member)',arg0path='\(path)'")
                }
            }
            connection.addMatch(fromBlueZ + ",interface='\(BlueZ.properties)',member='PropertiesChanged',path_namespace='\(adapter)'")
            connection.addMatch(
                "type='signal',sender='\(BlueZ.bus)',interface='\(BlueZ.bus)',member='NameOwnerChanged',arg0='\(BlueZ.service)'")
            connection.onSignal(interface: BlueZ.objectManager, member: "InterfacesAdded") { [weak self] in self?.interfacesAdded($0) }
            connection.onSignal(interface: BlueZ.objectManager, member: "InterfacesRemoved") { [weak self] in self?.interfacesRemoved($0) }
            connection.onSignal(interface: BlueZ.properties, member: "PropertiesChanged") { [weak self] in self?.propertiesChanged($0) }
            connection.onSignal(interface: BlueZ.bus, member: "NameOwnerChanged") { [weak self] in self?.nameOwnerChanged($0) }
        }

        private func askForBlueZOwner(now: Int64) {
            guard
                let call = BusMessage.methodCall(destination: BlueZ.bus, path: BlueZ.busPath, interface: BlueZ.bus, member: "GetNameOwner"),
                (try? call.append(.string(BlueZ.service))) != nil
            else {
                return
            }
            bus?.call(call, now: now) { [weak self] result in
                if case .success(let reply) = result, let owner = (try? reply.arguments())?.first?.text {
                    self?.bluezOwner = owner
                }
            }
        }

        /// Reads every BlueZ object once, to find the adapter and the devices it already knows. Those devices are
        /// kept only as dial targets: their service data and signal strength may be old, so they are not sighted.
        func takeInventory(now: Int64) {
            guard
                let call = BusMessage.methodCall(
                    destination: BlueZ.service,
                    path: "/",
                    interface: BlueZ.objectManager,
                    member: "GetManagedObjects"
                )
            else {
                return
            }
            bus?.call(call, now: now) { [weak self] result in
                self?.tookInventory(result, now: Monotonic.milliseconds())
            }
        }

        private func tookInventory(_ result: Result<BusMessage, BusError>, now: Int64) {
            guard case .success(let reply) = result, let objects = (try? reply.arguments())?.first else {
                log.log(.warning, "bluez did not answer GetManagedObjects; is bluetoothd running?")
                report(.unsupported)
                return
            }
            let owned = BlueZ.objects(from: objects).filter { configuration.adapter.owns($0.path) }
            let adapter = owned.first { $0.path == configuration.adapter.path }?.interfaces.first { $0.name == BlueZ.adapterInterface }
            do {
                try configuration.adapter.check(reportedAddress: adapter?.properties["Address"]?.text)
            } catch {
                log.log(.warning, "bluez refused the adapter: \(error)")
                adapterRefused = true
                bringDown()
                report(.unsupported)
                return
            }
            adapterPresent = true
            powered = adapter?.properties["Powered"]?.bool ?? false
            for object in owned where object.path != configuration.adapter.path {
                for interface in object.interfaces where interface.name == BlueZ.deviceInterface {
                    devices[object.path, default: BlueZDevice(path: object.path)].apply(interface.properties)
                    devices[object.path]?.heardAt = now
                    devices[object.path]?.listedBeforeUs = configuration.adapter.shared
                }
            }
            // A link left from before, held by bluetoothd's own GATT client, keeps the adapter a peripheral, and
            // this controller cannot advertise while it is one. An adapter that is the peer's alone lets it go; a
            // shared one's links belong to whoever else uses it.
            for (path, device) in devices.sorted(by: { $0.key < $1.key }) where device.connected {
                if configuration.adapter.shared {
                    log.log(.info, "bluez leaving a link on the shared adapter alone: \(path)")
                } else {
                    log.log(.info, "bluez dropping a link left from before: \(path)")
                    dropLink(to: path, now: now)
                }
            }
            reconcile(now: now)
        }

        // MARK: Signals

        private func interfacesAdded(_ message: BusMessage) {
            let arguments = (try? message.arguments()) ?? []
            guard let path = arguments.first?.text, configuration.adapter.owns(path),
                let interfaces = arguments.dropFirst().first?.textKeyed
            else {
                return
            }
            if path == configuration.adapter.path, interfaces.contains(where: { $0.key == BlueZ.adapterInterface }) {
                // The adapter came back: check it again before anything else.
                takeInventory(now: Monotonic.milliseconds())
                return
            }
            for (name, properties) in interfaces where name == BlueZ.deviceInterface {
                devices[path, default: BlueZDevice(path: path)].apply(properties)
                devices[path]?.heardAt = Monotonic.milliseconds()
                sight(path)
            }
        }

        private func interfacesRemoved(_ message: BusMessage) {
            let arguments = (try? message.arguments()) ?? []
            guard let path = arguments.first?.text, configuration.adapter.owns(path), let names = arguments.dropFirst().first?.textArray
            else {
                return
            }
            if path == configuration.adapter.path, names.contains(BlueZ.adapterInterface) {
                log.log(.warning, "bluez adapter \(configuration.adapter.name) went away")
                forgetBlueZ()
                report(.off)
            } else if names.contains(BlueZ.deviceInterface) {
                devices[path] = nil
                gattDeviceRemoved(path)
                doorbellDeviceGone(path)
            }
        }

        /// `PropertiesChanged`'s arguments: the interface, what changed, and what was invalidated.
        private func propertiesChanged(_ message: BusMessage) {
            let arguments = (try? message.arguments()) ?? []
            guard let path = message.path, configuration.adapter.owns(path), let interface = arguments.first?.text,
                let changed = arguments.dropFirst().first
            else {
                return
            }
            let invalidated = arguments.dropFirst().dropFirst().first?.textArray ?? []
            switch interface {
            case BlueZ.adapterInterface where path == configuration.adapter.path:
                if let nowPowered = changed["Powered"]?.bool, nowPowered != powered {
                    powered = nowPowered
                    if !nowPowered {
                        // BlueZ has dropped our advert and GATT application with the power.
                        activeAdvert = nil
                        pendingAdvert = nil
                        gattRegistered = false
                    }
                    reconcile(now: Monotonic.milliseconds())
                }
            case BlueZ.deviceInterface:
                devices[path, default: BlueZDevice(path: path)].apply(changed)
                devices[path]?.invalidate(invalidated)
                if devices[path]?.advert != nil || devices[path]?.servesPayloadOverGatt == true {
                    let keys = (changed.textKeyed ?? []).map(\.key).joined(separator: ",")
                    log.log(
                        .debug, "bluez \(Self.deviceName(path)) changed \(keys) invalidated \(invalidated) rssi \(devices[path]?.rssi ?? 0)"
                    )
                }
                gattDeviceChanged(path, changed, now: Monotonic.milliseconds())
                doorbellDeviceChanged(path, changed, now: Monotonic.milliseconds())
                if changed["RSSI"] != nil || changed["ServiceData"] != nil || changed["UUIDs"] != nil {
                    devices[path]?.heardAt = Monotonic.milliseconds()
                    sight(path)
                } else if changed["Connected"] != nil || changed["ManufacturerData"] != nil {
                    devices[path]?.heardAt = Monotonic.milliseconds()
                }
            default:
                return
            }
        }

        /// `NameOwnerChanged`'s arguments: the name, its old owner and its new one, empty when it left the bus.
        private static let nameOwnerChangedArity = 3

        private func nameOwnerChanged(_ message: BusMessage) {
            let arguments = ((try? message.arguments()) ?? []).compactMap(\.text)
            guard arguments.count == Self.nameOwnerChangedArity, arguments.first == BlueZ.service, let newOwner = arguments.last else {
                return
            }
            if newOwner.isEmpty {
                log.log(.warning, "bluetoothd left the bus")
                bluezOwner = nil
                devices.removeAll()
                forgetBlueZ()
                report(.off)
            } else {
                bluezOwner = newOwner
                takeInventory(now: Monotonic.milliseconds())
            }
        }

        /// Reports a device whose advert carries a Knit payload, or whose GATT characteristic did, while the plane is
        /// up. A device whose characteristic has not been read yet is read, and sighted once the read ends.
        func sight(_ path: String) {
            guard isUp, let device = devices[path], let rssi = device.rssi,
                let advert = device.advert ?? gattPayload(of: device, now: Monotonic.milliseconds()),
                !configuration.neverSighted.contains(advert.nodeId)
            else {
                return
            }
            emit(.sighted(RadioSighting(address: RadioAddress(path), advert: advert, rssi: rssi)))
        }

        // MARK: Discovery

        func startDiscovery(now: Int64) {
            // DuplicateData, so every advert is reported, as Android's scanner reports them: presence needs a
            // sighting at least every 8 s, and a filtered scan would report each device once.
            let filter = DBusValue.properties([("Transport", .string("le")), ("DuplicateData", .boolean(true))])
            scanning = true
            adapterCall("SetDiscoveryFilter", interface: BlueZ.adapterInterface, [filter], now: now)
            adapterCall("StartDiscovery", interface: BlueZ.adapterInterface, [], now: now)
        }

        func stopDiscovery(now: Int64) {
            guard scanning else {
                return
            }
            scanning = false
            adapterCall("StopDiscovery", interface: BlueZ.adapterInterface, [], now: now)
        }

        /// Asks BlueZ to drop its link to a device on this adapter. When a channel closes, bluetoothd's GATT client
        /// keeps the link up; the adapter then stays a peripheral, and this controller cannot advertise while it is
        /// one (ADR 2026-09.5ftc). A device that has already gone answers `NotConnected`, which is fine.
        func dropLink(to path: String, now: Int64) {
            guard let bus, bus.isOpen, configuration.adapter.owns(path), path != configuration.adapter.path,
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: path, interface: BlueZ.deviceInterface, member: "Disconnect")
            else {
                return
            }
            bus.call(call, now: now) { [weak self] result in
                self?.log.log(.debug, "bluez disconnect \(path): \((try? result.get()) == nil ? "not connected" : "done")")
            }
        }

        /// Asks BlueZ to forget the devices it has not heard for a while (`BlueZDevice.isStale`), bar any a channel or a
        /// GATT read still uses. BlueZ answers with `InterfacesRemoved`, which drops each from ``devices``.
        func forgetQuietDevices(now: Int64) {
            let quiet = devices.values
                .filter { $0.isStale(now: now, quietMilliseconds: configuration.forgetQuietDevicesMilliseconds) && !linkInUse($0.path) }
                .map(\.path)
                .sorted()
                .prefix(Self.forgetsPerSweep)
            guard !quiet.isEmpty else {
                return
            }
            log.log(.debug, "bluez forgetting \(quiet.count) devices not heard for \(configuration.forgetQuietDevicesMilliseconds) ms")
            for path in quiet {
                // Asked once: a device that stays is forgotten again only once it has been heard, and gone quiet, anew.
                devices[path]?.heardAt = nil
                adapterCall("RemoveDevice", interface: BlueZ.adapterInterface, [.objectPath(path)], now: now)
            }
        }

        /// Asks BlueZ, as the plane comes down, to forget every device this run found: with `TemporaryTimeout = 0`
        /// nothing else ever will. A device someone paired, bonded or trusted stays, as does one a shared adapter
        /// listed before the radio started or another user holds a link to.
        func forgetDevicesFound(now: Int64, linkedByUs: Set<String>) {
            let found = devices.values
                .filter { device in
                    !device.listedBeforeUs && !device.paired && !device.bonded && !device.trusted
                        && (!device.connected || linkedByUs.contains(device.path))
                }
                .map(\.path)
                .sorted()
            guard !found.isEmpty else {
                return
            }
            log.log(.debug, "bluez forgetting the \(found.count) devices this run found")
            for path in found {
                devices[path]?.heardAt = nil
                adapterCall("RemoveDevice", interface: BlueZ.adapterInterface, [.objectPath(path)], now: now)
            }
        }

        /// Calls a method on the adapter and logs a failure; nothing waits on these.
        func adapterCall(_ member: String, interface: String, _ arguments: [DBusValue], now: Int64) {
            adapterCall(member, interface: interface, arguments, now: now) { _ in
                // Logged by the call itself; nothing else waits on it.
            }
        }

        /// Calls a method on the adapter, logs a failure, and tells `then` whether it worked.
        func adapterCall(_ member: String, interface: String, _ arguments: [DBusValue], now: Int64, then: @escaping (Bool) -> Void) {
            guard let bus, bus.isOpen,
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: configuration.adapter.path, interface: interface, member: member),
                (try? call.append(arguments)) != nil
            else {
                then(false)
                return
            }
            bus.call(call, now: now) { [weak self] result in
                if case .failure(let error) = result {
                    self?.log.log(.info, "bluez \(member) failed: \(error)")
                }
                then((try? result.get()) != nil)
            }
        }
    }
#endif
