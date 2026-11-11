/// What an iPhone's GATT server holds, and the next step toward what it should (ADR 2026-11.prsp, "The aired form is the
/// GATT payload"): KnitBLE keeps one on its CoreBluetooth queue and carries out the steps, adding and removing the
/// services by the serials named here.
///
/// - **Clear,** the server holds today's one combined `0xFE30` service, the payload with the doorbell beside it, since a
///   pinned Android reads a clear payload only from the first `0xFE30` service. Each new value stops advertising, removes
///   every service and adds the new one, and advertising starts at its `didAdd`, as `BLECore.serve()` did before this type.
/// - **Blinding,** it holds two `0xFE30` primaries. The doorbell's (D) holds the doorbell alone, is added first at each
///   bring-up, before the L2CAP listener is published (``mayPublish``), and goes only at a stop, a power-off or a flip. The
///   payload's (P) holds the payload alone, and a rotation replaces it: the new P is added, and the old one removed by
///   reference once the new one's `didAdd` lands. Every ring client looks the doorbell up once and writes to that handle
///   with no response (Android's `BleDoorbell.write`, KnitBlueZ's `writeDoorbell`), and Android hears of a services change
///   only from API 31, and only if iOS indicates it: a doorbell that moved at each rotation would lose every later ring on
///   the link, unseen.
/// - **Advertising** starts once a payload is served: at the first P's `didAdd`, which comes after D's, or the combined
///   service's. A rotation keeps it up, and the L2CAP channel is never republished for one: a republish has flipped the PSM
///   (`bf171e6`).
/// - **One split add is in flight at a time,** so each `didAdd` is matched to its own service. A failed P keeps the old
///   one, and a failed add is tried again at the first radio event ``retryMilliseconds`` after it (``wantsRetry``), not
///   at the next slot.
/// - **A process clears the server once** at its first power-on, before it adds anything: a restoration relaunch hands back
///   the last process's services, which may hold the clear id from before a switch flip, and iOS keeps serving them until
///   then. A power-off or a stop forgets what is served, and the next bring-up clears again.
public struct GattServing: Sendable, Equatable {
    /// How long a failed split add waits before the next radio event tries it again: no busy loop at every advert.
    public static let retryMilliseconds: Int64 = 1000

    /// The services the server holds for a form.
    public enum Layout: Sendable, Equatable {
        /// One service, the payload and the doorbell: a clear form.
        case combined
        /// The doorbell's service and the payload's: a blinded form.
        case split
    }

    /// What a service holds.
    public enum Role: Sendable, Equatable {
        /// The payload and the doorbell.
        case combined
        /// The doorbell alone (D).
        case doorbell
        /// The payload alone (P).
        case payload
    }

    /// One service this process asked for.
    public struct Service: Sendable, Equatable {
        /// Its number, unique in the process, by which its `didAdd` and a removal name it.
        public let serial: UInt64
        /// What it holds.
        public let role: Role
        /// The payload's value; `nil` for the doorbell's service.
        public let value: [UInt8]?

        /// Service `serial`, holding what `role` says, with the payload `value`.
        public init(serial: UInt64, role: Role, value: [UInt8]?) {
            self.serial = serial
            self.role = role
            self.value = value
        }
    }

    /// What the radio asks of the peripheral manager, in order.
    public enum Step: Sendable, Equatable {
        /// `stopAdvertising()`.
        case stopAdvertising
        /// `removeAllServices()`: only at a process's first power-on and when a value replaces the combined service.
        case removeAll
        /// `add(_:)` a service built for the step's role and value, kept under its serial for its `didAdd` and removal.
        case add(Service)
        /// `remove(_:)` the service kept under the step's serial.
        case remove(Service)
        /// `startAdvertising(_:)` the `0xFE30` UUID alone.
        case startAdvertising
    }

    /// The payload the link manager wants served, while the listener holds its PSM.
    public struct Wanted: Sendable, Equatable {
        public let value: [UInt8]
        /// Whether bytes 1–16 are a tag (``KnitWire/AdvertPayload/blinded``), which serves the split layout.
        public let blinded: Bool

        /// The value `value`, blinded or not.
        public init(value: [UInt8], blinded: Bool) {
            self.value = value
            self.blinded = blinded
        }

        /// The layout it is served in.
        public var layout: Layout { blinded ? .split : .combined }
    }

    /// The layout the last wanted value asked for, or a restoration's: what a bring-up builds before the link manager says.
    public private(set) var layout: Layout?
    /// The doorbell's service, once its `didAdd` landed.
    public private(set) var doorbell: Service?
    /// The payload's service, once its `didAdd` landed.
    public private(set) var payload: Service?
    /// The combined service asked for, and whether its `didAdd` landed.
    public private(set) var combined: Service?
    /// Whether the combined service's `didAdd` landed.
    public private(set) var combinedUp = false
    /// The split add in flight.
    public private(set) var pending: Service?
    /// Whether this process asked to advertise and has not asked to stop since.
    public private(set) var advertising = false
    /// When a failed split add may be tried again.
    public private(set) var retryAt: Int64?
    /// Whether the server holds only what this type knows of: false until the first power-on clears it, and again after a
    /// power-off or a stop.
    public private(set) var cleared = false
    private var doorbellFailed = false
    private var nextSerial: UInt64 = 1

    /// A server this process has not touched.
    /// A server this process has not touched, which brings up the split layout first when the radio `expectsBlinding`: a
    /// cold launch whose persisted switch blinds puts D up before the listener, as a restoration's services do
    /// (``restored(knitServices:)``). The link manager's first advert, or a flip, still decides the layout served.
    public init(expectsBlinding: Bool = false) {
        layout = expectsBlinding ? .split : nil
    }

    /// Whether the radio may publish its L2CAP listener: once D is served while blinding, so a peer that dials the PSM it
    /// read finds the doorbell, or after D failed, so a failing add never keeps the iPhone from listening.
    public var mayPublish: Bool {
        layout != .split || doorbell != nil || doorbellFailed
    }

    /// Whether a failed split add waits for the next radio event.
    public var wantsRetry: Bool { retryAt != nil }

    /// A restoration relaunch handed back `knitServices` `0xFE30` services: two or more were a blinding process's, so this
    /// one brings up D first too, before it hears what the link manager wants. Fewer leave the layout as it was: one says
    /// only that the last process was clear, while a radio that expects blinding reads the switch as it is now, and
    /// following the old process there would publish the listener before D again.
    public mutating func restored(knitServices: Int) {
        if knitServices > 1 {
            layout = .split
        }
    }

    /// The oldest add this server still waits on an answer for: the split add in flight, or the combined add before its
    /// `didAdd`. An answer older than it belongs to an add a removal overtook.
    public var oldestOwed: UInt64? {
        [pending?.serial, combinedUp ? nil : combined?.serial].compactMap(\.self).min()
    }

    /// The steps toward serving `wanted`, or toward the bring-up's layout while nothing is wanted, at `now` on the
    /// monotonic clock. Call it only while the radio runs and is powered on.
    public mutating func serve(_ wanted: Wanted?, now: Int64) -> [Step] {
        var steps: [Step] = []
        if !cleared {
            cleared = true
            advertising = false
            steps += [.stopAdvertising, .removeAll]
        }
        if let wanted {
            layout = wanted.layout
        }
        switch layout {
        case .combined:
            return steps + serveCombined(wanted)
        case .split:
            return steps + serveSplit(wanted, now: now)
        case nil:
            return steps
        }
    }

    /// The service `serial` was added, or failed to be (`ok`), at `now`: the steps that follow, toward `wanted`.
    public mutating func added(_ serial: UInt64, ok: Bool, wanted: Wanted?, now: Int64) -> [Step] {
        if let combined, combined.serial == serial {
            guard ok else {
                // As before the split layout: the next serve adds it again. A flip to blinding made while it was in flight
                // goes on at once.
                self.combined = nil
                return layout == .split ? serve(wanted, now: now) : []
            }
            combinedUp = true
            advertising = true
            // Nothing more while clear; a flip to blinding made while it was in flight goes on now that it can be removed.
            return [.startAdvertising] + serve(wanted, now: now)
        }
        guard let added = pending, added.serial == serial else {
            // A service a stop, a power-off or a flip already let go of.
            return []
        }
        pending = nil
        guard ok else {
            retryAt = now + Self.retryMilliseconds
            doorbellFailed = doorbellFailed || added.role == .doorbell
            return []
        }
        retryAt = nil
        var steps: [Step] = []
        if added.role == .doorbell {
            doorbell = added
            doorbellFailed = false
        } else {
            if let old = payload {
                steps.append(.remove(old))
            }
            payload = added
            if !advertising {
                advertising = true
                steps.append(.startAdvertising)
            }
        }
        return steps + serve(wanted, now: now)
    }

    /// The radio stopped, after removing every service and advertising, or the manager went off, which clears the server:
    /// nothing is served, and the next bring-up clears again and starts from the last layout.
    public mutating func forgetServices() {
        doorbell = nil
        payload = nil
        combined = nil
        combinedUp = false
        pending = nil
        advertising = false
        retryAt = nil
        doorbellFailed = false
        cleared = false
    }

    // MARK: The two layouts

    /// Today's combined service, replaced whole for every new value.
    private mutating func serveCombined(_ wanted: Wanted?) -> [Step] {
        guard pending == nil, let wanted, combined?.value != wanted.value else {
            // A split add in flight lands first; nothing wanted, or this value served, has nothing to do.
            return []
        }
        // A flip from blinding: removing every service takes D and P with the rest.
        doorbell = nil
        payload = nil
        retryAt = nil
        doorbellFailed = false
        let service = make(.combined, wanted.value)
        combined = service
        combinedUp = false
        advertising = false
        return [.stopAdvertising, .removeAll, .add(service)]
    }

    /// D first, then a P for the wanted value beside it, one add at a time.
    private mutating func serveSplit(_ wanted: Wanted?, now: Int64) -> [Step] {
        guard pending == nil, retryAt.map({ now >= $0 }) ?? true else {
            return []
        }
        var steps: [Step] = []
        if let combined {
            guard combinedUp else {
                // Its add lands first, so the removal names a service the server holds.
                return []
            }
            // A flip to blinding: no reader may find the server between the two layouts.
            self.combined = nil
            combinedUp = false
            advertising = false
            steps += [.stopAdvertising, .remove(combined)]
        }
        guard doorbell != nil else {
            let service = make(.doorbell, nil)
            pending = service
            return steps + [.add(service)]
        }
        guard let wanted, payload?.value != wanted.value else {
            return steps
        }
        let service = make(.payload, wanted.value)
        pending = service
        return steps + [.add(service)]
    }

    private mutating func make(_ role: Role, _ value: [UInt8]?) -> Service {
        defer { nextSerial += 1 }
        return Service(serial: nextSerial, role: role, value: value)
    }
}
