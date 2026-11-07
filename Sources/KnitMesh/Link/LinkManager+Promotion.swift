import KnitWire

/// Promotion: whom the link manager dials, read over what is sighted and linked, and where each dial is booked (ADR
/// 2026-09.6es2, amended by ADR 2026-11.sv5t for blinded adverts).
extension LinkManager {
    /// Runs the promotion policy over what is sighted and linked, and acts on it (`driveConnections`).
    func promote(now: Int64) -> [Event] {
        guard running else {
            return []
        }
        let snapshots = presence.snapshots(now: now)
        pruneWithPresence(snapshots, now: now)
        let links = liveLinks.map { link in
            PromotionPolicy.LinkSnapshot(nodeId: link.neighbor.nodeId, smoothedRssi: linkRssi(link), ageMilliseconds: now - link.since)
        }
        let backoff = backingOff(snapshots, now: now)
        let promotion = promotionConfiguration
        let pool = keepingOneHeadStart(candidates(snapshots), backoff: backoff, configuration: promotion)
        // At most one, by keepingOneHeadStart.
        let headStart = pool.first(where: isHeadStartCandidate)
        let decision = PromotionPolicy.decide(
            candidates: pool,
            links: links,
            backoff: backoff,
            configuration: promotion
        )
        var events: [Event] = []
        for node in decision.evict {
            if let id = liveChannel(to: node) {
                log.log(.info, "link evicting \(node)")
                events += retire(id, backingOff: false, now: now)
            }
        }
        for key in decision.promote {
            dial(key, headStart: headStart?.key == key ? headStart : nil, now: now)
        }
        return events
    }

    /// What a live link scores at the budget: its peer's smoothed RSSI while a sighting is attributed to it; once none is, a
    /// link whose peer was sighted and lost scores ``Configuration/absentLinkRssi``, and one never sighted, or one whose
    /// peer blinds (``LiveLink/blinds``), ``Configuration/unsightedLinkRssi``. Until `CAP_BLIND_ADVERT` ships every rotation
    /// is unannounced, so a blinding peer's new tag lands under a fresh handle and its id's presence lapses with the link
    /// still up: scored as lost it would be shed first at the budget (the ca7c9dd/1fee521 class).
    func linkRssi(_ link: LiveLink) -> Double {
        if let rssi = presence.smoothedRssi(of: link.neighbor.nodeId) {
            return rssi
        }
        return link.sighted && !link.blinds ? configuration.absentLinkRssi : configuration.unsightedLinkRssi
    }

    /// Drops the backoffs and addresses nothing holds: a backoff whose window has passed and that no present sighting, dial
    /// or link names, so a peer that left starts fresh when it returns, and an address no present sighting is kept under
    /// (design-pass finding 1: every key a present snapshot carries, its dial key, its address and its handle streak).
    func pruneWithPresence(_ snapshots: [PresenceTracker.Snapshot], now: Int64) {
        var kept = Set(dialing.keys).union(liveLinks.map { DialKey.peer(.node($0.neighbor.nodeId)) })
        kept.formUnion(busy.map(DialKey.peer))
        for snapshot in snapshots {
            kept.insert(.peer(snapshot.key))
            if let dial = dialKey(of: snapshot) {
                kept.insert(dial)
                let unresolved = snapshot.key.nodeId == nil
                kept.formUnion(
                    [DialKeys.addressKey(dial, unresolved: unresolved), DialKeys.handleKey(dial, unresolved: unresolved)].compactMap(\.self)
                )
            }
        }
        backoffs = backoffs.filter { now < $0.value.nextAt || kept.contains($0.key) }
        let present = Set(snapshots.map(\.key))
        addresses = addresses.filter { present.contains($0.key) }
    }

    /// When a sighted peer's dwell ends between its adverts, so that promotion runs then instead of at its next advert
    /// (``PromotionPolicy/untilDwellEnds(candidates:backoff:configuration:)``). A head-start peer's dwell counts its
    /// head start, so this is also when that ends; a tag's handle-keyed dwell is woken for as an id's is. A peer backing
    /// off waits for its backoff's own deadline, and the promotion that runs then asks again.
    func dwellDue(now: Int64) -> Int64? {
        let snapshots = presence.present(now: now)
        let wait = PromotionPolicy.untilDwellEnds(
            candidates: candidates(snapshots),
            backoff: backingOff(snapshots, now: now),
            configuration: promotionConfiguration
        )
        return wait.map { now + $0 }
    }

    /// Peers linked, being dialed (by the sighting each dial was attributed to), or proving themselves on a link they
    /// dialed, so that seeking does not dial a peer whose proof is on its way.
    var busy: Set<SightingKey> {
        var keys = Set(liveLinks.map { SightingKey.node($0.neighbor.nodeId) })
        keys.formUnion(provingDialers.map(SightingKey.node))
        for target in dialTargets {
            keys.insert(target.record.peerKey)
            if let expected = target.expected {
                keys.insert(.node(expected))
            }
        }
        return keys
    }

    /// The targets of the dials in flight: every ``dialing`` entry's channel, which ``dial(_:headStart:now:)`` opens as a
    /// dialer's and which leaves ``dialing`` when it closes.
    var dialTargets: [DialTarget] {
        var targets: [DialTarget] = []
        for id in dialing.values {
            if case .dialer(let target) = channels[id]?.role {
                targets.append(target)
            }
        }
        return targets
    }

    /// The sighted peers promotion may pick: ours to dial (``weDial(_:flags:)``), any while seeking
    /// (``dialsWhateverTheOrder``), or a flagged peer that would dial us once its head start ends
    /// (``isHeadStartCandidate(_:)``), and not refused. A clear sighting is passed over while its id is linked, dialed or
    /// proving. A blinded one is passed over while its own dial key is in flight, the id it is attributed to is being dialed
    /// or proving, or a live link holds it off (``isHeldOff(_:live:proven:)``), all read now, never frozen at the sighting.
    /// An unresolved form cannot be refused by id (knit-peer's `deny-link`), since it names none. A head-start peer's dwell
    /// counts its head start less, and none is a candidate while a head-start dial is open.
    func candidates(_ snapshots: [PresenceTracker.Snapshot]) -> [PresenceTracker.Snapshot] {
        let anyOrder = dialsWhateverTheOrder
        let headStartOpen = headStartDialInFlight
        let occupied = busy
        let live = Set(liveLinks.map(\.neighbor.nodeId))
        let proven = Set(liveLinks.filter(\.proven).map(\.neighbor.nodeId))
        let attributedDials = Set(dialTargets.map(\.record.peerKey))
        return snapshots.compactMap { snapshot in
            if let id = snapshot.key.nodeId, refused.contains(id) {
                return nil
            }
            if snapshot.advert.blinded {
                guard let dial = dialKey(of: snapshot), dialing[dial] == nil, !attributedDials.contains(snapshot.key),
                    !provingDialers.contains(where: { SightingKey.node($0) == snapshot.key }),
                    !isHeldOff(snapshot, live: live, proven: proven)
                else {
                    return nil
                }
            } else if occupied.contains(snapshot.key) {
                return nil
            }
            let form = AdvertOrder.Form.of(snapshot.advert)
            if anyOrder || weDial(form, flags: snapshot.advert.flags) || (!form.blinded && impostor.dials == snapshot.key.nodeId) {
                return snapshot
            }
            return isHeadStartCandidate(snapshot) && !headStartOpen ? withHeadStart(snapshot) : nil
        }
    }

    /// The per-peer keys backing off among `snapshots`: every backoff not run out, read back to the sightings it holds off
    /// (``DialKeys/backedOff(sighted:active:dialKey:)``), so a tag dial's streak, booked on its handle and address, holds
    /// off the sighting it dialed.
    func backingOff(_ snapshots: [PresenceTracker.Snapshot], now: Int64) -> Set<SightingKey> {
        let active = Set(backoffs.filter { now < $0.value.nextAt }.keys)
        // The presence tracker keeps one entry per key, so each key names one snapshot.
        var byKey: [SightingKey: PresenceTracker.Snapshot] = [:]
        for snapshot in snapshots where byKey[snapshot.key] == nil {
            byKey[snapshot.key] = snapshot
        }
        return DialKeys.backedOff(sighted: snapshots.map(\.key), active: active) { key in byKey[key].flatMap(dialKey(of:)) }
    }

    /// Dials the sighting kept under `key`, logging the head-start line first when `headStart` is the peer as promotion saw
    /// it. A dial to a blinded advert is a tag dial, booked on its handle and address whether or not a key resolves it
    /// (ADR 2026-11.sv5t), and reads the PSM of the sighting it dials: never one cached per address across a tag change.
    func dial(_ key: SightingKey, headStart: PresenceTracker.Snapshot?, now: Int64) {
        // A PSM of 0 means the peer's listener is not open; Android never advertises one. A blinded form's handle stands:
        // promotion picked it through its dial key, and nothing lets a handle go between.
        guard let address = addresses[key], let advert = presence.advert(of: key), advert.psm != 0,
            let dialKey = DialKeys.dialKey(form: .of(advert), key: key, address: address, handle: { formKeys.existing($0) })
        else {
            return
        }
        let form = AdvertOrder.Form.of(advert)
        if form.blinded {
            blindCounts.tagDials += 1
        }
        if let headStart {
            logHeadStartDial(headStart)
        }
        let kind: DialRecord.Kind = headStart != nil ? .headStart : weDial(form, flags: advert.flags) ? .ordinary : .seeking
        let linkedAtStart = key.nodeId.map { liveChannel(to: $0) != nil } ?? false
        let record = DialRecord(kind: kind, peerKey: key, linkedAtStart: linkedAtStart)
        let target = DialTarget(key: dialKey, form: form, address: address, record: record)
        let id = radio.dial(address, psm: advert.psm)
        channels[id] = Channel(role: .dialer(target), stage: .connecting, deadline: now + configuration.connectTimeoutMilliseconds)
        dialing[dialKey] = id
        // The harness reads `link dialing <id> on` for a clear dial; a tag dial names its handle, never the tag.
        log.log(.info, "link dialing \(target.shown) on \(id)")
    }
}
