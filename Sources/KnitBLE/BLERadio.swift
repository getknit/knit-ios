#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    public import KnitMesh
    public import KnitWire
    import Synchronization

    /// The CoreBluetooth ``Radio``: a central that scans and dials, a peripheral that serves the GATT payload and
    /// listens on an L2CAP PSM, and the streams between (ADR 2026-09.6es2: it moves bytes and decides nothing).
    ///
    /// An iPhone cannot advertise service data, so it advertises the `0xFE30` UUID alone and serves its payload from
    /// a GATT characteristic; Android with A1 accepts its dial, and a peer that reads GATT dials it (ADR
    /// 2026-09.xzpt). It reads the GATT payload of any UUID-only peer on the same rules as the BlueZ radio
    /// (``GattPayloads``), so it sets `FLAG_DIALS_GATT_PEERS`.
    ///
    /// The managers are made on the first ``start()``, which is what asks for Bluetooth on a first run, and they carry
    /// restoration identifiers, so iOS can relaunch Knit in the background for a link. Everything CoreBluetooth
    /// touches runs on one serial queue; the streams run on one thread of their own (``StreamThread``).
    public final class BLERadio: Radio {
        public let advertisesServiceData = false
        public let dialsGattPeers = true
        /// iOS suspends Knit, and a write to its doorbell resumes it, so the HELLO asks the peer to ring.
        public let servesDoorbell = true
        public let events: AsyncStream<RadioEvent>
        let core: BLECore

        /// A radio that logs to `log`.
        public init(log: any KnitLog = SilentLog()) {
            let (stream, continuation) = AsyncStream<RadioEvent>.makeStream()
            events = stream
            core = BLECore(emit: { continuation.yield($0) }, log: log)
        }

        public func start() {
            core.onQueue { $0.start() }
        }

        public func stop() {
            core.onQueue { $0.stop() }
        }

        /// Knit came to the front. iOS gives a scan for every advert nothing while Knit is in the background, and a
        /// scan asked for there still found nobody once Knit came to the front (the iPhone 12, 2026-09-26). A
        /// relaunch to restore Bluetooth starts the radio in the background, so the scan starts again here.
        public func foregrounded() {
            core.onQueue { core in
                #if DEBUG
                    core.probe.cameToFront()
                #endif
                core.rescan()
            }
        }

        public func advertise(_ payload: AdvertPayload) {
            core.onQueue { $0.advertise(payload.gattValue, psm: payload.psm) }
        }

        public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
            let channel = core.newChannel()
            core.onQueue { $0.dial(channel, address, psm: psm) }
            return channel
        }

        public func write(_ bytes: [UInt8], to channel: ChannelID) {
            core.onQueue { $0.write(bytes, to: channel) }
        }

        public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
            core.onQueue { $0.writeDigest(record, to: channel) }
        }

        /// Each link reports a FILE record's last byte out of its queue, so a file never fills it.
        public var reportsFileWrites: Bool { true }

        public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
            core.onQueue { $0.writeFileRecord(record, to: channel) }
        }

        public func close(_ channel: ChannelID) {
            core.onQueue { $0.close(channel) }
        }

        public func ring(_ channel: ChannelID) {
            core.onQueue { $0.ring(channel) }
        }

        public func heardHello(from node: NodeId, on channel: ChannelID) {
            core.onQueue { $0.heardHello(node, on: channel) }
        }

        public func seekPeers(_ seeking: Bool) {
            core.onQueue { $0.seek(seeking) }
        }
    }

    /// The radio's state and CoreBluetooth's delegates, all on ``queue``.
    internal final class BLECore: NSObject, @unchecked Sendable {
        // @unchecked: every mutable member is read and written on `queue` only, which is also the queue CoreBluetooth
        // calls the delegates on. `nextChannel` is the exception, and is atomic.

        /// What a scan asks for.
        enum ScanFilter {
            /// Every advert: iOS reports nothing of it while Knit is in the background.
            case everyAdvert
            /// The `0xFE30` UUID alone, which iOS keeps scanning for in the background, resuming Knit at each match.
            case knitOnly
        }

        struct Dial {
            let peripheral: UUID
            let psm: UInt16
            var opening = false
        }

        #if os(iOS)
            static let centralRestoreId = "app.getknit.knit.central"
            static let peripheralRestoreId = "app.getknit.knit.peripheral"
        #endif

        /// The central and the peripheral manager.
        static let managerCount = 2
        /// CoreBluetooth's RSSI when it has no reading.
        static let noReading = 127
        /// How long the connection a GATT payload was read over stays up for a dial that may follow the read.
        static let readReleaseGraceMilliseconds = 2000

        let queue = DispatchQueue(label: "app.getknit.knit.ble")
        let emit: @Sendable (RadioEvent) -> Void
        let log: any KnitLog
        let streams = StreamThread()
        let clock = SystemClock()
        private let nextChannel = Atomic<UInt64>(1)

        var central: CBCentralManager?
        var peripheralManager: CBPeripheralManager?
        var running = false
        var reported: RadioState?
        /// The newest reference to every peripheral sighted, which CoreBluetooth needs to connect it again.
        var peripherals: [UUID: CBPeripheral] = [:]
        /// Connections a relaunch handed back, to drop once the central is powered on and can take the command.
        var restored: Set<UUID> = []
        var strengths: [UUID: Int] = [:]
        var dials: [ChannelID: Dial] = [:]
        var links: [ChannelID: L2CAPLink] = [:]
        /// The peripheral a dialed link runs to; an accepted link has none of ours.
        var owners: [ChannelID: UUID] = [:]
        /// The device at the far end of every link, dialed or accepted: the address a GATT payload of it is kept
        /// under. An accepted link's is its central's identifier, which CoreBluetooth gives the same device in both
        /// roles.
        var peers: [ChannelID: UUID] = [:]
        /// The device at the far end of each accepted link, connected as a peripheral as well, so that the end of the
        /// link's connection reaches `didDisconnectPeripheral` (``attach(_:to:)``).
        var attached: [ChannelID: UUID] = [:]
        var doorbells = Doorbells()
        var gatt = GattPayloads()
        var gattTarget: UUID?
        var gattReads = 0
        /// Whether the link manager seeks peers, so the scan asks for the `0xFE30` UUID alone (``seek(_:)``).
        var seeking = false
        /// What the scan this process started asks for, or `nil` before it starts one. A relaunch to restore Bluetooth
        /// may find iOS still running the last process's scan, with whatever filter it had.
        var scanning: ScanFilter?
        /// The L2CAP listener: what was asked of the peripheral manager and what it answered.
        var listener = ListenerPublication()
        /// What the link manager last asked to advertise, and its PSM: forgotten when the link manager forgets its advert.
        var wantedValue: [UInt8]?
        var wantedPSM: UInt16?
        var servedValue: [UInt8]?
        #if DEBUG
            var probe = ScanProbe()
        #endif

        init(emit: @escaping @Sendable (RadioEvent) -> Void, log: any KnitLog) {
            self.emit = emit
            self.log = log
        }

        func onQueue(_ work: @escaping @Sendable (BLECore) -> Void) {
            queue.async { [self] in work(self) }
        }

        func newChannel() -> ChannelID {
            ChannelID(nextChannel.add(1, ordering: .relaxed).oldValue)
        }

        // MARK: Lifecycle

        func start() {
            running = true
            guard central == nil else {
                resume()
                return
            }
            var centralOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
            var peripheralOptions: [String: Any] = [CBPeripheralManagerOptionShowPowerAlertKey: false]
            #if os(iOS)
                centralOptions[CBCentralManagerOptionRestoreIdentifierKey] = Self.centralRestoreId
                peripheralOptions[CBPeripheralManagerOptionRestoreIdentifierKey] = Self.peripheralRestoreId
            #endif
            central = CBCentralManager(delegate: self, queue: queue, options: centralOptions)
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: peripheralOptions)
        }

        func stop() {
            running = false
            central?.stopScan()
            scanning = nil
            gatt.scanStopped(now: clock.monotonicMilliseconds())
            for peripheral in peripherals.values where peripheral.state != .disconnected {
                central?.cancelPeripheralConnection(peripheral)
            }
            if let peripheralManager {
                peripheralManager.stopAdvertising()
                peripheralManager.removeAllServices()
            }
            // The next start publishes once this is answered, or its wait runs out (``ListenerPublication``). A manager
            // that is not powered on refuses the unpublish and never answers, so then the PSM is only forgotten.
            if let peripheralManager, peripheralManager.state == .poweredOn, let unpublish = listener.stop() {
                awaitUnpublish(unpublish, on: peripheralManager)
            } else {
                listener.forget()
            }
            // The service is gone, so the next start serves it again. iOS hands back the same PSM, so the value does
            // not change, and without this the iPhone came back serving neither its payload nor its doorbell.
            servedValue = nil
            // The link manager forgets what it advertised at a stop, and advertises again once the listener reports.
            wantedValue = nil
            wantedPSM = nil
            forgetLinks()
            log.log(.info, "ble stopped")
        }

        /// Scanning, the listener and the advert, once both managers are on and the radio runs.
        func resume() {
            guard running, reported == .on, let central, let peripheralManager else {
                return
            }
            if !central.isScanning {
                scan(with: central)
            } else if scanning != wantedScan {
                // A scan iOS restored, or one asked for before the radio went off: its filter may not be the one wanted.
                central.stopScan()
                scan(with: central)
            }
            if listener.shouldPublish() {
                peripheralManager.publishL2CAPChannel(withEncryption: false)
            }
            serve()
        }

        /// The state both managers agree on: any refusal or absence wins, then off, then on. A manager resetting (bluetoothd
        /// restarting) counts as off: its channels go, and it refuses a command unanswered until it is powered on again.
        func updateState() {
            let states = [central?.state, peripheralManager?.state].compactMap(\.self)
            let state: RadioState?
            if states.contains(.unsupported) {
                state = .unsupported
            } else if states.contains(.unauthorized) {
                state = .unauthorized
            } else if states.contains(.poweredOff) || states.contains(.resetting) {
                state = .off
            } else if states.count == Self.managerCount, states.allSatisfy({ $0 == .poweredOn }) {
                state = .on
            } else {
                state = nil
            }
            guard let state, state != reported else {
                return
            }
            reported = state
            log.log(.info, "ble \(state)")
            if state != .on {
                gatt.scanStopped(now: clock.monotonicMilliseconds())
                scanning = nil
                forgetLinks()
                listener.poweredOff()
                servedValue = nil
                // The link manager forgets its advert too, and advertises again once the listener reports a PSM.
                wantedValue = nil
                wantedPSM = nil
            }
            emit(.state(state))
            resume()
        }

        /// Drops every link, dial and read: the radio went off or stopped, and the link manager forgets them too.
        func forgetLinks() {
            for link in links.values {
                link.close()
            }
            links.removeAll()
            owners.removeAll()
            peers.removeAll()
            attached.removeAll()
            dials.removeAll()
            doorbells = Doorbells()
            gatt.cancel()
            gattTarget = nil
        }

        // MARK: The advert and its GATT payload

        func advertise(_ value: [UInt8], psm: UInt16) {
            wantedValue = value
            wantedPSM = psm
            serve()
        }

        /// Serves the wanted value from the `0xFE30` service, with the doorbell beside it, and advertises the UUID alone.
        /// The value is static, so the service is replaced whenever it changes, which is only with the PSM.
        /// Only while the listener is published on the value's PSM: an advert made from a `.listening` that predates a
        /// stop, or a debounced one racing the radio going off, may arrive before the new publish lands. The publish's
        /// answer serves it then, as the link manager sends no new advert for an unchanged PSM.
        func serve() {
            guard running, reported == .on, let peripheralManager, let value = wantedValue, value != servedValue,
                let psm = listener.psm, psm == wantedPSM
            else {
                return
            }
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            let characteristic = CBMutableCharacteristic(
                type: Self.characteristicUUID,
                properties: [.read],
                value: Data(value),
                permissions: [.readable]
            )
            let doorbell = CBMutableCharacteristic(
                type: Self.doorbellUUID,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [characteristic, doorbell]
            peripheralManager.add(service)
            servedValue = value
        }

        // MARK: Channels

        func dial(_ channel: ChannelID, _ address: RadioAddress, psm: UInt16) {
            guard running, let central, let uuid = UUID(uuidString: address.rawValue),
                let peripheral = peripherals[uuid] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first
            else {
                emit(.dialFailed(channel))
                return
            }
            peripherals[uuid] = peripheral
            peripheral.delegate = self
            dials[channel] = Dial(peripheral: uuid, psm: psm)
            if peripheral.state == .connected {
                openPending(on: peripheral)
            } else if peripheral.state != .connecting {
                central.connect(peripheral)
            }
        }

        /// Asks for an L2CAP channel for every dial waiting on `peripheral`.
        func openPending(on peripheral: CBPeripheral) {
            for (channel, dial) in dials where dial.peripheral == peripheral.identifier && !dial.opening {
                dials[channel]?.opening = true
                peripheral.openL2CAPChannel(CBL2CAPPSM(dial.psm))
            }
        }

        func write(_ bytes: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped \(bytes.count) bytes for \(channel), which has no link")
                return
            }
            link.write(bytes)
        }

        func writeDigest(_ record: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a digest of \(record.count) bytes for \(channel), which has no link")
                return
            }
            link.writeDigest(record)
        }

        func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a file record of \(record.count) bytes for \(channel), which has no link")
                return
            }
            link.writeFileRecord(record)
        }
    }

    // MARK: The GATT identifiers

    extension BLECore {
        /// `CBUUID` is not `Sendable`, so these are built where they are used rather than stored.
        static var serviceUUID: CBUUID { CBUUID(string: AdvertPayload.serviceUUID) }
        static var characteristicUUID: CBUUID { CBUUID(string: AdvertPayload.characteristicUUID) }
        static var doorbellUUID: CBUUID { CBUUID(string: AdvertPayload.doorbellUUID) }
    }
#endif
