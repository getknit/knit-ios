import KnitWire

@testable import KnitMesh

/// The ledger's seams for a test of ``AckSync`` alone, as knit-next's `AckSyncRig.kt` hands them in (`ackSyncOn`, at
/// `cbf2a487`): the authors who could read a sealed tick, whether a seal is made, and whether an origination goes, with
/// every seal and origination that went recorded. A seal is a stand-in whose bytes name its author and the ids it
/// acknowledges (`sealedWire`, `AckSyncRig.kt:69-85`).
final class LedgerSeals: TickSealing {
    var capable: Set<NodeId>
    var seals: Bool
    var originates: Bool
    /// Refuses the seal of the ids it names though ``seals`` would make one: a stale "can seal" for one chunk of a hold.
    var refuses: ([String]) -> Bool = { _ in false }
    /// The ids of each seal made, in order.
    private(set) var sealed: [[String]] = []
    /// The ids of each origination that went, in order.
    private(set) var originated: [[String]] = []

    init(capable: Set<NodeId> = [], seals: Bool = false, originates: Bool = false) {
        self.capable = capable
        self.seals = seals
        self.originates = originates
    }

    func canSeal(_ author: NodeId) -> Bool {
        capable.contains(author)
    }

    func sealTick(to author: NodeId, acks ids: [String]) -> WireEnvelope? {
        guard seals, !refuses(ids) else {
            return nil
        }
        sealed.append(ids)
        return Self.wire(to: author, acks: ids)
    }

    func originateTick(to _: NodeId, acks ids: [String]) -> Bool {
        guard originates else {
            return false
        }
        originated.append(ids)
        return true
    }

    /// The stand-in seal of `ids` to `author`: a chat-shaped frame, `relay = false`, under an id its first ack names.
    static func wire(to author: NodeId, acks ids: [String]) -> WireEnvelope {
        let envelope = RelayEnvelope(
            type: .chat,
            id: "sealed-\(ids.first ?? "")",
            senderId: "recip",
            sentAt: 1,
            recipientId: author.string,
            payload: ReceiptContent(ackId: ids.joined(separator: "+")).encoded
        )
        return WireEnvelope(relay: false, sig: [0x5A], signed: envelope.encoded)
    }
}

extension Array where Element == AckSync.Tick {
    /// The ids the cleartext ticks acknowledge, in order.
    var cleartextIds: [String] {
        compactMap { tick in
            guard case .cleartext(let ackId) = tick.form else {
                return nil
            }
            return ackId
        }
    }

    /// The sealed ticks, in order.
    var sealedWires: [WireEnvelope] {
        compactMap { tick in
            guard case .sealed(let wire) = tick.form else {
                return nil
            }
            return wire
        }
    }
}
