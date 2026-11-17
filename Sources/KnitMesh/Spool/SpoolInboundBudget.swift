/// What one connection's reader may post into ``Mesh`` before it waits (ADR 2026-11.adrq, P4b1, this port's own rule): a
/// bucket of ``records`` records and ``bytes`` bytes as a burst, each refilling in full over ``refillMilliseconds``, text
/// messages included. A record is charged once it is read, so the bytes may go below zero by one record; the reader waits
/// until a record and a byte are back.
internal struct SpoolInboundBudget: Sendable, Equatable {
    /// The burst, in records.
    static let records = 64
    /// The burst, in bytes.
    static let bytes = 1 << 20
    /// How long an empty bucket takes to fill.
    static let refillMilliseconds: Int64 = 1000

    private(set) var recordsLeft = Double(Self.records)
    private(set) var bytesLeft = Double(Self.bytes)
    private var refilledAt: Int64

    /// A full bucket at `now`.
    init(now: Int64) {
        refilledAt = now
    }

    /// Charges one record of `count` bytes at `now`. Answers whether the reader may read on at once.
    mutating func charge(bytes count: Int, now: Int64) -> Bool {
        refill(now)
        recordsLeft -= 1
        bytesLeft -= Double(max(count, 0))
        return hasRoom
    }

    /// Whether the reader may read on.
    var hasRoom: Bool { recordsLeft >= 1 && bytesLeft >= 1 }

    /// Whether the reader may read on at `now`, after the refill.
    mutating func hasRoom(now: Int64) -> Bool {
        refill(now)
        return hasRoom
    }

    /// When the reader may read on: the last refill when it already may, and otherwise when the refill since brings a
    /// record and a byte back.
    var readyAt: Int64 {
        let recordWait = max(1 - recordsLeft, 0) / Double(Self.records)
        let byteWait = max(1 - bytesLeft, 0) / Double(Self.bytes)
        let wait = (min(max(recordWait, byteWait), 1) * Double(Self.refillMilliseconds)).rounded(.up)
        return SpoolSession.later(refilledAt, by: Int64(wait))
    }

    private mutating func refill(_ now: Int64) {
        guard now > refilledAt else {
            // A clock that went back starts the interval again from here.
            refilledAt = min(refilledAt, now)
            return
        }
        let (elapsed, overflow) = now.subtractingReportingOverflow(refilledAt)
        let share = overflow ? 1 : min(Double(elapsed) / Double(Self.refillMilliseconds), 1)
        recordsLeft = min(recordsLeft + share * Double(Self.records), Double(Self.records))
        bytesLeft = min(bytesLeft + share * Double(Self.bytes), Double(Self.bytes))
        refilledAt = now
    }
}

/// What one relay's pushes may cost in an hour (ADR 2026-11.adrq, P4b1, this port's own rule), beside ``SpoolIntake``'s
/// pulls: ``maxPushedBytes`` an hour, each push charged its encoded record's size when it goes, on the monotonic clock,
/// and nothing starts the hour over but the hour. And the ids this relay stored from us in the hour (``pushedOk``), which
/// no round pushes again inside it: a spool that forgets what it acknowledged costs one upload a blob an hour, not one a
/// round. A scope the relay sheds (its `digest` falls to no blob) forgets its ids at once, so its frames are pushed again.
internal struct SpoolUpload: Sendable, Equatable {
    /// The pushed bytes one relay may cost in a window.
    static let maxPushedBytes = 16 << 20
    /// The window, an hour.
    static let windowMilliseconds = SpoolIntake.windowMilliseconds
    /// The most ids remembered as stored.
    static let maxRemembered = 4096

    private var windowStart: Int64?
    /// Bytes charged in the current window.
    private(set) var bytes = 0
    private struct Stored: Sendable, Equatable {
        let scope: SpoolID
        let at: Int64
    }

    private var storedAt: [SpoolID: Stored] = [:]
    private var order: [SpoolID] = []

    /// Whether a push of `count` bytes fits what the hour has left at `now`.
    mutating func fits(_ count: Int, now: Int64) -> Bool {
        roll(now)
        return count <= Self.maxPushedBytes - bytes
    }

    /// Charges a push of `count` bytes.
    mutating func charge(_ count: Int, now: Int64) {
        roll(now)
        bytes = min(bytes + max(count, 0), Self.maxPushedBytes)
    }

    /// The relay stored `id` in `scope` at `now`.
    mutating func stored(_ id: SpoolID, in scope: SpoolID, now: Int64) {
        if storedAt.updateValue(Stored(scope: scope, at: now), forKey: id) == nil {
            order.append(id)
        }
        while order.count > Self.maxRemembered {
            storedAt[order.removeFirst()] = nil
        }
    }

    /// Whether the relay stored `id` from us within the hour before `now`.
    func storedRecently(_ id: SpoolID, now: Int64) -> Bool {
        guard let at = storedAt[id]?.at else {
            return false
        }
        let (elapsed, overflow) = now.subtractingReportingOverflow(at)
        return !overflow && elapsed >= 0 && elapsed < Self.windowMilliseconds
    }

    /// The relay let `scope` go: what it stored there is pushed again (P3b's shed rule).
    mutating func forget(scope: SpoolID) {
        let gone = Set(storedAt.filter { $0.value.scope == scope }.keys)
        guard !gone.isEmpty else {
            return
        }
        storedAt = storedAt.filter { !gone.contains($0.key) }
        order.removeAll { gone.contains($0) }
    }

    private mutating func roll(_ now: Int64) {
        if let start = windowStart, now >= start {
            let (elapsed, overflow) = now.subtractingReportingOverflow(start)
            if !overflow, elapsed < Self.windowMilliseconds {
                return
            }
        }
        windowStart = now
        bytes = 0
    }
}
