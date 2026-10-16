import KnitCrypto
import KnitStore
import KnitWire

@testable import KnitMesh

/// The seams faked to seal over the engine they serve, as phase P5d will fill them: a v1 seal of a `CTL_RECEIPT` stands in
/// for the ratchet's, so each tick is a DM-form chat to its author, under a fresh id and `sentAt` now
/// (`sealDeliveryTickEnvelope`, `MeshManager.kt:1868-1905`), that custody carries and a test opens. A live-link tick is
/// signed `relay = false`; an originated one is signed once and goes out through the engine's `originate(_:)`, flooded and
/// carried. Only an author whose key is pinned and who is in ``capable`` can read one. It opens no store unit, which P5d's
/// seals must (``TickSealing``): the stand-in spends no chain key.
final class EngineSeals: TickSealing {
    private weak var engine: MeshEngine?
    var capable: Set<NodeId>
    var originates = true
    /// The ids of each live-link tick sealed, in order.
    private(set) var sealed: [[String]] = []
    /// The ids of each tick originated, in order.
    private(set) var originated: [[String]] = []

    /// Seams for `fixture`'s engine, which it takes in place of the ones it ships with.
    init(_ fixture: EngineFixture, capable: Set<NodeId>) {
        engine = fixture.engine
        self.capable = capable
        fixture.engine.tickSeals = self
    }

    func canSeal(_ author: NodeId) -> Bool {
        capable.contains(author)
    }

    func sealTick(to author: NodeId, acks ids: [String]) -> WireEnvelope? {
        guard let engine, let envelope = tick(to: author, acks: ids, from: engine), let wire = engine.sign(envelope, relay: false)
        else {
            return nil
        }
        sealed.append(ids)
        return wire
    }

    func originateTick(to author: NodeId, acks ids: [String]) -> Bool {
        // Signed first, so `true` answers only a frame that went, as the contract asks.
        guard originates, let engine, let envelope = tick(to: author, acks: ids, from: engine),
            let wire = engine.sign(envelope, relay: true)
        else {
            return false
        }
        originated.append(ids)
        engine.originate(SignedFrame(wire: wire, envelope: envelope))
        return true
    }

    /// The tick's frame, or `nil` for an author who cannot read one: one id rides `ack`, a batch `acks`.
    private func tick(to author: NodeId, acks ids: [String], from engine: MeshEngine) -> RelayEnvelope? {
        guard capable.contains(author), let record = engine.stores.peers.peer(author),
            let bundle = PublicKeyBundle(encoded: record.publicKey)
        else {
            return nil
        }
        let id = engine.newFrameId()
        let sentAt = engine.clock.wallMilliseconds()
        let content =
            ids.count == 1
            ? MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: ids.first)
            : MessageContent(body: "", ctl: MessageContent.Control.receipt, acks: ids)
        let header = MessageCrypto.header(id: id, senderId: engine.nodeId.string, sentAt: sentAt, thread: author.string)
        guard let enc = try? MessageCrypto.seal(content.encoded, header: header, to: [author: bundle]) else {
            return nil
        }
        return engine.chatEnvelope(id: id, sentAt: sentAt, recipient: author, group: nil, content: ChatContent(enc: enc))
    }

    /// The ids the tick in `written` acknowledges, as `reader`, its author, opens it, or `nil` for one it cannot open.
    static func acks(of written: Written, as reader: TestPeer) -> [String]? {
        let envelope = written.envelope
        guard let enc = try? ChatContent(decoding: envelope.payload).enc else {
            return nil
        }
        let header = MessageCrypto.header(
            id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: reader.nodeId.string)
        guard let content = MessageCrypto.open(enc, header: header, as: reader.keys), content.ctl == MessageContent.Control.receipt else {
            return nil
        }
        return [content.ack].compactMap(\.self) + (content.acks ?? [])
    }
}
