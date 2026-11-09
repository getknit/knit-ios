import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// The far end of a sealed link, played by hand against a ``LinkRig``: its own ephemeral key, the session it derives from
/// the rig's `KEY_SHARE`, and a reader of everything the rig's radio put on the air, opening each frame in order.
final class SealedFarEnd {
    let ephemeral = LinkSeal.Ephemeral()
    /// The role this end plays: the opposite of the rig's.
    let role: LinkProof.Role
    private(set) var session: LinkSeal.Session?
    /// Every outer record the rig wrote, in order.
    private(set) var outer: [LinkRecord.Tag] = []
    /// Every inner record the rig wrote, opened.
    private(set) var inner: [LinkRecord] = []
    private var read = 0
    private var reader = LinkRecordReader()
    private var innerReader = LinkRecordReader()

    init(role: LinkProof.Role) {
        self.role = role
    }

    /// This end's `KEY_SHARE` record.
    var keyShare: [UInt8] {
        LinkRecord(.keyShare, payload: ephemeral.keyShare).encoded ?? []
    }

    /// Both shares, once derived.
    var shares: LinkSeal.KeyShares? { session?.shares }

    /// Reads what the rig wrote on `id` since the last read: its `KEY_SHARE` derives the session, and its frames open.
    @discardableResult
    func take(from rig: LinkRig, on id: ChannelID) throws -> [LinkRecord] {
        let writes = rig.radio.writes(on: id)
        reader.append(writes.dropFirst(read).flatMap(\.self))
        read = writes.count
        let before = inner.count
        while let record = try reader.next() {
            outer.append(record.tag)
            switch record.tag {
            case .keyShare:
                session = try LinkSeal.derive(ephemeral, peerShare: record.payload, role: role)
            case .sealed:
                let opener = try #require(session?.opener)
                innerReader.append(try #require(opener.open(sealedPayload: record.payload), "frame \(outer.count) opens"))
            default:
                Issue.record("a \(record.tag) record on the air of a sealed link")
            }
        }
        while let record = try innerReader.next() {
            inner.append(record)
        }
        return Array(inner[before...])
    }

    /// `records`, sealed in one frame.
    func seal(_ records: [UInt8]...) throws -> [UInt8] {
        try #require(session?.sealer.seal(records.flatMap(\.self)))
    }

    /// A HELLO from `peer` as a sealing build writes it: the proof's bit, the seal's, and a nonce, unless told otherwise.
    static func hello(
        _ peer: NodeId, capabilities: Capabilities = Capabilities.local.union(.blobHave), nonce: [UInt8]? = LinkProof.freshNonce()
    ) -> [UInt8] {
        Hello(nodeId: peer.string, capabilities: capabilities, nonce: nonce).payload
    }

    /// The PROOF record `peer` signs as this end's role over `dialerHello` and `responderHello`, in `form`.
    func proof(_ peer: NodeId, form: LinkProof.Form? = nil, dialerHello: [UInt8], responderHello: [UInt8]) throws -> [UInt8] {
        let signed = try #require(form ?? shares.map { .sealed($0) })
        let payload = try LinkProof.payload(
            keys: LinkRig.keys(of: peer), form: signed, signer: role, dialerHello: dialerHello, responderHello: responderHello)
        return LinkRecord(.proof, payload: payload).encoded ?? []
    }
}

extension LinkRig {
    /// The advert flags of a sealing peer that reads GATT payloads.
    static let sealingFlags = AdvertPayload.dialsGattPeersFlag | AdvertPayload.linkSealFlag

    /// Sights `peer` with the seal's flag until promotion dials it, and opens the dial: answers the channel.
    func dialSealed(_ peer: NodeId) throws -> ChannelID {
        sightToPromotion(peer, flags: Self.sealingFlags)
        let id = try #require(radio.dials.last?.channel)
        _ = handle(.connected(id))
        return id
    }
}

extension LinkRecord {
    /// A record's bytes, for a test.
    static func bytes(_ tag: Tag, _ payload: [UInt8]) -> [UInt8] {
        LinkRecord(tag, payload: payload).encoded ?? []
    }
}
