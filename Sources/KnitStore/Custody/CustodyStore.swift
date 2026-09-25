import KnitWire

/// The frames this node carries for store-and-forward (`ForwardStore.kt` in knit-next).
///
/// Every time is the wall clock in epoch milliseconds, because custody expires at the originator's `sentAt`
/// plus a TTL. An implementation applies ``CustodyRules`` on every ``store(_:origin:now:)``, and every read
/// sees live frames only.
public protocol CustodyStore: AnyObject, Sendable {
    /// Takes `frame` into custody and trims every bucket it lands in to its quota. Returns `false` only when
    /// the frame was refused, dead on arrival or dated too far ahead, so the caller does no follow-on work. A
    /// frame already held is left as it is and answers `true`.
    @discardableResult
    func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> Bool

    /// Every live frame, the most recently received first: the order a digest answer serves them in.
    func liveFrames(now: Int64) -> [CarriedFrame]

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

    /// Drops every frame past its expiry and answers how many. Pure storage housekeeping: expired frames were
    /// already invisible to every read.
    @discardableResult
    func sweepExpired(now: Int64) -> Int
}

extension CustodyStore {
    /// The FNV fold over the live ids (`StoreDigest.current`), whose low 32 bits the advert carries as its digest
    /// cue.
    public func fingerprint(now: Int64) -> UInt64 {
        StoreDigest.fingerprint(of: liveIds(now: now))
    }
}
