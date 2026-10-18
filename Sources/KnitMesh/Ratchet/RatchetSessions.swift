public import KnitCrypto
public import KnitStore
public import KnitWire

/// The DM ratchet's session service (`RatchetSessions` in knit-next's `mesh/crypto/ratchet/RatchetSessions.kt`, at
/// `ac491f4c`): the pure ``RatchetEngine`` over a ``RatchetStore``, our identity, and the per-peer floors held in memory
/// (ADR 2026-10.5sk9). With the switch on, the engine opens DM frames through it and sends the resets it seals (phase
/// P5a), seals our DMs through it (phase P5b), our receipts and ticks (phase P5d), and our DM reactions, our sealed
/// profile and the answer a peer's init is owed (phase P5e).
///
/// **One phase, in a store unit.** Android opens in two phases: a peek with no lock feeds moderation, then a commit under
/// its one ratchet mutex, inside a Room transaction, re-runs the engine and writes the session with the message row
/// (`RatchetSessions.kt:19-31`, `:161-221`). This port's engine runs on one actor and moderates after the row is stored,
/// so each call here decides and writes inside one ``StoreTransactor`` unit, whose body carries the caller's own writes
/// (the message row, P5's), and the store is read inside the same unit, so a store that cannot answer fails the unit
/// rather than deciding on its fallback.
///
/// **What it answers.** Every call answers an ``Answer``. ``Answer/settled(_:)`` means the unit ended on its own: it
/// committed as the outermost, or changed nothing, and the floors in memory already moved. ``Answer/joined(_:_:)`` means
/// it ran inside a unit the caller opened: what it made stands only once that outermost unit commits, and the caller then
/// hands the ``Settlement`` to ``settle(_:)``; a frame it sealed may go, and a plaintext it opened may be delivered, only
/// after that. ``Answer/failed`` means a store failed: nothing persisted, and nothing it made may be used. A sealed frame
/// is persisted before it is answered, so the chain it spent is never spent again (ADR 2026-10.5sk9's P4a amendment).
///
/// **The floors held in memory** (`RatchetSessions.kt:97-111`) are the peer's replacements we adopted, when the peer
/// answered our own init, our resets when no session row holds the stamp, and the heuristic's undecryptable frame ids.
/// They die with the process, as Android's do, and each moves only once its unit commits, but for one: a frame the
/// heuristic counts joins its ids at once, as on Android, after the era gate read the session, and only their clearing
/// waits for a commit. `sealResetDm`'s decline reads the persisted `lastResetSentAt`, which survives a restart; the stamp
/// held here is only ``noteUndecryptable(from:frameId:sentAt:now:epochGoneBase:)``'s fallback for a peer with no session.
///
/// Left out: the spool's `exportedRoots` and `rootChanges`, since there is no spool here (ADR 2026-10.5sk9), but for the
/// filter `exportedRoots` applies, which ``confirmedPeers()`` keeps for the sealed profile's fan-out.
public final class RatchetSessions {
    let identity: IdentityKeys
    let store: any RatchetStore
    let transactor: any StoreTransactor
    let engine: RatchetEngine
    /// Where the facade's diagnostics go: a seal X25519 refused, and a reset gate's verdict (`log`, knit-next
    /// `RatchetSessions.kt:45-46` at `4f3cd995`).
    let log: any KnitLog

    /// Per peer, the distinct undecryptable frame ids, oldest first, at most ``RatchetResetPolicy/trackedFrames``
    /// (`undecryptable`, `RatchetSessions.kt:98`). Ids compare by their bytes (ADR 2026-09.jc2x).
    var undecryptable: [NodeId: [ExactKey]] = [:]
    /// Per peer, when we last sealed a reset, for a peer with no session row to hold the stamp (`lastResetSentAt`, `:101`).
    var lastResetSentAt: [NodeId: Int64] = [:]
    /// Per peer, when we last adopted a replacement or lost a race to it (`lastReplacementAt`, `:104`).
    var lastReplacementAt: [NodeId: Int64] = [:]
    /// Per peer, when a session we initiated was confirmed: the peer adopted our init no later than it sealed that answer,
    /// so its replacement floor runs until at least a minute past this (`confirmedAt`, `:106-111`).
    var confirmedAt: [NodeId: Int64] = [:]

    /// A session service for `identity` over `store`, whose units `transactor` runs, logging to `log`. `engine` draws from
    /// the system's generator unless a test or a vector replay passes another.
    public init(
        identity: IdentityKeys,
        store: any RatchetStore,
        transactor: any StoreTransactor,
        engine: RatchetEngine = RatchetEngine(),
        log: any KnitLog = SilentLog()
    ) {
        self.identity = identity
        self.store = store
        self.transactor = transactor
        self.engine = engine
        self.log = log
    }

    /// The session held with `peer`, read outside any unit (`sessionFor`, `RatchetSessions.kt:533-538`), for diagnostics
    /// only and never a decision: a store that cannot answer reads as none. Kotlin's era gate decides on `sessionFor`,
    /// which throws there; here the gate is inside ``noteUndecryptable(from:frameId:sentAt:now:epochGoneBase:)``, which reads the
    /// session in a unit, so a store that cannot answer counts nothing.
    public func session(of peer: NodeId) -> RatchetEngine.SessionState? {
        store.session(peer).map(RatchetRecords.session)
    }

    /// Our epochs for `peer`, the most recently minted first, as `(epoch, createdAt)`: the ground truth for an
    /// `EPOCH_GONE` diagnosis (`debugLocalEpochs`, `RatchetSessions.kt:540-541`).
    public func localEpochs(of peer: NodeId) -> [(epoch: Int, createdAt: Int64)] {
        store.records(of: peer).localEpochs.map { (epoch: $0.epoch, createdAt: $0.createdAt) }
    }

    /// The peers we hold a confirmed session with, in node id order, read in a unit of its own: the filter of
    /// `exportedRoots` (`RatchetSessions.kt:576-591`) without the spool's roots, which is the target set of the sealed
    /// profile's fan-out (`broadcastSealedProfile`, `MeshManager.kt:2845`; phase P5e). `nil` when a store failed, and when
    /// asked inside a caller's unit, where nothing fanned out could go before that unit commits.
    public func confirmedPeers() -> [NodeId]? {
        let unit = transactor.atomically { () -> [NodeId]? in
            store.sessionPeerIds().filter { store.session($0)?.confirmed == true }
        }
        guard case .committed(let peers) = unit else {
            return nil
        }
        return peers
    }

    /// The floors held in memory for `peer`, `nil` where none is held.
    public func floors(for peer: NodeId) -> Floors {
        Floors(
            lastReplacementAt: lastReplacementAt[peer],
            confirmedAt: confirmedAt[peer],
            lastResetSentAt: lastResetSentAt[peer],
            undecryptableIds: undecryptable[peer]?.count ?? 0
        )
    }

    /// Moves the floors held in memory as `settlement` says: what a call answered ``Answer/joined(_:_:)`` leaves for after
    /// the caller's outermost unit commits.
    public func settle(_ settlement: Settlement) {
        let peer = settlement.peer
        if let adopted = settlement.replacementAdoptedAt {
            lastReplacementAt[peer] = adopted
        }
        if let sealed = settlement.resetSealedAt {
            lastResetSentAt[peer] = sealed
        }
        if settlement.clearsUndecryptable {
            undecryptable[peer] = nil
        }
        if settlement.clearsConfirmedAt {
            confirmedAt[peer] = nil
        }
        if let answered = settlement.initAnsweredAt {
            confirmedAt[peer] = answered
        }
    }

    /// Records an undecryptable frame from `peer`, the frame `frameId` signed at `sentAt`, and says whether a reset is due
    /// (`maybeRequestReset` and `noteUndecryptable`, `InboundPipeline.kt:1835-1856` and `RatchetSessions.kt:279-311`):
    /// - **The era gate first.** A unit that only reads takes the session row. A frame authored before the session
    ///   held (``RatchetResetPolicy/isLiveEvidence(sentAt:session:now:)``) counts nothing and never enters the ids, whose
    ///   eight slots a re-served tail would otherwise fill (knit-next ADR 024, `d7487392`). A unit that fails counts
    ///   nothing either: a pre-era frame let in on a store's fallback would re-root on evidence from the era the reset
    ///   abandons. A peer with no session passes, since there is no era to compare with.
    /// - **Then, for an `EPOCH_GONE`, the retired base.** `epochGoneBase` is its header's `pe`. A frame sealed against one
    ///   of our epochs that retention already retired, behind an epoch the peer has sealed against since, is doomed as a
    ///   pre-era frame is, and never enters the ids (``RatchetResetPolicy/isRetiredBase(pe:highestPeAcked:lowestRetained:)``,
    ///   `maybeRequestReset`, knit-next `InboundPipeline.kt:1967-1999` at `4f3cd995`, knit-next ADR 2026-10.9wvr). The
    ///   unit that read the session reads our lowest epoch with it.
    /// - **Then the count.** The id joins the last ``RatchetResetPolicy/trackedFrames`` at once, as on Android, and a
    ///   reset is due at ``RatchetResetPolicy/distinctFrames`` distinct ids, ``RatchetResetPolicy/resetMilliseconds``
    ///   past our last reset: the stamp the unit read from the session row, which survives a restart, or the one held in
    ///   memory for a peer with no session row, whichever is later (`RatchetSessions.kt:308-310`).
    ///
    /// `sentAt` is the envelope's signed stamp exactly as it arrived, never passed through `clampFuture`: Kotlin compares
    /// the raw `env.sentAt` (`InboundPipeline.kt:1897-1899`). A responder's `establishedAt` is the peer's own `init.at`,
    /// so a stamp clamped to our clock would class every live failure from a peer whose clock runs fast as pre-era, and
    /// the heuristic would never fire toward it (knit-next `cf447a9b`).
    ///
    /// The caller gates on what the facade cannot see: an authenticated frame, and a failure in
    /// ``RatchetResetPolicy/triggeringFailures`` from an open that answered ``Answer/settled(_:)``, never
    /// ``Answer/failed``, whose verdict came from a store's fallback. The engine calls it on the drop path, outside any
    /// unit, as Kotlin does (`InboundPipeline.kt:1819-1826`). Inside a caller's unit it counts nothing: a joined open or reset
    /// clears the ids only once that unit commits, where Kotlin clears them as an open commits and as a reset is sealed
    /// (`RatchetSessions.kt:207-211`, `:435`, `:466`), so a frame counted before then would join the abandoned era's ids.
    public func noteUndecryptable(from peer: NodeId, frameId: String, sentAt: Int64, now: Int64, epochGoneBase: Int? = nil) -> Bool {
        // The body answers the row or its absence, never `nil`, which would abandon the unit. The lowest epoch held is
        // read in the same unit, and only for an `EPOCH_GONE`, so the retired-base gate decides on what the store holds.
        let read = transactor.atomically { () -> (RatchetSessionRecord?, Int?)? in
            (store.session(peer), epochGoneBase == nil ? nil : store.lowestLocalEpoch(peer))
        }
        let held: RatchetSessionRecord?
        let lowest: Int?
        switch read {
        case .committed(let rows):
            (held, lowest) = rows
        case .joined, .abandoned, .failed:
            return false
        }
        if let held, !RatchetResetPolicy.isLiveEvidence(sentAt: sentAt, session: RatchetRecords.session(held), now: now) {
            return false
        }
        if let pe = epochGoneBase, let retired = Self.retired(pe, held: held, lowest: lowest) {
            // Kotlin's own line, `InboundPipeline.kt:1986-1993` at `4f3cd995`.
            log.log(
                .info,
                "mesh reset gate: \(frameId) from \(peer) retired epoch pe=\(retired.pe) "
                    + "lowestRetained=\(retired.lowestRetained) highestPeAcked=\(retired.highestPeAcked)")
            return false
        }
        var ids = undecryptable[peer] ?? []
        let id = ExactKey(frameId)
        if !ids.contains(id) {
            ids.append(id)
        }
        ids.removeFirst(max(0, ids.count - RatchetResetPolicy.trackedFrames))
        undecryptable[peer] = ids
        guard ids.count >= RatchetResetPolicy.distinctFrames else {
            return false
        }
        return now &- max(held?.lastResetSentAt ?? 0, lastResetSentAt[peer] ?? 0) >= RatchetResetPolicy.resetMilliseconds
    }

    /// Whether a frame from `peer` that failed as `EPOCH_GONE` was sealed against our local epoch `pe` that this phone
    /// retired behind the peer's own progress, read in a unit of its own (`retiredBase`, knit-next `RatchetSessions.kt:594-611`
    /// at `4f3cd995`, knit-next ADR 2026-10.9wvr): the verdict, or `nil` when the frame may still be evidence, or when a
    /// store failed. No session is never retired: there is nothing to protect, and a reset is the only answer to a peer we
    /// cannot read. ``noteUndecryptable(from:frameId:sentAt:now:epochGoneBase:)`` applies the same rule inside its own
    /// read; this answers it for diagnostics and the tests.
    public func retiredBase(from peer: NodeId, pe: Int) -> RetiredBase? {
        let read = transactor.atomically { () -> (RatchetSessionRecord?, Int?)? in
            (store.session(peer), store.lowestLocalEpoch(peer))
        }
        guard case .committed(let (held, lowest)) = read else {
            return nil
        }
        return Self.retired(pe, held: held, lowest: lowest)
    }

    /// The retired-base verdict on `pe` for the session `held` and our lowest epoch `lowest` (``RatchetResetPolicy/isRetiredBase(pe:highestPeAcked:lowestRetained:)``).
    private static func retired(_ pe: Int, held: RatchetSessionRecord?, lowest: Int?) -> RetiredBase? {
        guard let held, let lowest, RatchetResetPolicy.isRetiredBase(pe: pe, highestPeAcked: held.highestPeAcked, lowestRetained: lowest)
        else {
            return nil
        }
        return RetiredBase(pe: pe, lowestRetained: lowest, highestPeAcked: held.highestPeAcked)
    }

    /// How often the engine runs ``sweep(now:)`` after the one at start: hourly, since every retention window is 48 h or
    /// more (`HealFloors.RETENTION_SWEEP_MS`, `MeshManager.kt:3510`, which `heal` runs at most this often, `:970`).
    public static let sweepMilliseconds: Int64 = 3_600_000

    /// The retention sweep at `now`, in a unit of its own (`sweep`, `RatchetSessions.kt:543-544`), and whether it stood.
    /// On the database a deleted row is zeroed in the next write of its page, which reaches the file only at a
    /// checkpoint, while the write-ahead log keeps the frames that wrote the key until it is reset and overwritten, or
    /// truncated. The sweep's truncating checkpoint after its unit commits does both, unless a reader holds a snapshot
    /// of the log then: between sweeps either file can hold a key spent, or a chain key a seal or an open replaced, and
    /// rarely an older copy a page's rebalance left behind outlives the sweep (``RatchetStore/sweep(now:)``). The engine
    /// runs it at start and then every ``sweepMilliseconds``, never inside a DM's unit, so no send waits behind the
    /// checkpoint (phase P5a).
    @discardableResult
    public func sweep(now: Int64) -> Bool {
        let unit = transactor.atomically { () -> Void? in
            store.sweep(now: now)
            return ()
        }
        switch unit {
        case .committed, .joined:
            return true
        case .abandoned, .failed:
            return false
        }
    }

    /// Drops every row held for `peer` and says whether there was a session (`forget`, `RatchetSessions.kt:546-565`). Not a
    /// reset: nothing is sealed, and the next frame either way starts from nothing.
    public func forget(_ peer: NodeId) -> Answer<Bool> {
        // swiftlint:disable:next discouraged_optional_boolean - a unit's body answers nil to abandon; this one never does
        let unit = transactor.atomically { () -> Bool? in
            let had = store.session(peer) != nil
            if had {
                store.deletePeer(peer)
            }
            return had
        }
        return answer(unit, settlement: .forgotten(peer), otherwise: false)
    }

    /// What a unit came to, as this answers it: the floors move at once when it committed as the outermost, and go up to
    /// the caller when it joined one; `otherwise` is what a unit that wrote nothing says.
    func answer<Result>(_ unit: Transacted<Result>, settlement: Settlement, otherwise: Result) -> Answer<Result> {
        switch unit {
        case .committed(let result):
            settle(settlement)
            return .settled(result)
        case .joined(let result):
            return .joined(result, settlement)
        case .abandoned:
            return .settled(otherwise)
        case .failed:
            return .failed
        }
    }
}
