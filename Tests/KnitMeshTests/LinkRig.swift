import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// A link manager on a fake radio and a hand-moved clock.
struct LinkRig {
    /// Three ids in a known order: the larger dials, as on Android.
    static let ids = [fixtureNodeId(1), fixtureNodeId(2), fixtureNodeId(3)].sorted()
    static let low = ids[0]
    static let middle = ids[1]
    static let high = ids[2]

    let radio: FakeRadio
    let clock: ManualClock
    let log = RecordingLog()
    let links: LinkManager

    init(local: NodeId, advertisesServiceData: Bool = true, configuration: LinkManager.Configuration = LinkManager.Configuration()) {
        radio = FakeRadio(advertisesServiceData: advertisesServiceData)
        clock = ManualClock(wall: 1_756_200_000_000, monotonic: 1000)
        links = LinkManager(
            localId: local,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 3),
            configuration: configuration,
            log: log
        )
        links.start()
    }

    func handle(_ event: RadioEvent) -> [LinkManager.Event] {
        links.handle(event)
    }

    func advance(_ milliseconds: Int64) -> [LinkManager.Event] {
        clock.advance(milliseconds)
        return links.advance()
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

    /// A peer dials us and sends its HELLO.
    func accept(_ peer: NodeId, on id: ChannelID) -> [LinkManager.Event] {
        _ = handle(.accepted(id))
        return handle(.received(id, Self.helloRecord(peer)))
    }

    static func sighting(_ peer: NodeId, flags: UInt8 = AdvertPayload.dialsGattPeersFlag, rssi: Int = -50) -> RadioSighting {
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: peer, digestCue: 0, psm: 0x80, flags: flags)
        return RadioSighting(address: RadioAddress("addr-\(peer)"), advert: advert, rssi: rssi)
    }

    static func helloRecord(_ peer: NodeId, capabilities: Capabilities = 0xFFF) -> [UInt8] {
        LinkRecord(.hello, payload: Hello(nodeId: peer.string, capabilities: capabilities).payload).encoded ?? []
    }

    static func frameRecord(_ wire: WireEnvelope) -> [UInt8] {
        LinkRecord(.frame, payload: wire.encoded).encoded ?? []
    }

    /// A signed-looking frame from the low peer; the link layer never checks signatures.
    static func signedFrame(_ id: String, sig: UInt8 = 1) -> WireEnvelope {
        let envelope = RelayEnvelope(type: .chat, id: id, senderId: low.string, payload: ChatContent(body: id).encoded)
        return WireEnvelope(sig: Array(repeating: sig, count: 64), signed: envelope.encoded)
    }

    /// The HELLO this node sends.
    static func ourHello(_ local: NodeId) -> LinkRecord {
        LinkRecord(.hello, payload: Array("\(local)|1|9".utf8))
    }
}
