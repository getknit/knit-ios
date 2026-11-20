import KnitWire

/// The frames this node carries for store-and-forward (`ForwardStore.kt` in knit-next).
///
/// Every time is the wall clock in epoch milliseconds, because custody expires at the originator's `sentAt`
/// plus a TTL. An implementation applies ``CustodyRules`` on every ``store(_:origin:now:carry:)``, and every read
/// sees live frames only. Below the row cap two stores holding the same frames keep the same ones; at the cap the global
/// trim reads this node's carry (``CustodyCarry``, the `custody-carry-policy` contract, §5).
public protocol CustodyStore: AnyObject, Sendable {
    /// The limits every rule here runs under. The engine reads ``CustodyLimits/maxProfileSignedBytes`` from here for the
    /// profiles it refuses before reading them, so the door and custody always bound the same frames.
    var limits: CustodyLimits { get }

    /// Takes `frame` into custody and trims every bucket it lands in to its quota, after ``CustodyRules/admission(of:now:limits:)``
    /// admits it. Answers whether the frame is held after its own write, which the trims may have undone, and whether
    /// custody changed (`ForwardStore.store` at knit-next `e0cbb842a`). A frame whose id a row already holds is left as it
    /// is and answers held and unchanged. A write that fails answers ``CustodyRefusal/writeFailed``. Only the global cap's
    /// choice of row reads `carry` (``CustodyRules/evictions(after:among:limits:carry:)``).
    @discardableResult
    func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64, carry: some CustodyCarry) -> CustodyStoreResult

    /// Every live frame, the most recently received first: the order a digest answer serves them in.
    func liveFrames(now: Int64) -> [CarriedFrame]

    /// Every live frame as a digest answer picks from it, in ``liveFrames(now:)``'s order, with nothing decoded from a
    /// frame's bytes (ADR 2026-10.f5zs). A row whose bytes no longer decode is listed here, as in ``liveIds(now:)``, and
    /// ``frame(_:now:)`` then answers `nil` for it.
    func liveIndex(now: Int64) -> [CustodyIndexEntry]

    /// Every live frame's id: what a `DIGEST` record lists.
    func liveIds(now: Int64) -> [String]

    /// The live frame `id`, or `nil` when it is not held or has expired.
    func frame(_ id: String, now: Int64) -> CarriedFrame?

    /// Whether a row holds `id`, expired or not. A frame held but expired is not stored again before the sweep.
    func contains(_ id: String) -> Bool

    /// The carried frame's recipient, or `nil` when it names none or is not held: the guard on a receipt's purge.
    func recipient(of id: String) -> String?

    /// Drops `id`, if held.
    func remove(_ id: String)

    /// Drops every frame past its expiry, every frame whose `signed` is longer than ``CustodyLimits/maxSignedBytes``, and
    /// every profile whose `signed` is longer than ``CustodyLimits/maxProfileSignedBytes``
    /// (``CustodyRules/isOversizeProfile(type:signedCount:limits:)``), and answers how many, each row counted once
    /// (`ForwardRepository.sweepExpired` at knit-next `ce56fec6e`). The expiry delete is pure storage housekeeping:
    /// expired frames were already invisible to every read. The two size deletes can move the live set: they reclaim what
    /// a build without either cap stored. Each is a function of the row alone, so every upgraded node deletes the same
    /// rows, and once those are gone it finds nothing. Until a node's first sweep after the upgrade, such a row still
    /// counts toward the quotas.
    @discardableResult
    func sweepExpired(now: Int64) -> Int
}

extension CustodyStore {
    /// ``store(_:origin:now:carry:)`` knowing of no holder (``NoCustodyCarry``): the old global key.
    @discardableResult
    public func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> CustodyStoreResult {
        store(frame, origin: origin, now: now, carry: NoCustodyCarry())
    }

    /// The FNV fold over the live ids (`StoreDigest.current`), whose low 32 bits the advert carries as its digest
    /// cue.
    public func fingerprint(now: Int64) -> UInt64 {
        StoreDigest.fingerprint(of: liveIds(now: now))
    }
}

/// What ``CustodyStore/store(_:origin:now:carry:)`` did with a frame.
///
/// "Held" and "changed" differ under the trims: one write can evict an older row and then the frame itself, as when the
/// sender trim takes an older frame and the group trim takes the new one. Android answers only the first
/// (`ForwardRepository.store` returns `kept`, knit-next ADR 2026-10.7mqm), so a frame its own write evicted pulls no
/// attachment. The engine reads the second, to re-read the advert's digest cue.
public struct CustodyStoreResult: Sendable, Equatable {
    /// Whether custody holds the frame after its write: the shared vector's `kept`. A frame already held answers `true`.
    public var held: Bool
    /// Whether the frame went in or any row went out. A frame that went in and was evicted by its own write answers `true`
    /// here and `false` for ``held``: the cue is re-read for nothing, which costs nothing.
    public var changed: Bool
    /// Why the frame was refused, when it was.
    public var refusal: CustodyRefusal?
    /// The ids the write's trims removed, the frame's own among them when its own write evicted it: the rows whose carry
    /// ledger entries die with them.
    public var evicted: [String]

    /// Makes an answer.
    public init(held: Bool, changed: Bool, refusal: CustodyRefusal? = nil, evicted: [String] = []) {
        self.held = held
        self.changed = changed
        self.refusal = refusal
        self.evicted = evicted
    }

    /// A frame refused for `reason`: not held, and nothing changed.
    public static func refused(_ reason: CustodyRefusal) -> Self {
        Self(held: false, changed: false, refusal: reason)
    }

    /// A frame whose id a row already held: left as it is.
    public static let alreadyHeld = Self(held: true, changed: false)

    /// A frame written, and `evicted` the ids its write's trims removed: held unless its own id, by its bytes, is among
    /// them.
    public static func inserted(_ id: String, evicted: [String]) -> Self {
        let key = ExactKey(id)
        return Self(held: !evicted.contains { ExactKey($0) == key }, changed: true, evicted: evicted)
    }
}
