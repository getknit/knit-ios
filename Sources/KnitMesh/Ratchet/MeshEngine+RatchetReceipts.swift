import KnitCrypto
import KnitStore
import KnitWire

/// Our receipts and ticks sealed with the ratchet, with the switch on (ADR 2026-10.5sk9, phase P5d): a DM's sealed receipt
/// (`acknowledge` and `sealDmReceipt`, `InboundPipeline.kt:2831-2862` and `:2895-2958`, at knit-next `cbf2a487`), and the
/// seals behind the three seams ``AckSync`` asks (``TickSealing``; `canSealTickTo`, `sealDeliveryTickEnvelope`,
/// `sealDeliveryTick` and `originateDeliveryTick`, `MeshManager.kt:1859-1966` and `:2066-2069`).
///
/// **What goes.** Each is a `CTL_RECEIPT` DM to the author under a fresh frame id and `sentAt` now, compact for an author
/// whose pinned profile reads v3, decided by one read of that row (``RatchetOutbound/receiptPlan(to:ratchet:)``). A tick
/// carries one id in `ack` and a batch in `acks`; a DM's receipt carries the DM's id in `ack` and the room ticks riding it
/// in `acks`. The live-link tick is signed with `relay = false` and never carried. Kotlin sends a v3 one unsigned (ADR
/// 059), and this port sends none unsigned, since a signed tick verifies on Android the normal way. The escalated batch
/// and the DM's receipt are originated: signed with `relay = true`, carried in our custody and flooded, so each reaches
/// its author as the message it acknowledges does.
///
/// **The unit.** Each seal stands in a store unit of its own, the outermost: the facade's `sealDm` joins it, and the frame
/// is signed once inside it and, when originated, taken into our custody inside it, as the send unit does
/// (``sendRatchet(_:to:_:purpose:riders:)``). The frame id and the clock are drawn inside it once the author's row has
/// been read, as Kotlin draws them after its read and before its seal. Nothing leaves before that unit commits: the
/// seal's settlement, the router's mark and the flood all wait for it. A seal asked for inside a unit its caller opened
/// joins that unit instead, and what it leaves behind stands or falls with it (``ControlSealing/joined``). Every ctl of ours
/// takes this seal (``sealControl(_:to:in:plan:)``), phase P5e's reactions and profiles included.
///
/// **The fallbacks.** The cleartext form, never v1, goes where the store works and no seal can be made: toward an author
/// who cannot read a sealed one, and when the facade cannot seal (no session and no usable prekey, a new epoch due with no
/// base, a key X25519 refuses). A v1 ctl frame is an empty bubble on a build without the ratchet (`InboundPipeline.kt:2898-2900`).
/// A store that fails is another matter for a DM's receipt: its plan is read inside the unit, so a failed read fails it as
/// a failed write does, and then nothing goes, as Kotlin's throw out of `sealDmReceipt` sends nothing (`PeerRepository.kt:138`,
/// `RatchetSessions.kt:50`, `:247`, `:259`, swallowed at `InboundPipeline.kt:304`). Only a DM's cleartext receipt purges
/// the DM from our custody; the sealed one purges nothing, ours included (ADR 2026-09.p6nb, amended). A tick whose seal
/// fails on a store keeps its cleartext entry, which purges nothing.
///
/// **No blocked gate** (`MeshManager.kt:1863-1865`, knit-next ADR 010): a blocked author's tick is sealed, batched and
/// escalated like anyone's, since a cleartext tick toward a blocked author alone would show the block on the air. A
/// blocked sender's DM is never delivered, so it earns no receipt of either form (``dropBlocked(_:sender:)``).
///
/// **Riders.** A DM's sealed receipt carries up to ``RatchetOutbound/maxReceiptRiders`` room ticks waiting for a ride toward
/// its author (``AckSync/takeRiding(_:limit:)``), taken before its unit, said to have ridden only once the unit commits,
/// and given back with their stamps otherwise, within this one call. The seams take none: the ledger takes the ones a
/// batch carries, since a seam that called back into the ledger would overlap the ledger's own access.
///
/// **The counts** are Android's (``RatchetReceiptCounts``): each committed seal, each seal the facade could not make toward
/// an author who could read one, each batch originated, and, in the ledger, each room tick that rode.
extension MeshEngine {
    /// How our receipts and ticks went so far, under Android's metric names (``RatchetReceiptCounts``, phase P5d), with the
    /// room ticks that rode, which the ledger counts as every carrier tells it (``AckSync/ridden``).
    public var receipts: RatchetReceiptCounts {
        var counts = receiptCounts
        counts.receiptsRidden = ackSync.ridden
        return counts
    }

    /// Whether `author` could read a sealed receipt or tick now (`canSealTickTo`, `MeshManager.kt:2066-2069`): the switch on,
    /// and one read of its pinned row finding `CAP_RATCHET` and a bundle that decodes. A cheap read, never a trial seal.
    func canSealTick(to author: NodeId) -> Bool {
        receiptPlan(to: author) != nil
    }

    /// One sealed tick acknowledging `ids` to `author` for its live link (`sealDeliveryTick`, `MeshManager.kt:1925-1931`):
    /// signed once with `relay = false`, and never carried. `nil` with the switch off, toward an author who cannot read
    /// one, and when the seal or its unit did not commit; the ledger then keeps the cleartext tick.
    func sealLiveTick(to author: NodeId, acks ids: [String]) -> WireEnvelope? {
        guard !ids.isEmpty, let plan = receiptPlan(to: author) else {
            return nil
        }
        let sealing = sealControl(RatchetOutbound.tick(acking: ids), to: author, in: .receipt(relay: false)) { plan }
        switch sealing {
        case .sealed(let tick):
            ratchet.settle(tick.settlement)
            receiptCounts.receiptsSealed += 1
            return tick.frame.wire
        case .unsealable:
            receiptCounts.receiptsSealedFallback += 1
            return nil
        case .failed:
            log.log(.warning, "mesh tick to \(author) not sealed: a store failed, and it goes in the clear")
            return nil
        case .unreadable, .joined:
            return nil
        }
    }

    /// One sealed tick acknowledging `ids` to `author`, originated (`originateDeliveryTick`, `MeshManager.kt:1939-1966`):
    /// signed once with `relay = true`, carried in our custody inside its unit, then marked as ours and flooded, so it
    /// reaches an absent author as the message it acknowledges does. `ids` is a batch and the room ticks riding it, which
    /// the ledger took. Answers whether it went: `false` when its unit did not commit, and the ledger then keeps the ids as
    /// cleartext entries.
    func originateTick(to author: NodeId, acks ids: [String]) -> Bool {
        guard !ids.isEmpty, let plan = receiptPlan(to: author) else {
            return false
        }
        let sealing = sealControl(RatchetOutbound.tick(acking: ids), to: author, in: .receipt(relay: true)) { plan }
        switch sealing {
        case .sealed(let tick):
            originateSealed(tick)
            receiptCounts.receiptsSealed += 1
            receiptCounts.receiptsCustodied += 1
            return true
        case .unsealable:
            receiptCounts.receiptsSealedFallback += 1
            return false
        case .failed:
            log.log(.warning, "mesh tick batch to \(author) not sealed: a store failed, and it waits in the clear")
            return false
        case .unreadable, .joined:
            return false
        }
    }

    /// Our receipt for DM `ackId` from `author`, sealed and originated (`sealDmReceipt`, `InboundPipeline.kt:2895-2958`),
    /// with the room ticks waiting for a ride toward `author` beside it. It purges nothing, ours included: carriers cannot
    /// read it, so the DM leaves every custody on its TTL alike (ADR 2026-09.p6nb, amended). The author's row is read
    /// inside the seal's unit, so a read that fails fails the unit. Answers what it came to: only
    /// ``SealedReceiptAttempt/unsealed`` asks the caller for the cleartext receipt.
    func sendSealedReceipt(for ackId: String, to author: NodeId) -> SealedReceiptAttempt {
        guard configuration.ratchet else {
            return .unsealed
        }
        // Taken before the unit, and settled within this call either way (`InboundPipeline.kt:2924`, `:2938`, `:2955`).
        let riders = ackSync.takeRiding(author, limit: RatchetOutbound.maxReceiptRiders)
        let content = RatchetOutbound.dmReceipt(acking: ackId, riders: riders)
        let sealing = sealControl(content, to: author, in: .receipt(relay: true)) {
            RatchetOutbound.receiptPlan(to: stores.peers.peer(author), ratchet: true)
        }
        guard case .sealed(let receipt) = sealing else {
            ackSync.giveBackRiding(author, riders, now: clock.monotonicMilliseconds())
            return attempt(sealing, for: ackId)
        }
        originateSealed(receipt)
        receiptCounts.receiptsSealed += 1
        ackSync.rode(riders, now: clock.monotonicMilliseconds())
        return .sent
    }

    /// What a DM's receipt whose seal did not commit comes to, its riders already given back.
    private func attempt(_ sealing: ControlSealing, for ackId: String) -> SealedReceiptAttempt {
        switch sealing {
        case .unsealable:
            receiptCounts.receiptsSealedFallback += 1
            return .unsealed
        case .joined:
            log.log(.warning, "mesh receipt for \(ackId) held back: asked for inside a store unit")
            return .heldBack
        case .failed:
            log.log(.warning, "mesh receipt for \(ackId) not sent: a store failed")
            return .failed
        case .sealed, .unreadable:
            return .unsealed
        }
    }

    /// What a sealed receipt or tick toward `author` takes, from one read of its pinned row, or `nil` when it cannot read
    /// one: always `nil` with the switch off, so no seam seals and nothing reaches the ratchet's tables.
    private func receiptPlan(to author: NodeId) -> RatchetOutbound.ReceiptPlan? {
        guard configuration.ratchet else {
            return nil
        }
        return RatchetOutbound.receiptPlan(to: stores.peers.peer(author), ratchet: true)
    }
}

/// What our sealed receipt for a DM came to (``MeshEngine/sendSealedReceipt(for:to:)``).
internal enum SealedReceiptAttempt: Equatable {
    /// Sealed, committed and flooded: nothing more is owed.
    case sent
    /// Not sealed, with the store working: the switch is off, the author cannot read a sealed receipt, or the facade could
    /// not seal. Nothing of it went, and the cleartext receipt goes in its place, with its self-purge.
    case unsealed
    /// Asked for inside a caller's store unit, where no frame may go, so nothing goes now, sealed or cleartext, and the
    /// riders go back. Not "nothing sent" for good: the seal joined that unit (``ControlSealing/joined``), and if the unit
    /// commits, the receipt stands in our custody and goes at the next exchange, carrying the riders it also gave back,
    /// which the author then applies twice, idempotently.
    case heldBack
    /// A store failed, the author's row read or the unit: nothing goes, sealed or cleartext, and nothing is purged, as
    /// Kotlin's throw sends nothing. The DM's tick waits until a copy reaches us again. Our digest lists the DM while our
    /// custody holds it, so only a copy past the router's window brings one: a back-fill once our quotas evict it, or a
    /// re-flood of a copy some node took from one holder while linked to another, through whatever neighbour relays it
    /// (ADR 2026-10.5sk9's P5d amendment).
    case failed
}

/// How our receipts and ticks went, under the names of Android's metrics (`MeshMetrics.Receipts`, `MeshMetrics.kt:1489-1498`,
/// at `cbf2a487`), counted where Kotlin counts them (`onReceiptSealed`, `onReceiptSealedFallback`, `onReceiptCustodied`
/// and `onReceiptRidden`, `MeshManager.kt:1887-1890`, `:1955-1957`, `:1194` and `InboundPipeline.kt:2939-2955`). Four of
/// Android's eight: its `receiptsResent` counts the ledger's re-sends, which this port leaves uncounted, and its
/// coalesced, spooled and unsigned ticks have no plane or form here. The control surface's `ratchet` reports them.
public struct RatchetReceiptCounts: Sendable, Equatable {
    /// Receipts and ticks sealed with the ratchet: a DM's receipt, a live-link tick and an escalated batch alike
    /// (`receiptsSealed`).
    public internal(set) var receiptsSealed = 0
    /// Seals the facade could not make toward an author who could read one, so the cleartext form went in their place
    /// (`receiptsSealedFallback`). A store that failed counts nothing, as Kotlin's throw counts nothing.
    public internal(set) var receiptsSealedFallback = 0
    /// Escalated batches originated into custody, one frame however many ids it carries (`receiptsCustodied`).
    public internal(set) var receiptsCustodied = 0
    /// Room ticks that rode a frame sealed toward their author anyway: a batch, a DM's receipt, or our DM's inline acks
    /// (`receiptsRidden`).
    public internal(set) var receiptsRidden = 0

    /// Counts as stated, each zero unless given: nothing sealed yet.
    public init(receiptsSealed: Int = 0, receiptsSealedFallback: Int = 0, receiptsCustodied: Int = 0, receiptsRidden: Int = 0) {
        self.receiptsSealed = receiptsSealed
        self.receiptsSealedFallback = receiptsSealedFallback
        self.receiptsCustodied = receiptsCustodied
        self.receiptsRidden = receiptsRidden
    }
}

/// The seams ``AckSync`` asks, sealing with the ratchet (``TickSealing``, phase P5d): each answers "cannot seal" by itself
/// with the switch off, since the ledger asks ``sealTick(to:acks:)`` without ``canSeal(_:)`` for a linked author, for an
/// absent one `canSeal` refused, and for a hold that goes over a link (`AckSync.kt:187`, `:586`). None reads or writes the
/// ledger: the engine's methods behind them touch its stores, its ratchet, its router, its custody bookkeeping, its counts
/// and its transport, never ``MeshEngine/ackSync``.
///
/// It holds its engine `unowned`: the engine keeps it, and it never outlives the engine.
internal struct RatchetTickSeals: TickSealing {
    unowned let engine: MeshEngine

    func canSeal(_ author: NodeId) -> Bool {
        engine.canSealTick(to: author)
    }

    func sealTick(to author: NodeId, acks ids: [String]) -> WireEnvelope? {
        engine.sealLiveTick(to: author, acks: ids)
    }

    func originateTick(to author: NodeId, acks ids: [String]) -> Bool {
        engine.originateTick(to: author, acks: ids)
    }
}
