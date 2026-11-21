public import KnitStore
public import KnitWire

/// Store-and-forward over a link (`ForwardSync.kt`): which frames this node takes into custody, what it serves a
/// neighbour whose digest lists what it holds, and what a receipt purges.
///
/// The link-up and 60-second digest exchange is the whole protocol. Each side sends the ids of every live frame
/// it carries; on receiving the other's, it serves the live frames the list omits, in paced rounds
/// (``round(_:memo:in:now:at:addressedOnly:crossed:key:)``, the `custody-carry-policy` contract, §1 and §2). Android serves
/// custody only in answer to a digest, so a node that never sends one never gets back-filled (`.agents/context/custody.md`).
///
/// It keeps the ``CarryLedger`` too, since every custody write passes through here: each write reads it for the global
/// cap's key 2, and feeds it what the write evicted and kept.
public struct CustodySync: Sendable {
    /// How long a purged DM's id stays tombstoned: the custody TTL, so the tombstone outlives every copy still
    /// in flight (`ACK_TOMBSTONE_TTL_MS`).
    public static let tombstoneMilliseconds: Int64 = 86_400_000

    /// Ids purged by a receipt, on the wall clock, so a copy an unvaccinated peer re-serves is not taken again.
    private var tombstones: SeenSet

    /// Every receipt, keyed by the acknowledged id and its acker, for the tombstone's window (`earlyAcks`): the DM
    /// that lands after its own receipt is refused on arrival rather than carried to its expiry (knit-next ADR
    /// 2026-09.adpz).
    private var earlyReceipts: SeenSet

    /// Where a refused oversize frame, profile or group frame is noted, at `.debug`: the engine's log, or none.
    private let log: (any KnitLog)?

    /// Who holds what, the rows' rosters and the peers' memos (the `custody-carry-policy` contract, §3 and §6).
    public internal(set) var ledger: CarryLedger

    /// Custody bookkeeping for the node `own` with knit-next's tombstone window unless told otherwise, noting oversize and
    /// group frames custody refuses to `log`.
    public init(own: NodeId? = nil, tombstoneMilliseconds: Int64 = Self.tombstoneMilliseconds, log: (any KnitLog)? = nil) {
        tombstones = SeenSet(windowMilliseconds: tombstoneMilliseconds)
        earlyReceipts = SeenSet(windowMilliseconds: tombstoneMilliseconds)
        self.log = log
        ledger = CarryLedger(own: own)
    }

    /// The purged ids tombstoned now.
    public var tombstoneCount: Int { tombstones.count }

    /// The receipts remembered for a DM that may land after them, stale ones included until the set's capacity
    /// evicts them.
    public var earlyReceiptCount: Int { earlyReceipts.count }

    /// Group frames custody refused because their roster is not their own (``CustodyRefusal/foreignRoster``, knit-next
    /// ADR 2026-10.7mqm), Android's `groupCustodyRefused`. Not a drop: each was still delivered and relayed.
    public private(set) var groupRefusedCount = 0

    /// Frames custody refused because their `signed` is longer than its byte cap (``CustodyRefusal/oversize``,
    /// knit-next ADR 2026-10.mqzv), Android's `custodyOversizeRefused` (`MeshMetrics.kt` at `ce56fec6e`). Not a drop:
    /// each was still delivered and relayed. Our own count too, since the cap binds them.
    public private(set) var oversizeRefusedCount = 0

    /// Profiles custody refused because their `signed` is longer than its profile cap (``CustodyRefusal/profileOversize``,
    /// ``CustodyLimits/maxProfileSignedBytes``), custody's part of `profileOversizeRefused`. A profile over the byte cap
    /// too is counted in ``oversizeRefusedCount`` alone. Custody's refusal stops nothing but custody. Our own count too,
    /// since the cap binds them.
    public private(set) var profileOversizeRefusedCount = 0

    /// Takes a relayed frame into custody (`ForwardSync.onSeen`) if `authenticate` says so, and answers what the store did,
    /// or `nil` when this side's own gates kept it out (not custodial, held, tombstoned, an early receipt, or `authenticate`
    /// refused it). The spool's door reads ``CustodyStoreResult/refusal`` for a write that failed (ADR 2026-11.adrq, P4a);
    /// the radio's door reads ``CustodyStoreResult/changed``, which re-reads the advert's digest cue, and
    /// ``CustodyStoreResult/held``, which marks its neighbour's offer as one that drew.
    ///
    /// Only custodial types are carried, never an id already held or tombstoned, nor a DM whose recipient's receipt
    /// came first. The store applies the byte cap, the profile cap, the TTL and the quotas, and refuses a frame whose
    /// `signed` is over the cap, a profile whose `signed` is over its own, one that is dead on arrival or dated too far
    /// ahead, or a group frame whose roster is not its own. A refusal stops nothing but custody: the caller delivers and
    /// relays without reading the answer. Times are on the wall clock.
    ///
    /// `source` is the proven peer the frame arrived from, or `nil`: the write's snapshot counts it among the frame's own
    /// holders, and the ledger records it only if the frame is held afterwards (the contract, §3, "source").
    ///
    /// "Changed" is not "held": a frame its own write evicted changed custody and is not held (``CustodyStoreResult``).
    /// Nothing here pulls a carried frame's photo (ADR 2026-10.ym9y).
    public mutating func carrying(
        _ frame: CarriedFrame, in store: some CustodyStore, now: Int64, from source: NodeId? = nil, authenticate: () -> Bool
    ) -> CustodyStoreResult? {
        guard admits(frame, in: store, now: now), authenticate() else {
            return nil
        }
        return write(frame, origin: .relayed, in: store, now: now, from: source)
    }

    /// Takes a frame of ours into custody (ORIGIN_SELF): trivially authentic, and under the same quotas, the same byte cap
    /// and the same group gate as everyone's, so every node keeps the same newest frames below the cap. Answers what the
    /// store did, or `nil` when the frame never reached it, as ``carrying(_:in:now:from:authenticate:)`` does. A refusal is
    /// the rules' answer before any write, never a thrown error, so the ratchet's store units that read it only to re-read
    /// the digest cue go on; the send itself still goes.
    public mutating func carryingOwn(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> CustodyStoreResult? {
        guard admits(frame, in: store, now: now) else {
            return nil
        }
        return write(frame, origin: .own, in: store, now: now, from: nil)
    }

    /// ``carrying(_:in:now:from:authenticate:)`` from no peer, answering only whether custody changed.
    public mutating func carry(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64, authenticate: () -> Bool) -> Bool {
        carrying(frame, in: store, now: now, authenticate: authenticate)?.changed ?? false
    }

    /// ``carryingOwn(_:in:now:)``, answering only whether custody changed.
    public mutating func carryOwn(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        carryingOwn(frame, in: store, now: now)?.changed ?? false
    }

    /// The one custody write: the store reads the ledger's carry, which counts nothing stale for the frame itself, then a
    /// write that inserted it drops its stale entries, so a returning frame never inherits holders or a roster, and the
    /// ledger learns what the write evicted and kept. A write that inserted nothing leaves the id's entries alone: the
    /// store's "held" can be a read that failed (ADR 2026-09.nyya), and its row's holders must not go with it.
    private mutating func write(
        _ frame: CarriedFrame, origin: CustodyOrigin, in store: some CustodyStore, now: Int64, from source: NodeId?
    ) -> CustodyStoreResult {
        let id = frame.envelope.id
        let result = store.store(frame, origin: origin, now: now, carry: ledger.carry(counting: source, for: id))
        if result.changed {
            ledger.clear(id)
        }
        ledger.noteWrite(result, of: frame.envelope, from: source, spreadMax: store.limits.spreadMax)
        noted(result, for: frame)
        return result
    }

    /// Counts and logs an oversize, a profile-oversize or a roster refusal (`ForwardRepository.store`'s, in Android's words),
    /// and nothing else. No other refusal is counted here: the dead and the future-dated are the clock's,
    /// and a failed write is the database's, which reports it. An oversize frame is counted as that alone, whatever its type
    /// or roster, as Android's byte cap comes first. The line names the id, the type and the length, never the payload.
    private mutating func noted(_ result: CustodyStoreResult, for frame: CarriedFrame) {
        let envelope = frame.envelope
        switch result.refusal {
        case .oversize:
            oversizeRefusedCount += 1
            log?.log(
                .debug,
                "custody refused \(envelope.id.prefix(Self.idCharacters)) (\(envelope.type.rawValue)): "
                    + "\(frame.signed.count) signed bytes over the cap"
            )
        case .profileOversize:
            profileOversizeRefusedCount += 1
            log?.log(
                .debug,
                "custody refused \(envelope.id.prefix(Self.idCharacters)) (\(envelope.type.rawValue)): "
                    + "\(frame.signed.count) signed bytes over the profile cap"
            )
        case .foreignRoster:
            groupRefusedCount += 1
            // Only a group frame is refused for its roster (`CustodyRules.admission`), so both stores' refusals name one.
            if let group = envelope.group {
                log?.log(
                    .debug,
                    "custody refused \(envelope.id.prefix(Self.idCharacters)) from \(envelope.senderId.prefix(Self.idCharacters)): "
                        + "roster of \(group.id) is not its own"
                )
            }
        case .deadOnArrival, .aheadOfWindow, .writeFailed, nil:
            break
        }
    }

    /// How much of a frame or node id the log line names (`ID_CHARS`): enough to find it in a dump.
    static let idCharacters = 8

    /// The most bytes one round serves on Bluetooth, keys ahead included, each counted as its encoded ``WireEnvelope``, as
    /// `LinkManager.send` writes it (the `custody-carry-policy` contract, §2). The first pick always goes, so a round can
    /// pass it by that one frame. It is also the line a link drains under before it takes the next round. Shared law:
    /// Android's Bluetooth round is the same.
    public static let roundBytes = 16_384 // 16 KiB

    /// Applies a verified receipt for `ackId` from `sender` (`ForwardSync.onAck`): the carried DM is purged, and its
    /// id tombstoned, only when `sender` is that DM's recipient, so a forged receipt cannot evict an undelivered
    /// message. A room or group frame names no recipient, so nothing purges it but its TTL. Answers whether
    /// anything was purged.
    ///
    /// Every receipt is remembered with its sender too, for a DM not held yet. Only the DM names its recipient, and
    /// the router marks the receipt seen, so without the memo a DM that lands after its receipt is carried to its
    /// expiry here while every neighbour that heard the two the other way round refuses it. Back-fill serves newest
    /// first, and a recipient sends its receipt at once but relays the DM after the jitter, so that order is common
    /// (knit-next ADR 2026-09.adpz, #100). A memo that never matches, for a room or group frame or from anyone but
    /// the recipient, costs one slot in a bounded set.
    @discardableResult
    public mutating func acknowledge(_ ackId: String, from sender: String, in store: some CustodyStore, now: Int64) -> Bool {
        _ = earlyReceipts.insert(Self.earlyReceiptKey(ackId, sender), now: now)
        guard let recipient = store.recipient(of: ackId), ExactKey(recipient) == ExactKey(sender) else {
            return false
        }
        store.remove(ackId)
        ledger.forget(ackId)
        _ = tombstones.insert(ackId, now: now)
        return true
    }

    /// Whether `frame` may enter custody. A DM whose recipient's receipt came first is refused and tombstoned, as
    /// the purge it missed would have left it. The memo is keyed on the acker, so a receipt from anyone but the DM's
    /// own recipient keeps nothing out, the same guard ``acknowledge(_:from:in:now:)`` applies.
    ///
    /// knit-next asks a second time after the custody write, for a receipt handled on another dispatcher while the
    /// row was being written. The engine here is synchronous behind one actor (ADR 2026-09.gq84), so no receipt can
    /// land between this check and the write.
    private mutating func admits(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        let id = frame.envelope.id
        guard frame.envelope.type.isCustodial, !tombstones.contains(id, now: now), !store.contains(id) else {
            return false
        }
        if let recipient = frame.envelope.recipientId, earlyReceipts.contains(Self.earlyReceiptKey(id, recipient), now: now) {
            _ = tombstones.insert(id, now: now)
            return false
        }
        return true
    }

    /// The memo's key, `ackId|acker`, spelled as knit-next spells it (`ForwardSync.earlyAckKey`) so both platforms
    /// match the same pairs. The set compares it by its bytes (ADR 2026-09.jc2x).
    private static func earlyReceiptKey(_ ackId: String, _ acker: String) -> String {
        "\(ackId)|\(acker)"
    }

    /// Whether `ackId` was purged by its recipient within the window.
    public func isTombstoned(_ ackId: String, now: Int64) -> Bool {
        tombstones.contains(ackId, now: now)
    }
}
