public import KnitWire

/// Who dials whom, and who is admitted: the dial rule, promotion, the HELLO exchange and the records behind it.
extension LinkManager {
    // MARK: Dialing

    /// Whether we dial `peer` rather than wait for it to dial us.
    func weDial(_ peer: NodeId, flags: UInt8) -> Bool {
        guard localId < peer else {
            return true
        }
        let peerFindsUs = radio.advertisesServiceData || flags & AdvertPayload.dialsGattPeersFlag != 0
        return !peerFindsUs
    }

    /// Runs the promotion policy over what is sighted and linked, and acts on it (`driveConnections`).
    func promote(now: Int64) -> [Event] {
        guard running else {
            return []
        }
        let snapshots = presence.snapshots(now: now)
        let present = Set(snapshots.map(\.nodeId))
        // A peer that left, and whose window has passed, starts fresh when it returns.
        let busy = Set(liveLinks.map(\.neighbor.nodeId)).union(dialing.keys)
        backoffs = backoffs.filter { now < $0.value.nextAt || present.contains($0.key) || busy.contains($0.key) }
        let candidates = snapshots.filter { snapshot in
            weDial(snapshot.nodeId, flags: snapshot.advert.flags) && !busy.contains(snapshot.nodeId) && !refused.contains(snapshot.nodeId)
        }
        let links = liveLinks.map { link in
            let node = link.neighbor.nodeId
            let rssi = presence.smoothedRssi(of: node) ?? configuration.unsightedLinkRssi
            return PromotionPolicy.LinkSnapshot(nodeId: node, smoothedRssi: rssi, ageMilliseconds: now - link.since)
        }
        let backingOff = Set(backoffs.filter { now < $0.value.nextAt }.keys)
        let decision = PromotionPolicy.decide(
            candidates: candidates,
            links: links,
            backoff: backingOff,
            configuration: configuration.promotion
        )
        var events: [Event] = []
        for node in decision.evict {
            if let id = liveChannel(to: node) {
                log.log(.info, "link evicting \(node)")
                events += retire(id, backingOff: false, now: now)
            }
        }
        for node in decision.promote {
            dial(node, now: now)
        }
        return events
    }

    func dial(_ peer: NodeId, now: Int64) {
        // A PSM of 0 means the peer's listener is not open; Android never advertises one.
        guard let address = addresses[peer], let advert = presence.advert(of: peer), advert.psm != 0 else {
            return
        }
        let id = radio.dial(address, psm: advert.psm)
        channels[id] = Channel(role: .dialer(peer), stage: .connecting, deadline: now + configuration.connectTimeoutMilliseconds)
        dialing[peer] = id
        log.log(.info, "link dialing \(peer) on \(id)")
    }

    /// A dial opened: send our HELLO first, then wait for the reply (`LinkHandshake.writeHello`).
    func connected(_ id: ChannelID, now: Int64) {
        guard let channel = channels[id], channel.stage == .connecting else {
            return
        }
        writeHello(on: id)
        channels[id]?.stage = .awaitingHello
        channels[id]?.deadline = now + configuration.helloTimeoutMilliseconds
    }

    // MARK: Refusals

    /// Refuses every link with `peer`, both ways, until ``permit(_:)``: closes its live link and any dial to it,
    /// never dials it, and closes its HELLO when it dials us. A rig's tool for forcing a line of nodes that could
    /// all hear each other (knit-peer's `deny-link`). Answers the link that went down.
    public func refuse(_ peer: NodeId) -> [Event] {
        refused.insert(peer)
        let now = clock.monotonicMilliseconds()
        let theirs = channels.filter { $0.value.stage == .live(peer) || $0.value.role == .dialer(peer) }
        return theirs.keys.sorted(by: Self.inOrder).flatMap { retire($0, backingOff: false, now: now) }
    }

    /// Lets `peer` link again, and dials it now if the promotion rules say so.
    public func permit(_ peer: NodeId) -> [Event] {
        refused.remove(peer)
        return promote(now: clock.monotonicMilliseconds())
    }

    // MARK: Records

    func receive(_ bytes: [UInt8], on id: ChannelID, now: Int64) -> [Event] {
        guard channels[id] != nil else {
            return []
        }
        channels[id]?.reader.append(bytes)
        var events: [Event] = []
        // The role and stage only, never the whole channel: a copy of its reader would copy the buffer each record.
        while let (role, stage) = channels[id].map({ ($0.role, $0.stage) }) {
            let record: LinkRecord?
            do {
                record = try channels[id]?.reader.next()
            } catch {
                // Android throws on an unknown tag or a bad length and drops the link; so do we.
                log.log(.warning, "link \(id) sent a bad record: \(error)")
                return events + retire(id, backingOff: true, now: now) + promote(now: now)
            }
            guard let record else {
                break
            }
            switch stage {
            case .connecting:
                events += retire(id, backingOff: true, now: now)
            case .awaitingHello:
                events += handleHello(record, on: id, role: role, now: now)
            case .live(let peer):
                events += dispatch(record, from: peer, on: id, now: now)
            }
        }
        return events
    }

    func handleHello(_ record: LinkRecord, on id: ChannelID, role: Role, now: Int64) -> [Event] {
        let hello = record.tag == .hello ? Hello(payload: record.payload) : nil
        switch role {
        case .dialer(let expected):
            // The link's identity is what the peer says over the socket, and it must be the peer we dialed.
            guard let hello, NodeId(hello.nodeId) == expected else {
                return retire(id, backingOff: true, now: now) + promote(now: now)
            }
            return register(id, hello: hello, peer: expected, now: now)
        case .responder:
            guard let hello else {
                return retire(id, backingOff: false, now: now)
            }
            return admit(id, hello: hello, now: now)
        }
    }

    /// A dialer's HELLO: the responder's rule (`superviseAccepted`, with A1).
    func admit(_ id: ChannelID, hello: Hello, now: Int64) -> [Event] {
        guard let dialer = NodeId(hello.nodeId), dialer != localId, !refused.contains(dialer) else {
            return retire(id, backingOff: false, now: now)
        }
        let sighting = presence.isPresent(dialer, now: now) ? presence.advert(of: dialer) : nil
        if let sighting, weDial(dialer, flags: sighting.flags) {
            log.log(.info, "link refused \(dialer): we dial it")
            return retire(id, backingOff: false, now: now)
        }
        var events: [Event] = []
        if let existing = liveChannel(to: dialer) {
            guard sighting == nil else {
                log.log(.info, "link refused \(dialer): already linked")
                return retire(id, backingOff: false, now: now)
            }
            log.log(.info, "link \(dialer) replaced its stale link \(existing) with \(id)")
            events += retire(existing, backingOff: false, now: now)
        }
        writeHello(on: id)
        return events + register(id, hello: hello, peer: dialer, now: now)
    }

    func register(_ id: ChannelID, hello: Hello, peer: NodeId, now: Int64) -> [Event] {
        if liveChannel(to: peer) != nil {
            // Our dial landed while the peer's own link to us was already up: keep the older one.
            return retire(id, backingOff: false, now: now)
        }
        let neighbor = Neighbor(nodeId: peer, protocolVersion: hello.version, capabilities: hello.capabilities)
        channels[id]?.stage = .live(peer)
        channels[id]?.deadline = nil
        liveLinks.append(LiveLink(channel: id, neighbor: neighbor, since: now))
        dialing[peer] = nil
        backoffs[peer] = nil
        crossings.forget(link: id)
        log.log(.info, "link up \(peer) on \(id)")
        return [.up(neighbor)] + promote(now: now)
    }

    func dispatch(_ record: LinkRecord, from peer: NodeId, on id: ChannelID, now: Int64) -> [Event] {
        switch record.tag {
        case .frame:
            guard let wire = try? WireEnvelope(decoding: record.payload), let envelope = try? RelayEnvelope(decoding: wire.signed) else {
                undecodableFrames += 1
                return []
            }
            // In counts as a crossing too: nothing we later write to this link may be the frame it just gave us.
            _ = crossings.firstCrossing(link: id, key: FrameKey.of(wire, envelope), now: now)
            return [.frame(InboundFrame(wire: wire, envelope: envelope, from: peer))]
        case .digest:
            guard let ids = LinkJSON.digestIds(from: record.payload) else {
                return []
            }
            return [.digest(ids, from: peer)]
        case .fileHeader, .fileChunk, .fileEnd, .keepalive, .hello:
            // Avatars and attachments are out of the MVP: their records are discarded as they stream by. A stray
            // HELLO after the handshake means nothing, and a keepalive's arrival is all it says.
            return []
        }
    }
}
