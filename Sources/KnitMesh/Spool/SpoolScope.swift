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

    /// The scope, or `nil` for keys whose id is not 32 bytes, which ``ScopeKeys`` never holds.
    static func of(_ keys: ScopeKeys, peer: NodeId, retiring: Bool) -> Self? {
        SpoolID(keys.id).map { Self(keys: keys, id: $0, peer: peer, retiring: retiring) }
    }

    private init(keys: ScopeKeys, id: SpoolID, peer: NodeId, retiring: Bool) {
        self.keys = keys
        self.id = id
        self.peer = peer
        self.retiring = retiring
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.peer == rhs.peer && lhs.retiring == rhs.retiring
    }

    var description: String { retiring ? "\(id) (retiring)" : "\(id)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A relay as the plane names it: a number the app gives each one it dials, never its URL, which a private relay's token
/// rides in (ADR 2026-11.adrq).
internal struct SpoolRelayHandle: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The app's number for the relay.
    let number: Int

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }

    var description: String { "relay \(number)" }
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
/// bits. The caller mines it off the engine and answers ``ScopeHeal/stampMined(_:counter:session:now:)``, and cancels it
/// when ``ScopeHeal/Output/cancelMining(_:)`` names it (P2's review: a cancelled worker cancels its mining).
internal struct SpoolMiningRequest: Hashable, Sendable, CustomStringConvertible {
    let relay: SpoolRelayHandle
    let scope: SpoolID
    let day: Int64
    let bits: Int

    var description: String { "\(relay) \(scope) day \(day), \(bits) bits" }
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
