#if os(Linux)
    import KnitMesh
    import KnitWire

    /// The advert and the GATT application: registering them with BlueZ, and answering what BlueZ asks of them.
    extension BlueZLoop {
        // MARK: The advert

        /// Registers the wanted advert under a new object path, then withdraws the old one: two instances briefly,
        /// never none (hci1 has four). A refresh re-registers the same payload, to re-enable an advert the kernel
        /// stopped when a peer connected.
        func syncAdvert(now: Int64) {
            guard isUp, pendingAdvert == nil, let bus, let desired = desiredAdvert else {
                return
            }
            let refreshing = refreshAdvertAt.map { now >= $0 } ?? false
            guard activeAdvert?.payload != desired || refreshing else {
                return
            }
            refreshAdvertAt = nil
            let path = configuration.objectRoot + "/advert\(advertGeneration)"
            advertGeneration += 1
            pendingAdvert = (path: path, payload: desired)
            bus.export(path) { [weak self] call in self?.answerAdvertisement(call, at: path) ?? .unknown }
            let arguments: [DBusValue] = [.objectPath(path), .properties([])]
            adapterCall("RegisterAdvertisement", interface: BlueZ.advertisingManager, arguments, now: now) { [weak self] success in
                self?.advertRegistered(path, success: success)
            }
        }

        private func advertRegistered(_ path: String, success: Bool) {
            guard pendingAdvert?.path == path else {
                return
            }
            let now = Monotonic.milliseconds()
            guard success else {
                bus?.unexport(path)
                pendingAdvert = nil
                refreshAdvertAt = now + configuration.retryDelayMilliseconds
                return
            }
            let replaced = activeAdvert
            activeAdvert = pendingAdvert
            pendingAdvert = nil
            log.log(.debug, "bluez advertising \(path)")
            if let replaced {
                withdrawAdvert(replaced.path, now: now)
            }
            syncAdvert(now: now)
        }

        private func withdrawAdvert(_ path: String, now: Int64) {
            adapterCall("UnregisterAdvertisement", interface: BlueZ.advertisingManager, [.objectPath(path)], now: now) { [weak self] _ in
                self?.bus?.unexport(path)
            }
        }

        func withdrawAdvertisements(now: Int64) {
            for path in [activeAdvert?.path, pendingAdvert?.path].compactMap(\.self) {
                withdrawAdvert(path, now: now)
            }
            activeAdvert = nil
            pendingAdvert = nil
        }

        private func answerAdvertisement(_ call: BusMessage, at path: String) -> BusConnection.Answer {
            guard isFromBlueZ(call) else {
                return .error(name: BlueZ.accessDenied, message: "only BlueZ may read the advertisement")
            }
            let payload = [activeAdvert, pendingAdvert].compactMap(\.self).first { $0.path == path }?.payload
            switch (call.interface, call.member) {
            case (BlueZ.advertisementInterface, "Release"):
                if activeAdvert?.path == path {
                    activeAdvert = nil
                    syncAdvert(now: Monotonic.milliseconds())
                }
                bus?.unexport(path)
                return .values([])
            case (BlueZ.properties, "GetAll"), (BlueZ.properties, "Get"):
                guard let payload else {
                    return .error(name: BlueZ.unknownInterface, message: "no advertisement at \(path)")
                }
                return properties(
                    AdvertisementProperties.of(payload, profile: configuration.profile), for: call, interface: BlueZ.advertisementInterface)
            default:
                return .unknown
            }
        }

        /// Answers `Properties.GetAll(interface)` and `Properties.Get(interface, name)` for one interface.
        func properties(_ properties: [(String, DBusValue)], for call: BusMessage, interface: String) -> BusConnection.Answer {
            let arguments = ((try? call.arguments()) ?? []).compactMap(\.text)
            guard arguments.first == interface else {
                return .error(name: BlueZ.unknownInterface, message: "no interface \(arguments.first ?? "")")
            }
            if call.member == "GetAll" {
                return .values([.properties(properties)])
            }
            let name = arguments.dropFirst().first
            guard let value = properties.first(where: { $0.0 == name })?.1 else {
                return .error(name: BlueZ.unknownProperty, message: "no property \(name ?? "")")
            }
            return .values([.variant(value)])
        }

        /// Whether a call into this process's objects came from BlueZ. On a peer-to-peer connection, which only the
        /// tests use, there is no sender to check.
        func isFromBlueZ(_ call: BusMessage) -> Bool {
            guard case .system = configuration.bus else {
                return true
            }
            return bluezOwner != nil && call.sender == bluezOwner
        }

        // MARK: The GATT application

        var application: GattApplication {
            GattApplication(root: configuration.objectRoot + "/gatt")
        }

        /// Serves the payload the way an iPhone does, for `--radio-profile ios`.
        func registerApplication(now: Int64) {
            guard let bus, !gattRegistered else {
                return
            }
            let gatt = application
            bus.export(gatt.root) { [weak self] call in
                guard let self, isFromBlueZ(call) else {
                    return .error(name: BlueZ.accessDenied, message: "only BlueZ may read the application")
                }
                guard call.interface == BlueZ.objectManager, call.member == "GetManagedObjects" else {
                    return .unknown
                }
                return .values([gatt.managedObjects])
            }
            bus.export(gatt.characteristicPath) { [weak self] call in
                self?.answerCharacteristic(call) ?? .unknown
            }
            gattRegistered = true
            let registered: (Bool) -> Void = { [weak self] success in
                if success {
                    self?.log.log(.info, "bluez serving the payload over GATT")
                } else {
                    self?.gattRegistered = false
                }
            }
            adapterCall(
                "RegisterApplication", interface: BlueZ.gattManager, [.objectPath(gatt.root), .properties([])], now: now, then: registered)
        }

        private func answerCharacteristic(_ call: BusMessage) -> BusConnection.Answer {
            guard isFromBlueZ(call) else {
                return .error(name: BlueZ.accessDenied, message: "only BlueZ may read the characteristic")
            }
            guard call.interface == BlueZ.gattCharacteristic, call.member == "ReadValue" else {
                return .unknown
            }
            let value = activeAdvert?.payload.gattValue ?? desiredAdvert?.gattValue ?? []
            guard let slice = GattApplication.read(value, options: (try? call.arguments())?.first) else {
                return .error(name: BlueZ.bluezInvalidOffset, message: "offset past the value")
            }
            return .values([.bytes(slice)])
        }

        func withdrawApplication(now: Int64) {
            guard gattRegistered else {
                return
            }
            gattRegistered = false
            let gatt = application
            adapterCall("UnregisterApplication", interface: BlueZ.gattManager, [.objectPath(gatt.root)], now: now) { [weak self] _ in
                self?.bus?.unexport(gatt.root)
                self?.bus?.unexport(gatt.characteristicPath)
            }
        }
    }
#endif
