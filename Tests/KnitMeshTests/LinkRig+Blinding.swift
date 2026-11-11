import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

extension LinkRig {
    /// The PSM a rig listens on.
    static let psm: UInt16 = 0x81

    /// A blinding iPhone: no service data, a GATT reader that serves the doorbell, a build that may blind, our keys attached,
    /// `keys.key` handed in and taken, and its listener up, which brings the advert up on a tag.
    static func blindingIPhone(
        _ local: NodeId = high, keys: FakeKeys, background: Bool = false, log: RecordingLog = RecordingLog(), listening: Bool = true,
        switchOn: Bool = true
    ) -> LinkRig {
        var configuration = LinkManager.Configuration()
        configuration.blindsAdvert = true
        configuration.blindSwitchOn = switchOn
        let rig = LinkRig(
            local: local, advertisesServiceData: false, servesDoorbell: true, background: background, configuration: configuration, log: log
        )
        rig.links.attachPresenceKeys(keys.source)
        rig.links.ownPresenceKeyChanged(keys.key)
        _ = rig.links.advance()
        if listening {
            _ = rig.handle(.listening(psm: psm))
        }
        return rig
    }

    /// What the radio airs now.
    var aired: AdvertPayload? { radio.advertised.last }

    /// The tag on the air, or `nil` while the advert is clear.
    var airedTag: NodeId? { aired.flatMap { $0.blinded ? $0.advertised : nil } }

    /// What another iPhone reads of this one's GATT payload, heard at `address`.
    func sightingOfItsPayload(at address: String, rssi: Int = -50) -> RadioSighting? {
        aired.flatMap { AdvertPayload(gattValue: $0.gattValue) }.map { advert in
            RadioSighting(address: RadioAddress(address), advert: advert, rssi: rssi)
        }
    }

    /// The wall clock now.
    var wall: Int64 { clock.wallMilliseconds() }

    /// The slot edge after the wall clock now.
    var edge: Int64 { (BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds }

    /// Fires every deadline until the wall clock reads `wall`.
    @discardableResult
    func run(untilWall wall: Int64) -> [LinkManager.Event] {
        run(until: clock.monotonicMilliseconds() + (wall - self.wall))
    }

    /// The `TAG_NEXT` records written on `id`, their tags in order.
    func tagNexts(on id: ChannelID) -> [NodeId] {
        radio.records(on: id).filter { $0.tag == .tagNext }.compactMap { NodeId(bytes: $0.payload) }
    }

    /// Our tag for `slot` and `restart` under `key`.
    func tag(_ key: OwnPresenceKey, slot: Int64, restart: Int = 0) -> NodeId {
        BlindFixture.tag(key.key, owner: links.localId, slot: slot, restart: restart)
    }

    /// The slot the wall clock is in now.
    var slot: Int64 { BlindTag.slotOf(wallMilliseconds: wall) }
}
