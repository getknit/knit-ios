#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh

    // MARK: The L2CAP listener and the peripheral manager behind it

    extension BLECore {
        /// Whether `manager` is the radio's peripheral manager, and not one a recycle let go of. While the property is still
        /// `nil` a manager is being made, and anything it says in its initializer is its own.
        func isCurrent(_ manager: CBPeripheralManager) -> Bool {
            peripheralManager.map { $0 === manager } ?? true
        }

        /// Whether a state change came while the manager was still being made, before the radio held it: it is read again
        /// once the radio does, so a fresh manager's `.poweredOn` never spends the latch with nothing to publish on.
        func rereadOnceHeld() -> Bool {
            guard peripheralManager == nil else {
                return false
            }
            queue.async { [weak self] in
                if let self, let held = peripheralManager {
                    peripheralManagerDidUpdateState(held)
                }
            }
            return true
        }

        /// How long after a recycle a manager still not powered on is logged: nothing else bounds that wait.
        static let recycledPowerOnWarningSeconds = 10

        /// Unpublishes a PSM, and bounds the wait for the answer, which holds the next publish back
        /// (``ListenerPublication``). A wait that runs out recycles the peripheral manager (knit/knit-ios#53), unless a
        /// recycle is already under way, whose manager the publish then waits for. The deadline runs on uptime, and
        /// nothing resumes a suspended Knit to run it, so there the recycle or the publish waits until the process runs
        /// again. A stop and a start come from Settings or the bridge, in the foreground, where it fires on time.
        func awaitUnpublish(_ unpublish: ListenerPublication.Unpublish, on manager: CBPeripheralManager) {
            #if DEBUG
                if skipsNextUnpublish {
                    skipsNextUnpublish = false
                    log.log(.info, "ble left the unpublish of PSM \(unpublish.psm) unsent, as the debug bridge asked")
                } else {
                    manager.unpublishL2CAPChannel(unpublish.psm)
                }
            #else
                manager.unpublishL2CAPChannel(unpublish.psm)
            #endif
            let wait = ListenerPublication.answerWaitMilliseconds
            queue.asyncAfter(deadline: .now() + .milliseconds(wait)) { [weak self] in
                self?.unpublishWaitEnded(unpublish, after: wait)
            }
        }

        /// The deadline ``awaitUnpublish(_:on:)`` armed came due. The recycle runs whether or not the radio runs, since the
        /// next start would otherwise publish on the manager that went quiet. The prefix up to `so ` is frozen
        /// (`scripts/interop.py`'s listener gate).
        private func unpublishWaitEnded(_ unpublish: ListenerPublication.Unpublish, after wait: Int) {
            switch listener.waitEnded(unpublish.wait) {
            case .answered:
                return
            case .recycle(let expired, let ordinal):
                log.log(.warning, "ble heard no answer to \(expired) unpublishes in \(wait) ms, so recycles the peripheral manager")
                recyclePeripheralManager(ordinal)
            case .publish(let expired):
                // A recycle is under way, so the publish waits for its manager's power-on.
                log.log(.warning, "ble heard no answer to \(expired) unpublishes in \(wait) ms, so publishes")
                resume()
            }
        }

        /// The process's first peripheral manager, or one that replaces it (``recyclePeripheralManager(_:)``).
        func makePeripheralManager(recycled: Bool) -> CBPeripheralManager {
            var options: [String: Any] = [CBPeripheralManagerOptionShowPowerAlertKey: false]
            #if os(iOS)
                if let restoreId = recycled ? Self.recycledPeripheralRestoreId : Self.peripheralRestoreId {
                    options[CBPeripheralManagerOptionRestoreIdentifierKey] = restoreId
                }
            #endif
            return CBPeripheralManager(delegate: self, queue: queue, options: options)
        }

        /// Replaces the peripheral manager after an unpublish it never answered (``ListenerPublication/Expiry/recycle(expired:ordinal:)``).
        /// In run `3a7576` the publish that followed such an unpublish on the same manager was answered with a PSM bluetoothd
        /// had no endpoint for, and only a relaunch, which made new managers, brought the listener back (knit/knit-ios#53).
        /// Only the peripheral manager: the central and the links it dialed stay up. The old manager is cut off before
        /// anything else, so none of its answers reach this radio, and every reference to it goes, with what it served.
        /// The new one starts `.unknown`, and its first `.poweredOn` resumes the radio (``peripheralManagerDidUpdateState(_:)``).
        /// The radio's state stays what it was, so the link manager forgets nothing.
        func recyclePeripheralManager(_ ordinal: Int) {
            if let old = peripheralManager {
                old.delegate = nil
                if old.state == .poweredOn {
                    old.stopAdvertising()
                    old.removeAllServices()
                }
            }
            peripheralManager = nil
            // `forgetServices()` keeps the adds owed for a power-off, whose answers still come; the old manager's never do.
            awaitingAdd.removeAll()
            forgetServices()
            let fresh = makePeripheralManager(recycled: true)
            peripheralManager = fresh
            log.log(.info, "ble recycled the peripheral manager, \(ordinal) in this process")
            let made = ObjectIdentifier(fresh)
            let warning = Self.recycledPowerOnWarningSeconds
            queue.asyncAfter(deadline: .now() + .seconds(warning)) { [weak self] in
                guard let self, let current = peripheralManager, ObjectIdentifier(current) == made, listener.recycling else {
                    return
                }
                let state = current.state.rawValue
                log.log(.warning, "ble found the recycled peripheral manager still not powered on \(warning) s in (\(state))")
            }
        }
    }
#endif
