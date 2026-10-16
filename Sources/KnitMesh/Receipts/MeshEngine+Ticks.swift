import KnitWire

/// The ticks we owe the authors of room posts and group messages, sent as ``AckSync`` decides them (`AckSync.kt` and its
/// wiring in `MeshManager.kt:373-389`, at knit-next `cbf2a487`): at a delivery, at a link-up and the 60 s re-offer, at the
/// heal, and at the deadline a batch's debounce sets. The ledger asks ``MeshEngine/tickSeals`` for a sealed tick, which the
/// ratchet seals with its switch on (phase P5d); any other tick is the cleartext one, signed here under a fresh id.
extension MeshEngine {
    /// Owes the author of room post or group message `id` a tick (`AckSync.owe`), and sends what is due now: the tick
    /// itself when the author is linked, or what a batch that went into custody leaves to send.
    func tickPost(_ id: String, author: NodeId, escalatable: Bool) {
        let now = clock.monotonicMilliseconds()
        sendTicks(ackSync.owe(id, author: author, escalatable: escalatable, me: nodeId, linked: linkedIds, now: now, seals: tickSeals))
    }

    /// Sends every tick owed to `peer`, now that it is linked or at the 60 s re-offer (`AckSync.onNeighborAdded`): its
    /// batch and its ride hold as one tick each, then each entry.
    func sendOwedTicks(to peer: NodeId) {
        sendTicks(ackSync.linked(to: peer, now: clock.monotonicMilliseconds(), seals: tickSeals))
    }

    /// The heal's pass over the ticks we owe (`AckSync.retryPending`, `MeshManager.kt:968`): the batches whose debounce
    /// ended, should their deadline have passed unfired, and whatever is owed to an author linked now.
    func retryOwedTicks() {
        sendTicks(ackSync.retryPending(linked: linkedIds, now: clock.monotonicMilliseconds(), seals: tickSeals))
    }

    /// The batches whose debounce has ended go into custody (`AckSync`'s wake, `AckSync.kt:429-433`): the engine's deadline,
    /// ``AckSync/nextBatchDue``, set only while a batch waits, which takes the ratchet's switch on.
    func flushDueTickBatches(now: Int64) {
        guard let due = ackSync.nextBatchDue, now >= due else {
            return
        }
        sendTicks(ackSync.flushDueBatches(linked: linkedIds, now: now, seals: tickSeals))
    }

    /// Sends what ``ackSync`` answered, each over its author's link: a sealed tick as it was given, a cleartext one signed
    /// under a fresh id.
    func sendTicks(_ ticks: [AckSync.Tick]) {
        for tick in ticks {
            switch tick.form {
            case .sealed(let wire):
                transport.send(wire, to: tick.author)
            case .cleartext(let ackId):
                sendTick(for: ackId, to: tick.author)
            }
        }
    }

    /// The neighbours linked now, which the ledger reads as the authors a tick can reach.
    var linkedIds: Set<NodeId> { Set(neighborIds) }

    /// A cleartext tick (`AckSync.receipt`, `AckSync.kt:693-706`): signed, point to point, no `sentAt`, and a fresh id every
    /// time, so the author's seen set never swallows a retry.
    func sendTick(for ackId: String, to author: NodeId) {
        let tick = RelayEnvelope(type: .receipt, id: newFrameId(), senderId: nodeId.string, payload: ReceiptContent(ackId: ackId).encoded)
        if let wire = sign(tick, relay: false) {
            transport.send(wire, to: author)
        }
    }
}
