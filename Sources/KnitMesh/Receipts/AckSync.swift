public import KnitWire

/// The delivery ticks this node owes the authors of the room posts and group messages it received (`AckSync.kt`, at
/// knit-next `cbf2a487`), without the spool and the fast plane, which this port lacks (ADR 2026-09.zwdp): a value that
/// decides, and answers the ticks for ``MeshEngine`` to send.
///
/// A DM's receipt floods and is carried, so it finds its way home. A room post or a group message has no one recipient,
/// so its tick is lighter. ``owe(_:author:escalatable:me:linked:now:seals:)`` decides it three ways, by whether the author
/// is linked and whether it could read a sealed tick (``TickSealing``):
///
/// - **A linked author** gets one tick over its link, point to point (`relay = false`), never flooded or carried: sealed
///   when it can read one, cleartext otherwise.
/// - **An absent author who could read a sealed tick.** A group message's tick joins that author's batch, which goes as
///   one sealed tick covering every id once its oldest has waited ``batchDebounceMilliseconds``, or at once when it fills
///   or the batches together reach ``pendingCapacity``. That tick is originated: flooded, and carried in custody for a day
///   like the message it acknowledges, for one chain key however many ids it covers (knit-next ADR 033). Its ids are
///   remembered, so a custody re-serve's re-owe does nothing. A room post's tick never costs a custody row (knit-next ADR
///   2026-09.aa27): it waits in the author's ride hold for a frame we seal toward that author anyway, which takes it
///   (``takeRiding(_:limit:)``), or for a link. A sealed batch is one such frame.
/// - **An author who could not read one** keeps the cleartext entry it always had: signed, point to point, no `sentAt`,
///   under a fresh id each attempt so its seen set never swallows a retry, sent only over a live link, never carried.
///
/// A live link is the reliable path home, and ends an owed entry as one tick, and a batch or a ride hold in ticks of at
/// most ``maxBatchAcks`` ids (``linked(to:now:seals:)``). An owed entry keeps the sealed tick it was given (`Owed.sealed`) and re-sends those bytes
/// verbatim, since a seal spends a chain key.
///
/// **What the missing planes leave out.** Kotlin's send toward an author with no link (`fastSend`) rides the fast plane:
/// on Bluetooth it writes only to the author's own link (`BluetoothMeshTransport.kt:706-716`). So here such an attempt
/// sends nothing, and the doubling back-off that paces those sends (`backOff`, knit-next ADRs 053 and 2026-09.6gk8) has
/// nothing to pace: a tick waits for its author's link, as the cleartext form always has. The ride hold's deadline
/// (`RIDE_HOLD_MS`) routes to the spool or the fast plane, so a due ride keeps waiting for a link or a carrier, and
/// `onReachable` has nothing to hear. The batch's debounce is an engine deadline (``nextBatchDue``, ADR 2026-09.gq84) where
/// Kotlin arms a coroutine, and the heal's ``retryPending(linked:now:seals:)`` is its backstop, as in Kotlin.
///
/// In memory and bounded, as `KeyExchange` and `PendingInbound` are: a tick a restart loses comes back when its message is
/// re-served and owed again. Where Kotlin's hash maps leave an order to chance, the oldest stamp goes first, ties by
/// arrival or by node id. Times are on the monotonic clock, and nothing in custody reads them. Ids compare by their bytes
/// (ADR 2026-09.jc2x).
public struct AckSync: Sendable {
    /// How long a tick stays owed, in any hold (`OWED_TTL_MS`): a DM's and a group's carry TTL.
    public static let owedMilliseconds: Int64 = 86_400_000
    /// The most owed entries at once, oldest evicted first (`OWED_CAP`).
    public static let owedCapacity = 500
    /// How long an absent author's group ticks gather before their batch goes into custody (`TICK_BATCH_DEBOUNCE_MS`).
    public static let batchDebounceMilliseconds: Int64 = 45_000
    /// How long a room tick waits for a ride before its deadline looks for a route (`RIDE_HOLD_MS`). Here the only route is
    /// a live link.
    public static let rideHoldMilliseconds: Int64 = 60_000
    /// The most ids one batch's tick carries, riders included, and the size at which a batch goes at once
    /// (`MAX_BATCH_ACKS`), and the most a hold sends over a link in one tick. A receiver applies at most twice this from one
    /// tick.
    public static let maxBatchAcks = 64
    /// The most ids waiting in every author's batch together, and in every ride hold together (`PENDING_CAP`).
    public static let pendingCapacity = 500
    /// The most escalated and ridden ids remembered, oldest forgotten first (`ESCALATED_CAP`).
    public static let escalatedCapacity = 1000

    /// A tick to send now, over its author's live link (`attempt`, `AckSync.kt:617-631`).
    public struct Tick: Sendable, Equatable {
        /// What goes on the link.
        public enum Form: Sendable, Equatable {
            /// The sealed tick an owed entry or a held batch was given, sent verbatim.
            case sealed(WireEnvelope)
            /// The cleartext tick for one id (`receipt`, `AckSync.kt:693-706`), which the engine signs under a fresh id.
            case cleartext(ackId: String)
        }

        /// The author it goes to.
        public var author: NodeId
        /// What goes.
        public var form: Form

        /// A tick of `form` to `author`.
        public init(author: NodeId, form: Form) {
            self.author = author
            self.form = form
        }
    }

    /// One owed tick (`Owed`, `AckSync.kt:116-125`, without the back-off's fields): the id it acknowledges, its author,
    /// when it was owed, and the sealed tick every attempt re-sends verbatim, or `nil` for the cleartext form, made afresh.
    struct Owed: Sendable {
        var messageId: String
        var key: ExactKey
        var author: NodeId
        var recordedAt: Int64
        var sealed: WireEnvelope?

        /// What an attempt sends.
        var form: Tick.Form {
            sealed.map(Tick.Form.sealed) ?? .cleartext(ackId: messageId)
        }
    }

    /// An id waiting in a batch or a ride hold, and the stamp it waits on (`PendingBatch.ids`).
    struct Waiting: Sendable {
        var messageId: String
        var key: ExactKey
        var at: Int64
    }

    /// When an id was escalated or rode, and in what order, so the cap forgets the oldest first.
    struct Done: Sendable {
        var at: Int64
        var order: Int
    }

    let ttl: Int64
    let capacity: Int
    /// The owed entries, oldest stamp first, ties in the order they came (`owed`).
    var owed: [Owed] = []
    /// Each absent author's group ticks, in arrival order, waiting out the debounce (`pending`). A hold that empties goes,
    /// here and in ``riding``.
    var pending: [NodeId: [Waiting]] = [:]
    /// Each absent author's room ticks, in arrival order, waiting for a ride (`riding`).
    var riding: [NodeId: [Waiting]] = [:]
    /// The ids a batch escalated or a carrier took: done, and remembered so a re-owe does nothing (`escalated`).
    var escalated: [ExactKey: Done] = [:]
    /// The stamp each ride id had when a carrier took it, which a give-back keeps (`lent`).
    var lent: [ExactKey: Int64] = [:]
    /// The next ``Done/order``.
    var nextOrder = 0
    /// How many room ticks rode a frame sealed toward their author, every carrier's together: a batch, a DM's receipt and
    /// our DM's inline acks. Each carrier tells ``rode(_:now:)`` what rode, where Kotlin counts `onReceiptRidden` beside
    /// each `rode` (`MeshMetrics.kt:556-558`; `MeshManager.kt:1194`, `:1957`, `InboundPipeline.kt:2955`), so this is
    /// Android's `receiptsRidden`.
    public internal(set) var ridden = 0

    /// A ledger with knit-next's bounds unless told otherwise.
    public init(owedMilliseconds: Int64 = Self.owedMilliseconds, capacity: Int = Self.owedCapacity) {
        ttl = owedMilliseconds
        self.capacity = capacity
    }

    /// How many ticks are owed: the owed entries, and the ids waiting in batches and ride holds.
    public var count: Int { owed.count + Self.waitingCount(pending) + Self.waitingCount(riding) }

    /// Whether no tick is owed.
    public var isEmpty: Bool { owed.isEmpty && pending.isEmpty && riding.isEmpty }

    /// We delivered message `messageId` by `author`: a room post, or a group message when `escalatable`
    /// (`AckSync.owe`, `AckSync.kt:170-194`; `InboundPipeline.kt:2857` decides `escalatable`). Answers the ticks to send
    /// now, each over its author's live link, which `linked` names. Our own messages are never ticked, and an id escalated,
    /// ridden or still waiting in its author's batch or ride hold is not owed again. A fresh id toward an absent author
    /// whom `seals` says could read a sealed tick waits in the batch or the ride hold. Any other is an owed entry, sealed
    /// now if `seals` can, and sent at once over a live link, which ends it. A re-owe keeps the entry and its seal.
    public mutating func owe( // swiftlint:disable:this function_parameter_count - Kotlin's three, and what it injects
        _ messageId: String, author: NodeId, escalatable: Bool, me: NodeId, linked: Set<NodeId>, now: Int64,
        seals: some TickSealing
    ) -> [Tick] {
        guard author != me else {
            return []
        }
        sweep(now: now)
        let key = ExactKey(messageId)
        guard escalated[key] == nil, !holds(.batch, author, key), !holds(.ride, author, key) else {
            return []
        }
        let existing = owed.first { $0.key == key }
        // Only a fresh id waits in a hold, so a re-owe keeps what the first owe decided (`heldForAbsentAuthor`, `:272-281`).
        // Both holds live inside a sealed frame, so an author who could not read one keeps the cleartext entry.
        if existing == nil, !linked.contains(author), seals.canSeal(author) {
            let waiting = Waiting(messageId: messageId, key: key, at: now)
            if escalatable {
                return enqueue(waiting, author: author, linked: linked, now: now, seals: seals)
            }
            holdForRide(waiting, author: author)
            return []
        }
        if let existing {
            return send(existing, ifLinked: linked)
        }
        evictPastCapacity()
        let entry = Owed(
            messageId: messageId, key: key, author: author, recordedAt: now, sealed: seals.sealTick(to: author, acks: [messageId]))
        insert(entry)
        return send(entry, ifLinked: linked)
    }

    /// A link to `peer` is up, fresh or at the 60 s re-offer (`onNeighborAdded`, `AckSync.kt:201-214`): its batch and its
    /// ride hold go over the link in ticks of at most ``maxBatchAcks`` ids, ahead of custody, then every entry owed to it,
    /// oldest first. A live link is the reliable path home, so each is done once sent. Past a sweep first, as at every entry
    /// point that sends (`owe`, `linked`, `retryPending`, `flushDueBatches`) and as the old ledger's two did, where Kotlin's
    /// `onNeighborAdded` and its debounce wake do not: so a tick past its day never goes.
    public mutating func linked(to peer: NodeId, now: Int64, seals: some TickSealing) -> [Tick] {
        sweep(now: now)
        var ticks = flushOverLink(.batch, of: peer, seals: seals)
        ticks += flushOverLink(.ride, of: peer, seals: seals)
        let due = owed.filter { $0.author == peer }
        owed.removeAll { $0.author == peer }
        return ticks + due.map { Tick(author: peer, form: $0.form) }
    }

    /// The heal's pass (`retryPending`, `AckSync.kt:222-235`, from `MeshManager.kt:968`): the sweep, so a batch past its
    /// day is dropped rather than escalated, then the batches whose debounce has ended, the ride holds due over a live
    /// link, and every entry whose author `linked` names, oldest first, so the ones nearest their day go first.
    public mutating func retryPending(linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        sweep(now: now)
        var ticks = flushBatchesDue(linked: linked, now: now, seals: seals)
        ticks += flushRidesDue(linked: linked, now: now, seals: seals)
        let due = owed.filter { linked.contains($0.author) }
        owed.removeAll { linked.contains($0.author) }
        return ticks + due.map { Tick(author: $0.author, form: $0.form) }
    }

    /// Drops every tick owed longer than the window, in every hold, and forgets escalated ids and lent stamps as old
    /// (`sweep`, `AckSync.kt:725-738`).
    public mutating func sweep(now: Int64) {
        let cutoff = now - ttl
        owed.removeAll { $0.recordedAt < cutoff }
        if escalated.values.contains(where: { $0.at < cutoff }) {
            escalated = escalated.filter { $0.value.at >= cutoff }
        }
        if lent.values.contains(where: { $0 < cutoff }) {
            lent = lent.filter { $0.value >= cutoff }
        }
        pending = Self.swept(pending, before: cutoff)
        riding = Self.swept(riding, before: cutoff)
    }

    // MARK: Owed entries

    /// Sends `entry` over its author's live link and ends it (`sendOwedIfDue`, `AckSync.kt:639-653`). With no link it
    /// stays owed: the send Kotlin makes then rides the fast plane.
    mutating func send(_ entry: Owed, ifLinked linked: Set<NodeId>) -> [Tick] {
        guard linked.contains(entry.author) else {
            return []
        }
        owed.removeAll { $0.key == entry.key }
        return [Tick(author: entry.author, form: entry.form)]
    }

    /// A batch or a hold whose seal failed, back as one cleartext entry per id, each with the stamp it waited on and tried
    /// once now (`restoreAsCleartext`, `AckSync.kt:596-607`).
    mutating func restoreAsCleartext(_ ids: [Waiting], author: NodeId, linked: Set<NodeId>) -> [Tick] {
        var ticks: [Tick] = []
        for waiting in ids {
            evictPastCapacity()
            let entry = Owed(messageId: waiting.messageId, key: waiting.key, author: author, recordedAt: waiting.at, sealed: nil)
            insert(entry)
            ticks += send(entry, ifLinked: linked)
        }
        return ticks
    }

    /// Makes room for one more entry, evicting the oldest (`evictOldest`, `AckSync.kt:758-760`).
    mutating func evictPastCapacity() {
        if owed.count >= capacity, !owed.isEmpty {
            owed.removeFirst()
        }
    }

    /// Puts `entry` in its place among the owed entries, oldest stamp first and ties in the order they came, in place of
    /// any entry under its id (`owed[messageId] = entry`).
    mutating func insert(_ entry: Owed) {
        owed.removeAll { $0.key == entry.key }
        let index = owed.firstIndex { $0.recordedAt > entry.recordedAt } ?? owed.endIndex
        owed.insert(entry, at: index)
    }
}
