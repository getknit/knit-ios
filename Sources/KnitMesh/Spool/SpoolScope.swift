import KnitCrypto
import KnitWire

/// One DM scope as the plane carries it (`Scope`, knit-next `ScopeFrames.kt:37-73` at `0832b8462`, the DM fields alone):
/// its keys, the peer it is shared with, and whether it drains a replaced root. Every per-scope state keys on ``id`` alone
/// (P2's review), so a pair's live and retiring scopes are two scopes, and nothing per scope names the peer but this value.
///
/// Kotlin's `resetInit` is not here: our own unanswered reset exports nothing in this port yet (ADR 2026-11.adrq), so it is
/// `null` on every scope, and ``ScopeFrames/mayRefill(_:me:scope:)`` reads it so.
///
/// It prints the id's prefix and nothing of the peer, so no log line puts a scope id beside a node id.
internal struct SpoolScope: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The scope's keys; ``id`` is their id.
    let keys: ScopeKeys
    /// The scope id, as the spool knows it.
    let id: SpoolID
    /// The other member.
    let peer: NodeId
    /// Whether this is the scope of a root the session replaced, pulled and never refilled (C-3.1-2, C-3.1-3).
    let retiring: Bool
    /// When a retiring scope's drain ends (``RatchetSessions/DMScopes/retiringUntil``, wall milliseconds), `nil` for a
    /// live one. Compared in `==`, so a drain that moves re-adopts the table (P4b2).
    let retiringUntil: Int64?

    /// The scope, or `nil` for keys whose id is not 32 bytes, which ``ScopeKeys`` never holds.
    static func of(_ keys: ScopeKeys, peer: NodeId, retiring: Bool, retiringUntil: Int64?) -> Self? {
        SpoolID(keys.id).map { Self(keys: keys, id: $0, peer: peer, retiring: retiring, retiringUntil: retiringUntil) }
    }

    private init(keys: ScopeKeys, id: SpoolID, peer: NodeId, retiring: Bool, retiringUntil: Int64?) {
        self.keys = keys
        self.id = id
        self.peer = peer
        self.retiring = retiring
        self.retiringUntil = retiringUntil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.peer == rhs.peer && lhs.retiring == rhs.retiring && lhs.retiringUntil == rhs.retiringUntil
    }

    var description: String { retiring ? "\(id) (retiring)" : "\(id)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A relay as the plane names it: a number the app gives each one it dials, never its URL, which a private relay's token
/// rides in (ADR 2026-11.adrq).
public struct SpoolRelayHandle: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The app's number for the relay.
    public let number: Int

    /// The relay the app numbers `number`.
    public init(number: Int) {
        self.number = number
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }

    public var description: String { "relay \(number)" }
}

/// The two clocks the heal loop reads: the monotonic one for its timers (ADR 2026-09.gq84), as ``SpoolSession`` does, and
/// the wall clock for what a frame's own time decides (`sentAt`, custody's reads, a stamp's UTC day).
internal struct SpoolNow: Sendable, Equatable {
    /// Monotonic milliseconds.
    let monotonic: Int64
    /// Epoch milliseconds.
    let wall: Int64
}

/// A stamp the heal loop needs mined (§8): which relay asked for it, for which scope, for which UTC day and at how many
/// bits, under a serial the plane draws from one counter per engine (P4b2). The serial is the request's identity: an
/// identical request asked again is a new one, and an answer clears the heal's search only when its serial matches.
///
/// ``SpoolMiner`` takes it, answers ``ScopeHeal/stampMined(_:_:session:now:)`` exactly once, or drops it when the heal's
/// own ``ScopeHeal/Output/cancelMining(_:)`` names it. A search outlives the connection that asked for it (P3b): only a
/// cancel, the plane's pause or a removed relay stops one.
internal struct SpoolMiningRequest: Hashable, Sendable, CustomStringConvertible {
    let serial: Int64
    let relay: SpoolRelayHandle
    let scope: SpoolID
    let day: Int64
    let bits: Int

    var description: String { "stamp \(serial): \(relay) \(scope) day \(day), \(bits) bits" }
}

/// How a stamp search ended, as the heal hears it (P4b2). There is no cancelled answer: a search the miner stops is resumed
/// or dropped inside ``SpoolMiner``, and a request ends either in one of these or in its own cancel.
internal enum SpoolStampAnswer: Sendable, Equatable {
    /// A stamp, with the leading zero bits its digest actually has, at least the request's.
    case found(counter: Int64, bits: Int)
    /// No counter below ``SpoolPow/maxTries`` meets the request's bits: the (scope, day, bits) is settled for the day.
    case exhausted
    /// The engine's budget or a share of it cannot hold the search; the scope parks this long (at least
    /// ``SpoolSession/minParkMilliseconds``, at most a day).
    case overBudget(parkMilliseconds: Int64)
}

/// A set of blob ids that remembers its insertion order and holds at most ``bound``, the oldest going first (`remember`
/// and `account`, `ScopeSync.kt:3168-3178`, `:3219-3228`). What the heal loop's accounted, invalid and unpushable sets are.
internal struct BoundedIDSet: Sendable, Equatable {
    /// The size every per-scope set here keeps (`BLOB_SET_MAX`).
    static let defaultBound = 512

    let bound: Int
    private(set) var members: Set<SpoolID> = []
    private var order: [SpoolID] = []

    /// An empty set of ``defaultBound``.
    init() {
        self.init(bound: Self.defaultBound)
    }

    /// An empty set of `bound`, at least one.
    init(bound: Int) {
        self.bound = max(bound, 1)
    }

    /// How many ids it holds, and whether none. Read by the tests alone, through `@testable`, which `swiftlint analyze`
    /// (Sources only) does not see.
    var count: Int { order.count } // swiftlint:disable:this unused_declaration
    var isEmpty: Bool { order.isEmpty } // swiftlint:disable:this unused_declaration
    /// The ids, oldest first.
    var ordered: [SpoolID] { order }

    func contains(_ id: SpoolID) -> Bool {
        members.contains(id)
    }

    /// Adds `id`, dropping the oldest at the bound. Answers whether it was new.
    @discardableResult
    mutating func insert(_ id: SpoolID) -> Bool {
        guard !members.contains(id) else {
            return false
        }
        while order.count >= bound {
            members.remove(order.removeFirst())
        }
        members.insert(id)
        order.append(id)
        return true
    }

    /// Drops `id`. Answers whether it was here.
    @discardableResult
    mutating func remove(_ id: SpoolID) -> Bool {
        guard members.remove(id) != nil else {
            return false
        }
        order.removeAll { $0 == id }
        return true
    }

    /// Drops every id `drop` says to. Answers whether any went.
    @discardableResult
    mutating func removeAll(where drop: (SpoolID) -> Bool) -> Bool {
        let gone = order.filter(drop)
        guard !gone.isEmpty else {
            return false
        }
        let goneSet = Set(gone)
        order.removeAll { goneSet.contains($0) }
        members.subtract(goneSet)
        return true
    }
}
