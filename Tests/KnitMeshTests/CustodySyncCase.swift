import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire

/// What the custody suites share: their nodes, a frame maker, and a reply round with a carrier's pin store.
protocol CustodySyncCase {}

extension CustodySyncCase {
    var now: Int64 { 1_756_200_000_000 }
    var alice: NodeId { fixtureNodeId(1) }
    var bob: NodeId { fixtureNodeId(2) }
    var zed: NodeId { fixtureNodeId(26) }

    func frame(
        _ id: String,
        type: FrameType = .chat,
        from sender: NodeId? = nil,
        to recipient: NodeId? = nil,
        members: [NodeId]? = nil,
        sentAt: Int64? = nil,
        payloadBytes: Int = 0
    ) -> CarriedFrame {
        let author = sender ?? alice
        // The id derives from the roster, as custody's group gate checks (knit-next ADR 2026-10.7mqm).
        let group = members.map { GroupInfo(id: GroupId.derive($0.map(\.string)), members: $0.map(\.string), createdBy: author.string) }
        let envelope = RelayEnvelope(
            type: type,
            id: id,
            senderId: author.string,
            sentAt: sentAt ?? now,
            recipientId: recipient?.string,
            group: group,
            payload: Array(repeating: 0x2A, count: payloadBytes)
        )
        return CarriedFrame(envelope: envelope, sig: Self.signature(id), signed: envelope.encoded)
    }

    /// A signature whose first eight bytes, the link's frame key, are the id's last eight: one key per frame.
    static func signature(_ id: String) -> [UInt8] {
        let tail = Array(id.utf8.suffix(8))
        return tail + Array(repeating: 1, count: 64 - tail.count)
    }

    /// The key a carrier's pin store serves for `sender`, `bytes` long once signed, with a frame key of its own.
    static func key(of sender: NodeId, bytes: Int = 200) -> WireEnvelope {
        WireEnvelope(relay: false, sig: signature("k" + sender.string.suffix(7)), signed: Array(repeating: 0x55, count: bytes))
    }

    /// The link's frame key for `wire`.
    static func frameKey(_ wire: WireEnvelope) -> String {
        FrameKey.ofSigned(wire) ?? ""
    }

    /// A round with every sender's key in the pin store, as a carrier keeps them, and `crossed` the keys the link carried.
    func round(
        _ sync: CustodySync, from theirIds: [String] = [], for peer: NodeId, in store: MemoryCustodyStore,
        crossed: Set<String> = [], keyBytes: Int = 200
    ) -> CustodySync.DigestReply {
        sync.missing(
            from: theirIds, for: peer, in: store, now: now, crossed: { crossed.contains($0) }, key: { Self.key(of: $0, bytes: keyBytes) })
    }

    /// The ids a reply serves, in order.
    func ids(_ reply: CustodySync.DigestReply) -> [String] {
        reply.frames.compactMap { try? RelayEnvelope(decoding: $0.signed).id }
    }
}
