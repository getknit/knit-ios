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
        public let events: AsyncStream<RadioEvent>
        private let core: BLECore

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
            core.onQueue { $0.rescan() }
        }

        public func advertise(_ payload: AdvertPayload) {
            core.onQueue { $0.advertise(payload.gattValue) }
        }

        public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
            let channel = core.newChannel()
            core.onQueue { $0.dial(channel, address, psm: psm) }
            return channel
        }

        public func write(_ bytes: [UInt8], to channel: ChannelID) {
            core.onQueue { $0.write(bytes, to: channel) }
        }

        public func close(_ channel: ChannelID) {
            core.onQueue { $0.close(channel) }
        }
    }

    /// The radio's state and CoreBluetooth's delegates, all on ``queue``.
    internal final class BLECore: NSObject, @unchecked Sendable {
        // @unchecked: every mutable member is read and written on `queue` only, which is also the queue CoreBluetooth
        // calls the delegates on. `nextChannel` is the exception, and is atomic.

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
        var gatt = GattPayloads()
        var gattTarget: UUID?
        var gattReads = 0
        var publishing = false
        var psm: UInt16?
        var wantedValue: [UInt8]?
        var servedValue: [UInt8]?

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
            for peripheral in peripherals.values where peripheral.state != .disconnected {
                central?.cancelPeripheralConnection(peripheral)
            }
            if let peripheralManager {
                peripheralManager.stopAdvertising()
                peripheralManager.removeAllServices()
                if let psm {
                    peripheralManager.unpublishL2CAPChannel(psm)
                }
            }
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
            }
            if psm == nil, !publishing {
                publishing = true
                peripheralManager.publishL2CAPChannel(withEncryption: false)
            }
            serve()
        }

        /// Every advert, every time: a foreground scan filtered by service would miss Android's, which lists `0xFE30`
        /// only as service data (P8 checks what a filter matches).
        func scan(with central: CBCentralManager) {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log.log(.info, "ble scanning")
        }

        /// Starts the scan again, for ``BLERadio/foregrounded()``.
        func rescan() {
            guard running, reported == .on, let central else {
                return
            }
            central.stopScan()
            scan(with: central)
        }

        /// The state both managers agree on: any refusal or absence wins, then off, then on.
        func updateState() {
            let states = [central?.state, peripheralManager?.state].compactMap(\.self)
            let state: RadioState?
            if states.contains(.unsupported) {
                state = .unsupported
            } else if states.contains(.unauthorized) {
                state = .unauthorized
            } else if states.contains(.poweredOff) {
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
                forgetLinks()
                psm = nil
                publishing = false
                servedValue = nil
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
            dials.removeAll()
            gatt.cancel()
            gattTarget = nil
        }

        // MARK: The advert and its GATT payload

        func advertise(_ value: [UInt8]) {
            wantedValue = value
            serve()
        }

        /// Serves the wanted value from the `0xFE30` service, with the doorbell beside it, and advertises the UUID alone.
        /// The value is static, so the service is replaced whenever it changes, which is only with the PSM.
        func serve() {
            guard running, reported == .on, let peripheralManager, let value = wantedValue, value != servedValue else {
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

        func close(_ channel: ChannelID) {
            if let dial = dials.removeValue(forKey: channel) {
                releaseIfIdle(dial.peripheral)
            }
            guard let link = links.removeValue(forKey: channel) else {
                return
            }
            link.close()
            emit(.closed(channel))
            if let owner = owners.removeValue(forKey: channel) {
                releaseIfIdle(owner)
            }
        }

        /// Starts a link over an open channel, dialed or accepted, once its opening is reported.
        func adopt(_ channel: CBL2CAPChannel, as id: ChannelID, owner: UUID?) {
            let link = L2CAPLink(
                id: id,
                channel: channel,
                thread: streams,
                log: log,
                received: { [emit] bytes in emit(.received(id, bytes)) },
                ended: { [weak self] in self?.onQueue { $0.ended(id) } }
            )
            links[id] = link
            owners[id] = owner
            link.open()
        }

        /// The far side closed a link, or it failed.
        func ended(_ id: ChannelID) {
            guard links.removeValue(forKey: id) != nil else {
                return
            }
            emit(.closed(id))
            if let owner = owners.removeValue(forKey: id) {
                releaseIfIdle(owner)
            }
        }

        /// Whether a dial, a link or the GATT read in progress uses the connection to `uuid`.
        func inUse(_ uuid: UUID) -> Bool {
            gattTarget == uuid || dials.values.contains { $0.peripheral == uuid } || owners.values.contains(uuid)
        }

        /// Drops the connection to `uuid` once nothing uses it, so the controller is free for the next.
        func releaseIfIdle(_ uuid: UUID) {
            guard !inUse(uuid), let peripheral = peripherals[uuid], peripheral.state != .disconnected else {
                return
            }
            central?.cancelPeripheralConnection(peripheral)
        }

        /// Every dial waiting on `uuid` failed; a payload read over GATT may name a PSM it no longer listens on, so
        /// it is read again (``GattPayloads``). A connection that ends with no dial waiting keeps the payload: the
        /// radio ends its own after every read, and forgetting it then meant reading the same peer every few
        /// seconds (the iPhone 12, 2026-09-26).
        func failDials(on uuid: UUID) {
            var failed = false
            for (channel, dial) in dials where dial.peripheral == uuid {
                dials[channel] = nil
                emit(.dialFailed(channel))
                failed = true
            }
            if failed {
                gatt.forget(RadioAddress(uuid.uuidString))
            }
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
