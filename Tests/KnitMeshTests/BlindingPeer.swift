import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A scripted blinding Android, as knit-next ADR 2026-11.xp6d's writer behaves at `cad69c77b`: it airs a ``BlindTag`` from a
/// fixed presence key for the slot of the wall clock it is given, answers a tag dial with Android's reply (its `t`, its PROOF
/// over both HELLOs as they crossed), refuses with no reply a dialer whose HELLO lacks ``Capabilities/blindAdvert``
/// (`RefuseLegacy`, `BleAdmissionPolicy.kt:115`), dials with `t` and `a`, and writes `TAG_NEXT`.
struct BlindingPeer {
    /// The phone's identity: one of the rig's three, so its proofs verify.
    let id: NodeId
    /// Its presence key, the one a contact would list.
    let key: PresenceKey
    /// The flags its advert carries besides `FLAG_BLINDED`.
    let flags: UInt8
    /// Where it airs from.
    var address = RadioAddress("addr-blinding")

    init(_ id: NodeId, flags: UInt8 = AdvertPayload.dialsGattPeersFlag, keyByte: UInt8 = 7) {
        self.id = id
        self.flags = flags
        key = required(PresenceKey(bytes: [UInt8](repeating: keyByte, count: PresenceKey.byteCount)))
    }

    /// Its tag for the slot `wall` falls in, at `restart`.
    func tag(wall: Int64, restart: Int = 0) -> NodeId {
        BlindFixture.tag(key, owner: id, slot: BlindTag.slotOf(wallMilliseconds: wall), restart: restart)
    }

    /// Its blinded advert airing `tag`.
    func sighting(_ tag: NodeId, rssi: Int = -50) -> RadioSighting {
        let advert = AdvertPayload(capabilities: 0xFF, nodeId: tag, digestCue: 0, psm: 0x80, flags: flags | AdvertPayload.blindedFlag)
        return RadioSighting(address: address, advert: advert, rssi: rssi)
    }

    /// A HELLO from this phone, its `t` and `a` written as Android writes them after the nonce.
    func hello(told: NodeId?, addressed: NodeId? = nil, nonce: [UInt8] = LinkProof.freshNonce()) -> [UInt8] {
        let caps = Capabilities.local.union(.blobHave).union(.blindAdvert)
        var fields = ["\(id)", "1", caps.hex, "n\(Hex.encode(nonce))"]
        if let told {
            fields.append("t\(Hex.encode(told.bytes))")
        }
        if let addressed {
            fields.append("a\(Hex.encode(addressed.bytes))")
        }
        return Array(fields.joined(separator: "|").utf8)
    }

    /// Answers the rig's dial on `id`: refuses with no reply a HELLO lacking ``Capabilities/blindAdvert``, as a blinding
    /// phone does, else replies telling `told` and proves itself. Answers what the manager said.
    func answer(_ rig: LinkRig, on channel: ChannelID, told: NodeId?) throws -> [LinkManager.Event] {
        let ours = try #require(rig.ourHelloPayload(on: channel))
        guard Hello(payload: ours).capabilities.contains(.blindAdvert) else {
            return rig.handle(.closed(channel))
        }
        let reply = hello(told: told)
        let proof = try LinkRig.proofRecord(LinkRig.keys(of: id), as: .responder, dialerHello: ours, responderHello: reply)
        return rig.handle(.received(channel, required(LinkRecord(.hello, payload: reply).encoded) + proof))
    }

    /// Dials the rig on `channel` telling `told` and addressing the rig's id, and proves itself once answered.
    func dial(_ rig: LinkRig, on channel: ChannelID, told: NodeId?) throws -> [LinkManager.Event] {
        let ours = hello(told: told, addressed: rig.links.localId)
        _ = rig.handle(.accepted(channel))
        var events = rig.handle(.received(channel, required(LinkRecord(.hello, payload: ours).encoded)))
        events += try rig.proveDialer(id, on: channel, hello: ours)
        return events
    }

    /// A `TAG_NEXT` record announcing `tag`.
    static func tagNext(_ tag: NodeId) -> [UInt8] {
        required(LinkRecord(.tagNext, payload: tag.bytes).encoded)
    }
}

extension LinkRig {
    /// An iPhone: no service data, a GATT reader that serves the doorbell.
    static func iPhone(_ local: NodeId = high, background: Bool = false, claimsBlindAdvert: Bool = true) -> LinkRig {
        var configuration = LinkManager.Configuration()
        configuration.claimsBlindAdvert = claimsBlindAdvert
        return LinkRig(
            local: local, advertisesServiceData: false, servesDoorbell: true, background: background, configuration: configuration)
    }

    /// Hears `sighting` every two seconds for `milliseconds`, firing what falls due between.
    @discardableResult
    func hear(_ sighting: RadioSighting, for milliseconds: Int64) -> [LinkManager.Event] {
        var events = handle(.sighted(sighting))
        var left = milliseconds
        while left > 0 {
            let step = min(left, 2000)
            events += advance(step)
            events += handle(.sighted(sighting))
            left -= step
        }
        return events
    }
}
