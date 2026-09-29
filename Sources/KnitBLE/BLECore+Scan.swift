#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh
    import KnitWire

    // MARK: Scanning

    extension BLECore {
        /// Every advert, every time. A scan filtered on `0xFE30` would match the same peers, Android's service data
        /// included, but it runs on once Knit leaves the front and wakes Knit for every match, where this one goes
        /// quiet (P8's scan-filter check, `.agents/context/ble-transport.md`).
        func scan(with central: CBCentralManager) {
            central.scanForPeripherals(withServices: scanFilter, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            gatt.scanStarted(now: clock.monotonicMilliseconds())
            log.log(.info, "ble scanning")
        }

        /// The services a scan asks for: none, so every advert, unless a debug build's scan probe runs (``ScanProbe``).
        var scanFilter: [CBUUID]? {
            #if DEBUG
                probe.isOn ? [Self.serviceUUID] : nil
            #else
                nil
            #endif
        }

        /// Starts the scan again, for ``BLERadio/foregrounded()``.
        func rescan() {
            guard running, reported == .on, let central else {
                return
            }
            central.stopScan()
            scan(with: central)
        }
    }

    // MARK: A debug build's scan probe

    #if DEBUG
        /// A debug build's probe for P8's scan-filter check (`.agents/specs/mvp.md`). While it is on, the central
        /// scans for the `0xFE30` UUID alone, as a scan in the background must, and the probe records what each
        /// advert the scan matched carried: `0xFE30` as service data, as Android advertises it, or in a UUID list, as
        /// an iPhone or the `ios` profile does. It also records whether Knit was away from the front when the match
        /// came. When Knit leaves the front the scan starts again, so a peer that appears once Knit is suspended
        /// counts as a new discovery.
        public struct ScanProbe: Sendable {
            /// One peripheral the filtered scan matched.
            public struct Match: Sendable, Equatable {
                /// CoreBluetooth's identifier for it.
                public let peripheral: String
                /// Its node id, from its service data or its GATT payload, once either is known.
                public var node: String?
                /// Whether a matched advert carried `0xFE30` as service data.
                public var serviceData = false
                /// Whether a matched advert listed `0xFE30` among its service UUIDs.
                public var listed = false
                /// Whether a matched advert had `0xFE30` in the overflow area, where a backgrounded iPhone puts it.
                public var overflow = false
                /// How many adverts matched.
                public var count = 0
                /// How many of them matched while Knit was away from the front.
                public var awayCount = 0
                /// When it first matched, in wall milliseconds.
                public var firstAt: Int64
                /// When it last matched.
                public var lastAt: Int64
                /// When it first matched while Knit was away from the front.
                public var firstAwayAt: Int64?
                /// The last match's RSSI.
                public var rssi: Int
            }

            /// How much of a peripheral's identifier a match shows: enough to tell the peripherals in range apart.
            static let shownLength = 8

            /// Whether the probe runs.
            public private(set) var isOn = false
            /// Whether Knit is away from the front.
            public private(set) var isAway = false
            /// When Knit last left the front, in wall milliseconds.
            public private(set) var awaySince: Int64?
            private var matches: [UUID: Match] = [:]

            /// What it matched, oldest first.
            public var matched: [Match] {
                matches.values.sorted { ($0.firstAt, $0.peripheral) < ($1.firstAt, $1.peripheral) }
            }

            mutating func turn(on: Bool) {
                isOn = on
                if on {
                    matches.removeAll()
                }
            }

            mutating func leftFront(now: Int64) {
                isAway = true
                awaySince = now
            }

            mutating func cameToFront() {
                isAway = false
            }

            /// Records one matched advert, and answers what is worth a log line: its first match, or its first while
            /// Knit was away.
            mutating func saw(_ uuid: UUID, _ advertisement: [String: Any], node: String?, rssi: Int, now: Int64) -> String? {
                let first = matches[uuid] == nil
                let shown = String(uuid.uuidString.prefix(Self.shownLength))
                var match = matches[uuid] ?? Match(peripheral: shown, firstAt: now, lastAt: now, rssi: rssi)
                let firstAway = isAway && match.awayCount == 0
                match.node = node ?? match.node
                match.serviceData = match.serviceData || BLEAdvert.payload(advertisement) != nil
                match.listed = match.listed || Self.lists(advertisement, CBAdvertisementDataServiceUUIDsKey)
                match.overflow = match.overflow || Self.lists(advertisement, CBAdvertisementDataOverflowServiceUUIDsKey)
                match.count += 1
                match.lastAt = now
                match.rssi = rssi
                if isAway {
                    match.awayCount += 1
                    match.firstAwayAt = match.firstAwayAt ?? now
                }
                matches[uuid] = match
                guard first || firstAway else {
                    return nil
                }
                let carried = [("service data", match.serviceData), ("UUID list", match.listed), ("overflow", match.overflow)]
                    .filter(\.1).map(\.0).joined(separator: ", ")
                return "ble probe matched \(match.peripheral) \(match.node ?? "unknown node") by \(carried)\(isAway ? " while away" : "")"
            }

            /// Fills in node ids learned since, from GATT payloads read after the match.
            mutating func learn(_ nodes: (UUID) -> String?) {
                for (uuid, match) in matches where match.node == nil {
                    matches[uuid]?.node = nodes(uuid)
                }
            }

            private static func lists(_ advertisement: [String: Any], _ key: String) -> Bool {
                (advertisement[key] as? [CBUUID])?.contains(BLECore.serviceUUID) ?? false
            }
        }

        extension BLERadio {
            /// Turns the scan probe on, forgetting what it matched before, or off, and scans again either way.
            public func probeScan(_ on: Bool) {
                core.onQueue { core in
                    core.probe.turn(on: on)
                    core.log.log(.info, "ble probe \(on ? "on: scanning for 0xFE30 alone" : "off")")
                    core.rescan()
                }
            }

            /// Knit left the front. While the probe is on, the scan starts again, so that what it matches from now on
            /// is a new discovery for a scan in the background.
            public func backgrounded() {
                core.onQueue { core in
                    guard core.probe.isOn else {
                        return
                    }
                    core.probe.leftFront(now: core.clock.wallMilliseconds())
                    core.rescan()
                }
            }

            /// The probe as it stands.
            public func probeReport() async -> ScanProbe {
                await withCheckedContinuation { continuation in
                    core.onQueue { core in
                        core.probe.learn { uuid in core.gatt.payload(of: RadioAddress(uuid.uuidString))?.nodeId.string }
                        continuation.resume(returning: core.probe)
                    }
                }
            }
        }

        extension BLECore {
            /// Records an advert the probe's scan matched.
            func probeSaw(_ peripheral: CBPeripheral, _ advertisement: [String: Any], rssi: Int) {
                let address = RadioAddress(peripheral.identifier.uuidString)
                let node = (BLEAdvert.payload(advertisement) ?? gatt.payload(of: address))?.nodeId.string
                let now = clock.wallMilliseconds()
                if let line = probe.saw(peripheral.identifier, advertisement, node: node, rssi: rssi, now: now) {
                    log.log(.info, line)
                }
            }
        }
    #endif
#endif
