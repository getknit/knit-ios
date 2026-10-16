import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// An Android phone for the ratchet's engine tests: a fixed identity, its signed prekey, and a real ``RatchetSessions``
/// over memory stores of its own, which seals DMs to the engine under test as Android's `RatchetSessions.sealDm` does
/// (`V2Author`, `InboundPipelineTest.kt:4707-4795`), and opens what the engine sends back. A second instance over the same
/// identity is the same phone after a wipe: a fresh store, so its next seal initiates again.
final class AndroidPeer {
    /// What Android's profile advertises: every bit through `CAP_CRYPTO_V3` (`0x15F`).
    static let capabilities: Int64 = 0x15F

    let peer: TestPeer
    let prekey: SignedPrekey
    let store = MemoryRatchetStore()
    let sessions: RatchetSessions

    /// Android on `peer`'s keys, with prekey `prekeyId`, whose pair is fixed by its id as ``TestPeer/prekey(id:)``'s is.
    init(_ peer: TestPeer, prekeyId: Int = 1) throws {
        self.peer = peer
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 200 + prekeyId))
        prekey = try SignedPrekey.mint(id: prekeyId, signedBy: peer.keys, createdAt: 0) { pair }
        sessions = RatchetSessions(identity: peer.keys, store: store, transactor: MemoryTransactor(stores: [store]))
    }

    var nodeId: NodeId { peer.nodeId }

    /// Its profile at `publishedAt`, carrying its prekey and the ratchet's bits, as every Android build since 2.3.0 sends.
    func profile(publishedAt: Int64, version: Int64? = nil, name: String = "Android") throws -> TestFrame {
        try peer.profile(
            name: name, version: version, publishedAt: publishedAt, capabilities: Self.capabilities, prekey: prekey.info)
    }

    /// A DM to `recipient` sealed with the ratchet against `recipientPrekey`: `content` laid out compactly under v3 when
    /// `v3` asks and the content has a compact form, else named under v2, at the clock `now` (the frame's `sentAt` unless
    /// told otherwise). `edit` changes the envelope after the seal, as a malformed or stale frame would carry it, before
    /// the frame is signed, or sent unsigned point to point when `signed` is false.
    func dm(
        _ content: MessageContent,
        to recipient: TestPeer,
        prekey recipientPrekey: PeerPrekey,
        id: String,
        sentAt: Int64,
        now: Int64? = nil,
        v3: Bool = false,
        signed: Bool = true,
        relay: Bool = true,
        edit: (inout EncEnvelope) -> Void = asSealed
    ) throws -> TestFrame {
        let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: recipient.nodeId.string)
        let bytes = content.sealBytes(v3: v3)
        #expect(!v3 || bytes.scheme == EncEnvelope.Version.compactRatchet, "v3 asked for content with a compact form")
        let answer = sessions.sealDm(
            to: recipient.keys.bundle,
            prekey: recipientPrekey,
            plaintext: bytes.plaintext,
            aad: aad,
            now: now ?? sentAt,
            v3: bytes.scheme == EncEnvelope.Version.compactRatchet
        )
        guard case .settled(.sealed(var envelope)) = answer else {
            Issue.record("Android's seal failed: \(answer)")
            throw Refused()
        }
        edit(&envelope)
        let relayEnvelope = RelayEnvelope(
            type: .chat,
            id: id,
            senderId: nodeId.string,
            sentAt: sentAt,
            recipientId: recipient.nodeId.string,
            payload: ChatContent(enc: envelope).encoded
        )
        guard signed else {
            return TestFrame(wire: WireEnvelope(relay: relay, sig: [], signed: relayEnvelope.encoded), envelope: relayEnvelope)
        }
        return try peer.signed(relayEnvelope, relay: relay)
    }

    /// Leaves an envelope as it was sealed: what ``dm(_:to:prekey:id:sentAt:now:v3:signed:relay:edit:)`` does unless told.
    static func asSealed(_: inout EncEnvelope) {
        // Nothing to change: the frame goes as it was sealed.
    }

    /// A plain DM saying `body`.
    func dm(
        _ body: String,
        to recipient: TestPeer,
        prekey recipientPrekey: PeerPrekey,
        id: String,
        sentAt: Int64,
        v3: Bool = false
    ) throws -> TestFrame {
        try dm(MessageContent(body: body), to: recipient, prekey: recipientPrekey, id: id, sentAt: sentAt, v3: v3)
    }

    /// This phone's reset toward `recipient`, as its `sealResetDm` seals one, stamped and sealed at `stamp` on its own
    /// clock: a fresh init, flagged, or the marker under an init it still holds unanswered.
    func resetDm(to recipient: TestPeer, prekey recipientPrekey: PeerPrekey, id: String, at stamp: Int64) throws -> TestFrame {
        let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: stamp, thread: recipient.nodeId.string)
        let sealing = sessions.sealResetDm(
            to: recipient.keys.bundle, prekey: recipientPrekey, plaintext: RatchetSessions.resetPlaintext, aad: aad, now: stamp)
        guard case .settled(.sealed(let envelope, _)) = sealing else {
            Issue.record("Android's reset: \(sealing)")
            throw Refused()
        }
        let relay = RelayEnvelope(
            type: .chat,
            id: id,
            senderId: nodeId.string,
            sentAt: stamp,
            recipientId: recipient.nodeId.string,
            payload: ChatContent(enc: envelope).encoded
        )
        return try peer.signed(relay)
    }

    /// Opens `frame`, a ratchet DM the engine under test sent this phone, at `now`.
    func open(_ frame: Written, from sender: TestPeer, now: Int64) throws -> RatchetSessions.Answer<RatchetSessions.Opening<Void>> {
        let envelope = frame.envelope
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: nodeId.string)
        let held = prekey
        let opening = try #require(RatchetSessions.Frame(envelope: enc, aad: aad))
        return sessions.open(
            opening, from: sender.keys.bundle, now: now, prekeys: { $0 == held.id ? held : nil }, alongside: { _ in () })
    }

    /// The session this phone holds with `peer`, or `nil`.
    func session(with peer: TestPeer) -> RatchetEngine.SessionState? {
        sessions.session(of: peer.nodeId)
    }

    struct Refused: Error {}
}

extension EngineFixture {
    /// An engine for `me` with the ratchet's switch on and the ring `keychain` keeps, which its start mints prekey 1 into
    /// when it holds none, as a Debug iPhone with `-ratchet` runs. A reinstall is another engine over fresh stores and the
    /// same keychain.
    static func ratcheting(
        _ me: TestPeer,
        stores: MeshStores = .inMemory(),
        keychain: KeptSecretStore? = nil,
        wall: Int64 = start,
        configuration: MeshConfiguration = MeshConfiguration(ratchet: true)
    ) throws -> EngineFixture {
        let ring = try PrekeyRing.load(for: me.keys, from: keychain ?? KeptSecretStore(me.keys.storedForm))
        return EngineFixture(me, stores: stores, configuration: configuration, prekeys: ring, wall: wall)
    }

    /// Our newest prekey, as a peer pins it from our profile.
    func ourPrekey() throws -> PeerPrekey {
        let newest = try #require(engine.prekeyRing?.newest, "a ratcheting engine mints its first prekey at start")
        return try #require(PeerPrekey(verifying: newest.info, signedBy: me.keys.bundle))
    }

    /// Pins `android`'s profile by delivering it from the phone itself, at our clock.
    func pin(_ android: AndroidPeer) throws {
        deliver(try android.profile(publishedAt: clock.wallMilliseconds()), from: android.peer)
    }

    /// `count` frames from `android` that the session we hold cannot read, stamped `sentAt` on the peer's clock and sealed at
    /// its `now`: the init dropped and the base moved to our first epoch, a peer that holds a session we do not share
    /// (`deliverUnreadable`, `InboundPipelineTest.kt:5115-5133`).
    func deliverUnreadable(from android: AndroidPeer, tag: String, sentAt: Int64, now: Int64 = start, count: Int = 3) throws {
        let prekey = try ourPrekey()
        for index in 0..<count {
            let frame = try android.dm(
                MessageContent(body: "unreadable"),
                to: me,
                prekey: prekey,
                id: "\(tag)-\(index)",
                sentAt: sentAt,
                now: now
            ) { $0.ratchet = $0.ratchet?.steady }
            deliver(frame, from: android)
        }
    }

    /// Hands the engine a frame from `android`.
    func deliver(_ frame: TestFrame, from android: AndroidPeer) {
        deliver(frame, from: android.peer)
    }

    /// What the engine's ratchet store holds for `peer`.
    func ratchetRecords(of peer: TestPeer) -> RatchetPeerRecords {
        stores.ratchet.records(of: peer.nodeId)
    }

    /// The resets the engine sent: DM-form chats to `peer` whose plaintext is the reset marker, which only `peer` could
    /// open, so they are told apart by their flag or their init.
    func resetsSent(to peer: TestPeer) -> [Written] {
        transport.written(.chat).filter { written in
            guard ExactKey(written.envelope.recipientId ?? "") == ExactKey(peer.nodeId.string),
                let header = (try? ChatContent(decoding: written.envelope.payload))?.enc?.ratchet
            else {
                return false
            }
            return header.initial != nil || header.flags & RatchetHeader.resetFlag != 0
        }
    }

    /// The ids our cleartext receipts acknowledged.
    var acknowledged: [String] {
        transport.written(.receipt).compactMap { (try? ReceiptContent(decoding: $0.envelope.payload))?.ackId }
    }
}

/// The messages `events` announced, as their records.
func receivedRecords(in events: [MeshEvent]) -> [MessageRecord] {
    events.compactMap { event in
        guard case .received(let record, _) = event else {
            return nil
        }
        return record
    }
}

/// The ids `events` said were delivered.
func deliveredIds(in events: [MeshEvent]) -> [String] {
    events.compactMap { event in
        guard case .delivered(let id) = event else {
            return nil
        }
        return id
    }
}
