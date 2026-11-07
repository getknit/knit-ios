import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A link manager on a fake radio and a hand-moved clock.
struct LinkRig {
    /// Three identities in a known order of their ids: the larger dials, as on Android. Each id derives from its keys, so
    /// a link between rigs proves itself.
    static let identities = [TestPeer(seed: 1), TestPeer(seed: 2), TestPeer(seed: 3)].map(\.keys).sorted { $0.nodeId < $1.nodeId }
    static let ids = identities.map(\.nodeId)
    static let low = ids[0]
    static let middle = ids[1]
    static let high = ids[2]

    /// The keys behind one of ``ids``.
    static func keys(of node: NodeId) -> IdentityKeys {
        guard let keys = identities.first(where: { $0.nodeId == node }) else {
            fatalError("\(node) is none of the rig's three")
        }
        return keys
    }

    /// The ids whose stored profile the manager is told carries ``Capabilities/linkProof``.
    final class ProofProfiles {
        var ids: Set<NodeId> = []
    }

    let radio: FakeRadio
    let clock: ManualClock
    let log: RecordingLog
    let links: LinkManager
    /// What the store would say of each id's profile: empty unless a test fills it.
    let proofProfiles = ProofProfiles()

    init(
        local: NodeId,
        advertisesServiceData: Bool = true,
        dialsGattPeers: Bool = true,
        servesDoorbell: Bool = false,
        reportsFileWrites: Bool = false,
        background: Bool = false,
        configuration: LinkManager.Configuration = LinkManager.Configuration(),
        log: RecordingLog = RecordingLog(),
        partials: any PartialBlobStore = MemoryPartialBlobStore()
    ) {
        self.log = log
        radio = FakeRadio(
            advertisesServiceData: advertisesServiceData,
            dialsGattPeers: dialsGattPeers,
            servesDoorbell: servesDoorbell,
            reportsFileWrites: reportsFileWrites
        )
        clock = ManualClock(wall: 1_756_200_000_000, monotonic: 1000)
        let profiles = proofProfiles
        links = LinkManager(
            identity: Self.keys(of: local),
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 3),
            configuration: configuration,
            log: log,
            partials: partials
        ) { profiles.ids.contains($0) }
        links.start()
        if background {
            _ = links.setInBackground(true)
        }
    }

    /// Whether the manager logged `line` at the info level.
    func said(_ line: String) -> Bool {
        log.all.contains("info \(line)")
    }

    func handle(_ event: RadioEvent) -> [LinkManager.Event] {
        links.handle(event)
    }

    func advance(_ milliseconds: Int64) -> [LinkManager.Event] {
        clock.advance(milliseconds)
        return links.advance()
    }

    /// Moves the clock on, firing what falls due, while `peer` stays in range: sighted every two seconds, and once more
    /// at the end.
    @discardableResult
    func advance(_ milliseconds: Int64, hearing peer: NodeId) -> [LinkManager.Event] {
        var events: [LinkManager.Event] = []
        var left = milliseconds
        while left > 0 {
            let step = min(left, 2000)
            events += advance(step)
            events += handle(.sighted(Self.sighting(peer)))
            left -= step
        }
        return events
    }

    /// Sights `peer` twice, 5 s apart, and leaves it quiet: its dwell ends 7 s later with nothing heard.
    func hear(_ peer: NodeId, rssi: Int = -50) {
        _ = handle(.sighted(Self.sighting(peer, rssi: rssi)))
        clock.advance(5000)
        _ = handle(.sighted(Self.sighting(peer, rssi: rssi)))
    }

    /// Sights `peer` every two seconds, as a scanner reports it, until it has dwelled long enough to promote.
    @discardableResult
    func sightToPromotion(_ peer: NodeId, flags: UInt8 = AdvertPayload.dialsGattPeersFlag, rssi: Int = -50) -> [LinkManager.Event] {
        var events: [LinkManager.Event] = []
        for step in 0...6 {
            if step > 0 {
                clock.advance(2000)
            }
            events += handle(.sighted(Self.sighting(peer, flags: flags, rssi: rssi)))
        }
        return events
    }

    /// Dials `peer` and completes the handshake as it would answer.
    func link(_ peer: NodeId, flags: UInt8 = AdvertPayload.dialsGattPeersFlag, rssi: Int = -50) throws -> ChannelID {
        sightToPromotion(peer, flags: flags, rssi: rssi)
        let id = try #require(radio.dials.last?.channel)
        _ = handle(.connected(id))
        _ = handle(.received(id, Self.helloRecord(peer)))
        return id
    }

    /// A peer dials us and sends its HELLO, carrying `capabilities`.
    func accept(_ peer: NodeId, on id: ChannelID, capabilities: Capabilities = 0xFFF) -> [LinkManager.Event] {
        _ = handle(.accepted(id))
        return handle(.received(id, Self.helloRecord(peer, capabilities: capabilities)))
    }

    /// Fires every deadline up to `time` in turn, as the `Mesh` actor's timer does, then moves the clock to `time`. A
    /// clock that jumps past a feed's wait reads as the app suspended (``FeedWindow/slept(_:now:)``).
    @discardableResult
    func run(until time: Int64) -> [LinkManager.Event] {
        var events: [LinkManager.Event] = []
        // Bounded, so a deadline that never moves fails the test rather than hanging it.
        for _ in 0..<10_000 {
            guard let next = links.nextDeadline, next <= time else {
                break
            }
            events += advance(max(0, next - clock.monotonicMilliseconds()))
        }
        clock.advance(time - clock.monotonicMilliseconds())
        return events
    }

    static func sighting(_ peer: NodeId, flags: UInt8 = AdvertPayload.dialsGattPeersFlag, rssi: Int = -50) -> RadioSighting {
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: peer, digestCue: 0, psm: 0x80, flags: flags)
        return RadioSighting(address: RadioAddress("addr-\(peer)"), advert: advert, rssi: rssi)
    }

    static func helloRecord(_ peer: NodeId, capabilities: Capabilities = 0xFFF) -> [UInt8] {
        LinkRecord(.hello, payload: Hello(nodeId: peer.string, capabilities: capabilities).payload).encoded ?? []
    }

    /// A HELLO from `peer` that proves itself: the bit, and a fresh nonce unless one is given.
    static func provingHello(
        _ peer: NodeId, nonce: [UInt8] = LinkProof.freshNonce(), capabilities: Capabilities = Capabilities.local.union(.blobHave)
    ) -> Hello {
        Hello(nodeId: peer.string, capabilities: capabilities, nonce: nonce)
    }

    /// The PROOF record `keys` writes as `signer` for a link whose HELLOs crossed as these payloads.
    static func proofRecord(
        _ keys: IdentityKeys, as signer: LinkProof.Role, dialerHello: [UInt8], responderHello: [UInt8]
    ) throws -> [UInt8] {
        let payload = try LinkProof.payload(keys: keys, signer: signer, dialerHello: dialerHello, responderHello: responderHello)
        return LinkRecord(.proof, payload: payload).encoded ?? []
    }

    /// A peer dials us on `id` with a HELLO that proves itself; answers the HELLO's payload, and what the manager said.
    func acceptProving(
        _ peer: NodeId, on id: ChannelID, nonce: [UInt8] = LinkProof.freshNonce(),
        capabilities: Capabilities = Capabilities.local.union(.blobHave)
    ) -> (hello: [UInt8], events: [LinkManager.Event]) {
        let hello = Self.provingHello(peer, nonce: nonce, capabilities: capabilities).payload
        _ = handle(.accepted(id))
        return (hello, handle(.received(id, LinkRecord(.hello, payload: hello).encoded ?? [])))
    }

    /// The payload of the first HELLO we wrote on `id`.
    func ourHelloPayload(on id: ChannelID) -> [UInt8]? {
        radio.records(on: id).first { $0.tag == .hello }?.payload
    }

    /// Finishes a proving peer's dial of us on `id`: its PROOF, by `keys` (the peer's own unless given), over the HELLO it
    /// sent and the reply we wrote.
    func proveDialer(_ peer: NodeId, on id: ChannelID, hello: [UInt8], keys: IdentityKeys? = nil) throws -> [LinkManager.Event] {
        let reply = try #require(ourHelloPayload(on: id))
        return handle(
            .received(id, try Self.proofRecord(keys ?? Self.keys(of: peer), as: .dialer, dialerHello: hello, responderHello: reply)))
    }

    /// A proving peer accepts our dial on `id`: its reply HELLO and its PROOF in one read, over the HELLO we wrote.
    func answerProving(_ peer: NodeId, on id: ChannelID) throws -> (reply: [UInt8], events: [LinkManager.Event]) {
        let ours = try #require(ourHelloPayload(on: id))
        let reply = Self.provingHello(peer).payload
        let proof = try Self.proofRecord(Self.keys(of: peer), as: .responder, dialerHello: ours, responderHello: reply)
        return (reply, handle(.received(id, (LinkRecord(.hello, payload: reply).encoded ?? []) + proof)))
    }

    static func frameRecord(_ wire: WireEnvelope) -> [UInt8] {
        LinkRecord(.frame, payload: wire.encoded).encoded ?? []
    }

    /// The FRAME record for a frame the engine behind the link must take past the router's id gate
    /// (``FrameId/admits(_:)``): a label id a test forgot to make canonical would otherwise be refused unnoticed.
    static func admittedRecord(_ frame: TestFrame, sourceLocation: SourceLocation = #_sourceLocation) -> [UInt8] {
        #expect(
            FrameId.admits(frame.envelope),
            "\(frame.envelope.type.rawValue) \(frame.envelope.id) is not its type's id shape: use frameIdOf",
            sourceLocation: sourceLocation
        )
        return frameRecord(frame.wire)
    }

    /// A signed-looking frame from the low peer; the link layer never checks signatures.
    static func signedFrame(_ id: String, sig: UInt8 = 1, type: FrameType = .chat) -> WireEnvelope {
        let envelope = RelayEnvelope(type: type, id: id, senderId: low.string, payload: ChatContent(body: id).encoded)
        return WireEnvelope(sig: Array(repeating: sig, count: 64), signed: envelope.encoded)
    }

    /// Whether `records` is the HELLO this node sends, alone: caps `c215f`, since it answers holder queries, proves its id
    /// and reads tags, or `c315f` when its radio serves a doorbell too, then a fresh nonce, whose bytes are random.
    static func isOurHello(_ records: [LinkRecord], _ local: NodeId, servesDoorbell: Bool = false) -> Bool {
        guard records.count == 1, let record = records.first, record.tag == .hello, let nonce = Hello(payload: record.payload).nonce else {
            return false
        }
        // A dial's HELLO names the form it dialed (`a`, ADR 2026-11.sv5t); an answer names none.
        let addressed = Hello(payload: record.payload).addressed.map { "|a\(Hex.encode($0))" } ?? ""
        return record.payload == Array("\(local)|1|\(servesDoorbell ? "c315f" : "c215f")|n\(Hex.encode(nonce))\(addressed)".utf8)
    }
}
