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
        /// Every channel's queued and written bytes, counted here as each write is handed over and on the stream thread as
        /// each byte goes out, so the link manager reads them without a hop to the queue (ADR 2026-10.f5zs).
        private let levels: OutboxLevels
        /// Every channel's bytes delivered and not yet processed, counted on the stream thread as each read is delivered and
        /// here as `Mesh` reports it processed, so neither waits on the other (ADR 2026-10.f5zs, rule 6).
        private let credits: InboxCredits

        /// A radio that logs to `log`. `expectsBlinding` brings the doorbell's service up before the listener at a cold
        /// launch whose persisted switch blinds, before the link manager's first advert says so (``GattServing``; ADR
        /// 2026-11.prsp). A restoration only ever upgrades it to the split layout, and the advert still decides.
        public init(log: any KnitLog = SilentLog(), expectsBlinding: Bool = false) {
            let (stream, continuation) = AsyncStream<RadioEvent>.makeStream()
            let counted = OutboxLevels()
            let inbound = InboxCredits()
            events = stream
            levels = counted
            credits = inbound
            core = BLECore(
                emit: { event in
                    counted.note(event)
                    inbound.note(event)
                    continuation.yield(event)
                },
                levels: counted,
                credits: inbound,
                log: log,
                expectsBlinding: expectsBlinding
            )
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
            core.onQueue { $0.advertise(GattServing.Wanted(value: payload.gattValue, blinded: payload.blinded), psm: payload.psm) }
        }

        public func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
            let channel = core.newChannel()
            core.onQueue { $0.dial(channel, address, psm: psm) }
            return channel
        }

        public func write(_ bytes: [UInt8], to channel: ChannelID) {
            levels.queued(bytes.count, on: channel)
            core.onQueue { $0.write(bytes, to: channel) }
        }

        public func writeDigest(_ record: [UInt8], to channel: ChannelID) {
            levels.queued(record.count, on: channel)
            core.onQueue { $0.writeDigest(record, to: channel) }
        }

        /// Each link reports a FILE record's last byte out of its queue, so a file never fills it.
        public var reportsFileWrites: Bool { true }

        public func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
            levels.queued(record.count, on: channel)
            core.onQueue { $0.writeFileRecord(record, to: channel) }
        }

        /// Counted at this radio's entry points, so bytes still crossing to the CoreBluetooth queue or the stream thread
        /// count as queued.
        public func outboxLevel(on channel: ChannelID) -> OutboxLevel {
            levels.level(on: channel)
        }

        public func close(_ channel: ChannelID) {
            core.onQueue { $0.close(channel) }
        }

        /// Taken off the channel's credit here, at once. Only a resume hops: to the queue, to find the link, and from it to
        /// the stream thread, where the link reads again of its own accord, since its stream will not say
        /// `hasBytesAvailable` again until it does (``L2CAPLink/resumeReading(unprocessed:)``).
        public func consumed(_ count: Int, on channel: ChannelID) {
            guard let unprocessed = credits.consumed(count, on: channel) else {
                return
            }
            core.onQueue { $0.links[channel]?.resumeReading(unprocessed: unprocessed) }
        }

        public func ring(_ channel: ChannelID) {
            core.onQueue { $0.ring(channel) }
        }

        public func heardHello(from node: NodeId, told: NodeId?, announced: NodeId?, on channel: ChannelID) {
            core.onQueue { $0.heardHello(node, told: told, announced: announced, on: channel) }
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
        /// Every channel's level (``BLERadio/outboxLevel(on:)``): a channel counts from ``newChannel()``.
        let levels: OutboxLevels
        /// Every channel's inbound credit (``InboxCredits``), which its link reads before each read: a channel counts from
        /// ``newChannel()`` too.
        let credits: InboxCredits
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
        /// Rule 4's jitter seeded at random, so readers of one writer read it again at different moments.
        var gatt = GattPayloads(jitterSeed: UInt64.random(in: .min ... .max))
        var gattTarget: UUID?
        /// How far the read of ``gattTarget`` has come: its search of every `0xFE30` service once their list came.
        var gattStage: GattReadStage?
        var gattReads = 0
        /// Whether the link manager seeks peers, so the scan asks for the `0xFE30` UUID alone (``seek(_:)``).
        var seeking = false
        /// What the scan this process started asks for, or `nil` before it starts one. A relaunch to restore Bluetooth
        /// may find iOS still running the last process's scan, with whatever filter it had.
        var scanning: ScanFilter?
        /// The L2CAP listener: what was asked of the peripheral manager and what it answered.
        var listener = ListenerPublication()
        /// What the link manager last asked to advertise, and its PSM: forgotten when the link manager forgets its advert.
        var wanted: GattServing.Wanted?
        var wantedPSM: UInt16?
        /// What the GATT server holds and the next step toward what it should: one combined service while clear, the
        /// doorbell's and the payload's while blinding (ADR 2026-11.prsp).
        var serving: GattServing
        /// The services asked for whose `didAdd` has not come, by ``GattServing/Service/serial``. Kept through a stop or a
        /// power-off, so a late answer is still matched to its own service, which ``serving`` has let go of, and ignored.
        var awaitingAdd: [UInt64: CBMutableService] = [:]
        /// The services the server holds, by serial, which a removal names.
        var served: [UInt64: CBMutableService] = [:]
        /// What the factory said at construction (``BLERadio/init(log:expectsBlinding:)``), for ``BLERadio/servingReport()``.
        let expectsBlinding: Bool
        /// How many `0xFE30` services a restoration handed back, `nil` when this process was not restored.
        var restoredServices: Int?
        /// How many `didAdd` answers were matched by order, not identity (``oldestAwaited()``), which the probe expects never.
        var matchedByOrder = 0
        #if DEBUG
            var probe = ScanProbe()
        #endif

        init(
            emit: @escaping @Sendable (RadioEvent) -> Void, levels: OutboxLevels, credits: InboxCredits, log: any KnitLog,
            expectsBlinding: Bool
        ) {
            self.emit = emit
            serving = GattServing(expectsBlinding: expectsBlinding)
            self.expectsBlinding = expectsBlinding
            self.levels = levels
            self.credits = credits
            self.log = log
        }

        func onQueue(_ work: @escaping @Sendable (BLECore) -> Void) {
            queue.async { [self] in work(self) }
        }

        /// A channel id never used before, counted from now: before any event names it, so before the link manager can
        /// write to it.
        func newChannel() -> ChannelID {
            let id = ChannelID(nextChannel.add(1, ordering: .relaxed).oldValue)
            levels.open(id)
            credits.open(id)
            return id
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
            forgetServices()
            // The next start publishes once this is answered, or its wait runs out (``ListenerPublication``). A manager
            // that is not powered on refuses the unpublish and never answers, so then the PSM is only forgotten.
            if let peripheralManager, peripheralManager.state == .poweredOn, let unpublish = listener.stop() {
                awaitUnpublish(unpublish, on: peripheralManager)
            } else {
                listener.forget()
            }
            // The link manager forgets what it advertised at a stop, and advertises again once the listener reports.
            wanted = nil
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
            // Served first: the process's one clear of what a restoration handed back, and while blinding the doorbell's
            // service, whose `didAdd` publishes (ADR 2026-11.prsp).
            serve()
            publishIfDue(on: peripheralManager)
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
                // A manager that goes off clears its services, and the next power-on serves them again.
                forgetServices()
                // The link manager forgets its advert too, and advertises again once the listener reports a PSM.
                wanted = nil
                wantedPSM = nil
            }
            emit(.state(state))
            resume()
        }

        /// Drops every link, dial and read: the radio went off or stopped, and the link manager forgets them too.
        func forgetLinks() {
            for (id, link) in links {
                link.close()
                levels.close(id)
                credits.close(id)
            }
            for id in dials.keys {
                levels.close(id)
                credits.close(id)
            }
            links.removeAll()
            owners.removeAll()
            peers.removeAll()
            attached.removeAll()
            dials.removeAll()
            doorbells = Doorbells()
            gatt.cancel()
            gattTarget = nil
            gattStage = nil
        }
    }
#endif
