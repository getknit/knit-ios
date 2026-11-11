public import KnitCrypto
public import KnitWire

/// The blinded-advert reader (knit-next ADR 2026-11.xp6d's reader; ADR 2026-11.sv5t; knit-ios #42): resolving what a
/// sighting names, the tag dial's proof, `TAG_NEXT`, and the contacts' presence keys. The writer, which airs our own tag, is
/// `LinkManager+Writer.swift` (ADR 2026-11.prsp); our own tags, current and previous, resolve to nobody here.
///
/// - **Sightings.** A clear advert is its own id. A blinded one is resolved (``AdvertAliases``) and kept under the key its
///   answer gives (``BlindSightings``): the resolved id, or its tag's handle (``FormKeys``). Every blinded form gets a
///   handle, resolved or not, since every dial to a blinded advert is a tag dial booked on the handle and the address.
/// - **Suppression** is read when a dial is decided, never frozen at the sighting (``isHeldOff(_:live:proven:)``).
/// - **The tag dial** expects no id, requires a proof and takes the proven one (``answeredTag(_:_:hello:payload:now:)``,
///   ``provedTagDial(_:_:_:now:)``).
extension LinkManager {
    /// The reader's own counts.
    struct BlindCounts {
        var tagsHeard = 0
        var tagDials = 0
        var tagDialsProven = 0
        var tagNextTaken = 0
        var tagNextRefused = 0
    }

    /// What the reader did, counts only, never a tag or a key: what `status` reports under `aliases`.
    public struct AliasCounters: Sendable, Equatable {
        /// Blinded adverts heard that were not ours.
        public var tagsHeard: Int
        /// Resolutions by a contact's key, a link's claim and a dialer's hint.
        public var resolvedByKey: Int
        public var resolvedByClaim: Int
        public var resolvedByHint: Int
        /// Tags held under a handle now, at most 512.
        public var unresolvedForms: Int
        /// Handles the cap let go.
        public var formsEvicted: Int
        /// Dials to a blinded advert, and those that proved.
        public var tagDials: Int
        public var tagDialsProven: Int
        public var claimsRecorded: Int
        public var claimsDropped: Int
        public var claimsVoided: Int
        /// Tag dials that proved another id than a contact's key names: a replayed tag.
        public var keyProofMismatches: Int
        /// `TAG_NEXT` records handed to the resolver, and those dropped or rate-limited.
        public var tagNextTaken: Int
        public var tagNextRefused: Int
        /// Contacts whose keys are listed, and the expected tags listed for them.
        public var contacts: Int
        public var expectedTags: Int
    }

    /// The reader's counters.
    public var aliasCounters: AliasCounters {
        let counted = aliases.counters
        return AliasCounters(
            tagsHeard: blindCounts.tagsHeard,
            resolvedByKey: counted.resolvedByKey,
            resolvedByClaim: counted.resolvedByClaim,
            resolvedByHint: counted.resolvedByHint,
            unresolvedForms: formKeys.count,
            formsEvicted: formKeys.evicted,
            tagDials: blindCounts.tagDials,
            tagDialsProven: blindCounts.tagDialsProven,
            claimsRecorded: counted.claimsRecorded,
            claimsDropped: counted.claimsDropped,
            claimsVoided: counted.claimsVoided,
            keyProofMismatches: counted.keyProofMismatches,
            tagNextTaken: blindCounts.tagNextTaken,
            tagNextRefused: blindCounts.tagNextRefused,
            contacts: counted.tableContacts,
            expectedTags: counted.tableSize
        )
    }

    // MARK: MeshTransport

    /// The direct contacts' presence keys, newest first, at most three each, the whole listing each time. Gains go through
    /// ``KeyChurnLimiter``, whose held listings apply at ``nextDeadline``; drops apply at once.
    public func listPresenceKeys(_ listing: [NodeId: [PresenceKey]]) {
        if let applied = keyLimiter.offer(listing.filter { $0.key != localId }, now: clock.monotonicMilliseconds()) {
            applyKeys(applied)
        }
    }

    func applyKeys(_ listing: [NodeId: [PresenceKey]]) {
        aliases.setKeys(listing.compactMapValues { ExpectedTagTable.ContactKey(keys: $0) })
    }

    // MARK: Sightings

    /// The key a sighting is kept under, or `nil` to drop it: our own advert, a malformed one, or a replay.
    /// Resolving a blinded form mints its handle here, the one place a handle is minted, and forgets the entries of the one
    /// the cap let go.
    func sightingKey(of sighting: RadioSighting) -> SightingKey? {
        let advert = sighting.advert
        guard advert.blinded else {
            return advert.advertised == localId ? nil : .node(advert.advertised)
        }
        let tag = advert.advertised
        let resolution = aliases.resolve(.of(advert))
        if resolution == .malformed || resolution == .own {
            return nil
        }
        blindCounts.tagsHeard += 1
        let pinned = pinnedHandles
        let minted = formKeys.handle(for: tag) { pinned.contains($0) }
        if let gone = minted.evicted {
            forgetHandle(gone)
        }
        let replayed = replayMarks.replayed(tag, at: sighting.address)
        guard let attribution = BlindSightings.attribute(resolution, handle: minted.handle, replayed: replayed),
            attribution.key != .node(localId)
        else {
            return nil
        }
        let held = SightingKey.form(minted.handle)
        switch attribution.history {
        case .carry:
            presence.move(held, to: attribution.key)
            addresses[held] = nil
        case .drop:
            presence.forget(held)
            addresses[held] = nil
        case .inPlace:
            break
        }
        for gone in presence.forgetOthers(airing: tag, except: attribution.key) {
            addresses[gone] = nil
        }
        return attribution.key
    }

    /// The handles a live dial key names, which the cap never lets go: a dial in flight, a backoff, a held proven link's
    /// held-dial key.
    var pinnedHandles: Set<FormHandle> {
        var pinned = Set<FormHandle>()
        for key in Array(dialing.keys) + Array(backoffs.keys) + Array(heldDials.values) {
            switch key {
            case .tag(let handle, _), .peer(.form(let handle)):
                pinned.insert(handle)
            case .peer(.node), .address:
                break
            }
        }
        return pinned
    }

    /// The cap let `handle` go: what was kept under it goes too.
    func forgetHandle(_ handle: FormHandle) {
        presence.forget(.form(handle))
        addresses[.form(handle)] = nil
        refusedDials = refusedDials.filter { $0.key.tagHandle != handle }
    }

    /// The key a dial to `snapshot` is booked under: its id when clear, its tag's handle and address when blinded, or `nil`
    /// for a blinded form whose handle has gone (it is dialable again once it is heard again).
    func dialKey(of snapshot: PresenceTracker.Snapshot) -> DialKey? {
        DialKeys.dialKey(form: .of(snapshot.advert), key: snapshot.key, address: addresses[snapshot.key]) { formKeys.existing($0) }
    }

    /// Whether a live link holds off a dial to a blinded `snapshot` now, read when the dial is decided: our own held proven
    /// dial to the same tag at the same address (``DialKeys/dialHeld(blinded:held:dialKey:)``), or the answer the tag
    /// resolves to now, by key while its id holds a proven link, by claim while the claimant's link is the one held, and
    /// by hint while the hint's own link is held (ADR 2026-11.sv5t's departure; ``BlindSightings/suppressor(of:)``). An
    /// unresolved form is held off by nothing else. One lookup, at decide time, so an answer that went stale since the
    /// sighting is never read. Promotion asks it of a blinded sighting only (``candidates(_:)``).
    func isHeldOff(_ snapshot: PresenceTracker.Snapshot, live: Set<NodeId>, proven: Set<NodeId>) -> Bool {
        if DialKeys.dialHeld(blinded: true, held: Set(heldDials.values), dialKey: { dialKey(of: snapshot) }) {
            return true
        }
        guard let answer = aliases.standing(snapshot.advert.advertised) else {
            return false
        }
        let suppressor: Suppressor<ChannelID> = BlindSightings.suppressor(of: answer)
        return suppressor.suppressed(id: answer.nodeId, linked: live, proven: proven) { self.liveChannel(to: $0) }
    }

    // MARK: The tag dial

    /// The reply to our tag dial, `payload` as it crossed (`LinkHandshake.dialTag`, `LinkHandshake.kt:134-154`): one naming
    /// us fails; one without ``Capabilities/linkProof``, or with the bit and no nonce, fails as `unproven` or `nonce`;
    /// otherwise its PROOF is awaited, to be verified against the reply's own id. Every failure is booked on the dial key,
    /// and while unresolved on its address and handle, never on the id the reply named. The radio hears nothing of an
    /// unproven reply (`heardHello`), since nothing it says is yet believed.
    func answeredTag(_ id: ChannelID, _ target: DialTarget, hello: Hello?, payload: [UInt8], now: Int64) -> [Event] {
        guard let hello, let named = NodeId(hello.nodeId) else {
            return retire(id, backingOff: true, now: now) + promote(now: now)
        }
        guard named != localId else {
            log.log(.info, "link \(id) tag dial to \(target.shown) reached a node naming us")
            return retire(id, backingOff: true, now: now) + promote(now: now)
        }
        guard provesLinks, hello.capabilities.contains(.linkProof), hello.nonce != nil, let ours = channels[id]?.wroteHello else {
            proofFailed(on: id, for: named, why: hello.capabilities.contains(.linkProof) && provesLinks ? "nonce" : "unproven")
            return retire(id, backingOff: true, now: now) + promote(now: now)
        }
        let claim = Claim(peer: named, hello: hello, sighted: true)
        awaitProof(on: id, PendingProof(claim: claim, dialerHello: ours, responderHello: payload, displacing: nil), now: now)
        return []
    }

    /// Our tag dial proved `pending.peer`. The safety net first (ADR 2026-11.sv5t): a proven link already held under that
    /// id is retired, as Android's responder replaces in that case, so the engine sees `.down` then `.up`; any unproven
    /// link claiming the id is displaced as R3 has it. Then the resolver hears the dial (`onDialed`, which runs
    /// `onDialProved` first). A refused id never comes here: ``handleProof(_:_:on:role:now:)`` closes its dial before our
    /// PROOF (``refusedTagDial(_:_:_:now:)``). The handle's history moves to the id unless a key names the tag another id's
    /// (a replay), and the held-dial key is written before the link registers.
    func provedTagDial(_ id: ChannelID, _ target: DialTarget, _ pending: PendingProof, now: Int64) -> [Event] {
        let peer = pending.peer
        var events: [Event] = []
        if let held = liveLinks.first(where: { $0.neighbor.nodeId == peer && $0.proven }) {
            // The line the harness reads for a replacement (`IOS_CHANNEL_ENDINGS`), byte for byte.
            log.log(.info, "link \(peer) replaced its stale link \(held.channel) with \(id)")
            heldStreaks.moved(from: held.channel, to: id, fromHeldMilliseconds: now - held.since)
            events += retire(held.channel, backingOff: false, now: now)
        }
        for channel in liveLinks.filter({ $0.neighbor.nodeId == peer && !$0.proven }).map(\.channel) {
            log.log(.info, "link \(channel) displaced: \(peer) proved itself on \(id)")
            claims.claimRefused()
            events += retire(channel, backingOff: false, now: now)
        }
        let mismatches = aliases.keyProofMismatchCount
        let told = pending.claim.hello.told.flatMap(NodeId.init(bytes:))
        // Only now is the reply believed, so only now may it retire a payload read for another form (rule 2; ADR 2026-11.prsp).
        radio.heardHello(from: peer, told: told, announced: aliases.announced(by: peer), on: id)
        aliases.onDialed(id, dialed: target.form, told: told, provenId: peer)
        if aliases.keyProofMismatchCount > mismatches {
            replayMarks.mark(target.form.advertised, at: target.address)
        } else if let handle = target.handle {
            presence.move(.form(handle), to: .node(peer))
            if let address = addresses.removeValue(forKey: .form(handle)) {
                addresses[.node(peer)] = address
            }
        }
        heldDials[id] = DialKeys.heldDial(target.key, proven: true)
        blindCounts.tagDialsProven += 1
        log.log(.info, "link \(target.shown) proved \(peer) on \(id)")
        return events + register(id, pending.claim, proven: true, now: now)
    }

    /// Our tag dial's responder proved `pending.peer`, an id this node refuses (``refuse(_:)``, knit-peer's `deny-link`):
    /// closed before our PROOF, so the peer registers nothing either. The resolver hears only the proof (`onDialProved`),
    /// and a replay is still marked (`onTagDialed`, `BluetoothMeshTransport.kt:3889-3899` at `cad69c77b`). Nothing backs
    /// off, since the refusal is our policy and no failure of the peer's, and a backoff would outlive ``permit(_:)``;
    /// instead the dial key is marked (``refusedDials``), so the tag at that address is not dialed again while the id is
    /// refused, until the tag goes 90 s unheard or the cap lets its handle go. The lab iPhone on `1d6affd` redialed such
    /// a tag at every advert, 1 to 3 s apart, with no line between.
    func refusedTagDial(_ id: ChannelID, _ target: DialTarget, _ pending: PendingProof, now: Int64) -> [Event] {
        let peer = pending.peer
        let mismatches = aliases.keyProofMismatchCount
        aliases.onDialProved(target.form, provenId: peer)
        if aliases.keyProofMismatchCount > mismatches {
            replayMarks.mark(target.form.advertised, at: target.address)
        }
        refusedDials[target.key] = peer
        log.log(.info, "link \(target.shown) proved refused \(peer) on \(id)")
        // A peer waiting for the head-start slot this dial held is dialed now, not at its next advert; the mark keeps
        // this tag out.
        return retire(id, backingOff: false, now: now) + promote(now: now)
    }

    /// Whether a dial under `dialKey` once proved an id still refused (``refusedTagDial(_:_:_:now:)``).
    func provedRefused(_ dialKey: DialKey) -> Bool {
        refusedDials[dialKey].map(refused.contains) == true
    }

    // MARK: TAG_NEXT

    /// Takes the newest `TAG_NEXT` `id` sent in the read just handled: a suspended iPhone reads a locked hour's
    /// announcements back to back, and the rate limit would keep the oldest. Only a proven link whose HELLO carries
    /// ``Capabilities/blindAdvert``, and the one registered under its id, is heard (`onTagNext`,
    /// `BluetoothMeshTransport.kt:4434-4447`); any other is dropped and counted.
    func takeTagNext(on id: ChannelID) {
        guard let tag = tagNextHeld.removeValue(forKey: id) else {
            return
        }
        guard let link = liveLinks.first(where: { $0.channel == id }), link.proven,
            link.neighbor.capabilities.contains(.blindAdvert),
            BlindSightings.current(registered: liveChannel(to: link.neighbor.nodeId), link: id)
        else {
            blindCounts.tagNextRefused += 1
            return
        }
        let outcome = aliases.onTagNext(id, provenId: link.neighbor.nodeId, tag: tag)
        switch outcome {
        case .rateLimited, .ignored:
            blindCounts.tagNextRefused += 1
        case .recorded, .pending, .hinted, .redundant, .contradicted, .contested, .full:
            blindCounts.tagNextTaken += 1
        }
        noteLinkForm(id, tag: tag, outcome: outcome)
    }

    // MARK: Deadlines

    /// When the reader and the writer next have work, the wall clock's instants converted to the monotonic one: the next
    /// slot edge while any contact's keys are listed (the window slides there), when the key limiter frees a held listing,
    /// the slot turn's next step while we blind (``turnDue(now:wall:)``), a link's announced form reaching its edge, and now
    /// while a key change waits to be taken.
    func blindDue(now: Int64) -> Int64? {
        let wall = clock.wallMilliseconds()
        let edge: Int64? = aliases.listsKeys ? now + nextSlotEdge(wall: wall) : nil
        let keyChange: Int64? = blindWriter.keyChangeDue ? now : nil
        let form = blindWriter.notes.nextDue.map { now + max(0, $0 - wall) }
        return [edge, keyLimiter.nextDueAt(), turnDue(now: now, wall: wall), keyChange, form].compactMap(\.self).min()
    }

    /// The wall-clock wait to the next slot edge, at least 1 ms.
    func nextSlotEdge(wall: Int64) -> Int64 {
        let slot = BlindTag.slotOf(wallMilliseconds: wall)
        return max(1, (slot + 1) * BlindTag.slotMilliseconds - wall)
    }

    /// Slides the window, applies a key listing the limiter has freed, takes a key change, runs the slot turn, and applies
    /// the link forms whose edge has come.
    func advanceBlind(now: Int64) {
        if aliases.listsKeys {
            aliases.slide()
        }
        if let applied = keyLimiter.release(now: now) {
            applyKeys(applied)
        }
        takeKeyChange()
        advanceTurn()
        applyDueLinkForms()
    }
}
