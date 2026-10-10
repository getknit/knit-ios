#if os(Linux)
    import KnitBlueZ
    import KnitCrypto
    import KnitMesh
    import KnitPeer
    import KnitWire

    /// This platform's peer radio.
    internal typealias PeerHost = BlueZHost

    /// The Linux peer's radio: BlueZ on one adapter, found by its address, dongle A unless told otherwise, and never
    /// the maintainer's adapter unshared.
    internal struct BlueZHost: PeerRadioHost {
        let radio: any Radio
        let profile: String
        private let blueZ: BlueZRadio

        /// The radio `options` ask for, once the adapter is checked: a missing or wrong one throws.
        init(_ options: RunOptions, log: any KnitLog) throws(PeerHostError) {
            let selection: AdapterSelection
            do {
                selection = try Self.checkedAdapter(options.adapterAddress, shared: options.sharedAdapter, log: log)
            } catch {
                throw .adapter(error)
            }
            let chosen = options.radioProfile.flatMap(RadioProfile.init(name:)) ?? .android
            guard options.servesGattPayload || chosen == .ios else {
                throw .unsupported("--no-gatt-payload: only the ios profile serves GATT")
            }
            var configuration = BlueZRadio.Configuration(adapter: selection, profile: chosen, log: log)
            configuration.servesGattPayload = options.servesGattPayload
            configuration.neverSighted = options.neverSighted
            if options.gattReads != .asProfile, (options.gattReads == .on) != configuration.readsGattPayloads {
                configuration.readsGattPayloads = options.gattReads == .on
                if options.gattReads == .on {
                    log.log(.info, "reading GATT payloads, and setting FLAG_DIALS_GATT_PEERS, as a release Android does")
                } else {
                    log.log(.info, "reading no GATT payloads, and leaving FLAG_DIALS_GATT_PEERS clear, a test switch")
                }
            }
            if !options.neverSighted.isEmpty {
                log.log(.info, "never sighting \(options.neverSighted.map(\.string).sorted().joined(separator: ", ")), a test switch")
            }
            if !options.servesGattPayload {
                log.log(.info, "serving the doorbell without the payload, so readers take this peer for a stranger")
            }
            let receiveMTU = options.receiveMTU.flatMap(UInt16.init(exactly:))
            let sendMTU = options.sendMTU.flatMap(UInt16.init(exactly:))
            if receiveMTU != nil || sendMTU != nil {
                configuration.sockets = L2CAPSockets(
                    adapter: selection.address,
                    receiveMTU: receiveMTU ?? L2CAPSockets.largestReceiveMTU,
                    sendMTU: sendMTU ?? L2CAPSockets.defaultSendMTU
                )
                let offered = receiveMTU.map(String.init) ?? "the default"
                let written = sendMTU ?? L2CAPSockets.defaultSendMTU
                log.log(.info, "channels offer a receive MTU of \(offered) and write at most \(written)")
            }
            blueZ = BlueZRadio(configuration: configuration)
            radio = blueZ
            profile = chosen.name
        }

        func shutdown() async {
            await blueZ.shutdown()
        }

        /// Drives the radio directly, with no link manager to dial.
        static func scan(_ options: ScanOptions) async {
            let log = JSONLinesLog(
                threshold: JSONLinesLog.level(named: options.logLevel) ?? .info, clock: SystemClock(), write: Lines.error.write)
            let selection: AdapterSelection
            do {
                selection = try checkedAdapter(options.adapterAddress, shared: options.sharedAdapter, log: log)
            } catch {
                KnitPeerMain.fail("refusing to start: \(error)")
            }
            let advertised = options.advertise.flatMap(RadioProfile.init(name:))
            var configuration = BlueZRadio.Configuration(adapter: selection, profile: advertised ?? .android, log: log)
            configuration.readsGattPayloads = true
            let scanner = BlueZRadio(configuration: configuration)
            var own: NodeId?
            if advertised != nil {
                do {
                    own = try PeerState(directory: options.stateDirectory).loadIdentity().keys.nodeId
                } catch {
                    KnitPeerMain.fail("cannot load the identity in \(options.stateDirectory): \(error)")
                }
            }
            var report = ScanReport(own: own)
            let deadline = ContinuousClock.now.advanced(by: .seconds(options.seconds))
            let stopper = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                await scanner.shutdown()
            }
            scanner.start()
            for await event in scanner.events {
                switch event {
                case .listening(let psm):
                    if let own {
                        scanner.advertise(AdvertPayload(capabilities: .local, nodeId: own, digestCue: 0, psm: psm))
                        log.log(.info, "advertising \(own) on PSM \(psm)")
                    }
                case .sighted(let sighting):
                    report.take(sighting).map(Lines.output.write)
                case .accepted(let channel):
                    // Someone dialed the advert anyway: hang up before any HELLO.
                    scanner.close(channel)
                case .state(let state) where state != .on:
                    log.log(.warning, "radio \(state)")
                default:
                    continue
                }
            }
            _ = await stopper.result
            Lines.output.write(report.summary)
        }

        private static func checkedAdapter(_ address: String, shared: Bool, log: any KnitLog) throws -> AdapterSelection {
            let status = try AdapterProbe.select(address: address, shared: shared)
            let selection = status.adapter
            let use = shared ? ", shared" : ""
            log.log(.info, "adapter \(selection.name) is \(selection.address)\(use), \(status.powered ? "powered" : "not powered")")
            return selection
        }
    }
#endif
