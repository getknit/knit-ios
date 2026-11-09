public import KnitWire

/// Who dials whom, and who is admitted: the dial rule, promotion, the HELLO exchange and the records behind it.
extension LinkManager {
    // MARK: Dialing

    /// Whether we dial a peer advertising `form` with `flags` rather than wait for it to dial us: the order on advertised
    /// forms (``AdvertOrder/iDial(_:_:)``), or ADR 2026-09.6es2's exception, a radio without service data dialing a peer
    /// that reads no GATT payload whatever the order. For a clear peer this is today's `peer < localId || !peerFindsUs`;
    /// a clear phone never dials a blinded advert by the order, so a blinded one is dialed only by the exception.
    func weDial(_ form: AdvertOrder.Form, flags: UInt8) -> Bool {
        AdvertOrder.iDial(mine.current, form) || !peerFindsUs(flags: flags)
    }

    /// Whether a peer advertising `flags` can find us: we advertise service data, or it reads GATT payloads.
    func peerFindsUs(flags: UInt8) -> Bool {
        radio.advertisesServiceData || flags & AdvertPayload.dialsGattPeersFlag != 0
    }

    /// A dial opened: send our HELLO first, then wait for the reply (`LinkHandshake.writeHello`), or, when the advert
    /// dialed carries `FLAG_LINK_SEAL`, our `KEY_SHARE` first (``openSealed(_:now:)``; the `link-seal` contract, §2).
    func connected(_ id: ChannelID, now: Int64) {
        guard let channel = channels[id], channel.stage == .connecting else {
            return
        }
        if case .dialer(let target) = channel.role, target.seals, dialsSealed {
            openSealed(id, now: now)
            return
        }
        writeHello(on: id)
        enterStage(.awaitingHello, on: id, now: now)
    }

    // MARK: Refusals

    /// Refuses every link with `peer`, both ways, until ``permit(_:)``: closes its live link and any dial to it, never
    /// dials it, and closes its HELLO when it dials us. An unresolved tag names no id, so it is dialed until a dial to it
    /// proves `peer`; that dial closes before our PROOF, and the tag at that address is not dialed again while `peer` stays
    /// refused (``refusedTagDial(_:_:_:now:)``): one dial per rotation, address and start, and one more after 90 s
    /// unheard. A rig's tool for forcing a line of nodes that could all hear each other (knit-peer's `deny-link`).
    /// Answers the link that went down.
    public func refuse(_ peer: NodeId) -> [Event] {
        refused.insert(peer)
        let now = clock.monotonicMilliseconds()
        let theirs = channels.filter { entry in
            entry.value.stage == .live(peer) || Self.dials(peer, entry.value) || Self.awaitsProof(of: peer, entry.value)
        }
        return theirs.keys.sorted(by: Self.inOrder).flatMap { retire($0, backingOff: false, now: now) } + reconsiderSeeking(now: now)
    }

    /// Lets `peer` link again, and dials it now if the promotion rules say so.
    public func permit(_ peer: NodeId) -> [Event] {
        refused.remove(peer)
        refusedDials = refusedDials.filter { $0.value != peer }
        let now = clock.monotonicMilliseconds()
        return promote(now: now) + reconsiderSeeking(now: now)
    }

    /// Whether `channel` is a clear dial to `peer`.
    static func dials(_ peer: NodeId, _ channel: Channel) -> Bool {
        if case .dialer(let target) = channel.role {
            return target.expected == peer
        }
        return false
    }

    // MARK: Records

    func receive(_ bytes: [UInt8], on id: ChannelID, now: Int64) -> [Event] {
        guard channels[id] != nil else {
            return []
        }
        channels[id]?.reader.append(bytes)
        channels[id]?.trace.read(bytes.count)
        if let index = liveLinks.firstIndex(where: { $0.channel == id }) {
            // What `RefuseHeld` reads as the held link answering (``heldQuiet(_:now:)``).
            liveLinks[index].lastRead = now
        }
        var events: [Event] = []
        // The role and stage only, never the whole channel: a copy of its reader would copy the buffer each record.
        // Where the next record starts rides along too: a record that throws does not move it.
        while let (role, stage, sealed, at) = channels[id].map({ ($0.role, $0.stage, $0.seal != nil, $0.reader.consumed) }) {
            let record: LinkRecord?
            do {
                record = try channels[id]?.reader.next()
            } catch {
                if sealed || stage == .awaitingKeyShare || opensWithBadKeyShare(error, role: role, stage: stage) {
                    // Bytes that arrived and were wrong where only a KEY_SHARE or a frame may be: a failed seal, which says
                    // where, never what (`link-seal` §4).
                    return events + sealFailed(on: id, why: "record \(error) at byte \(at)", now: now)
                }
                // Android throws on an unknown tag or a bad length and drops the link; so do we, and say what came.
                if let channel = channels[id] {
                    log.log(.warning, "link \(id) sent a bad record: \(error) \(channel.trace.explain(channel.reader))")
                    if case .awaitingProof(let pending) = channel.stage {
                        proofFailed(on: id, for: pending.peer, why: "record")
                    }
                }
                // Dropped, not kept, unlike Android's every close: a stack that mangles multi-packet SDUs (the Moto G,
                // `cb440a6`, `04a927b`; tags 87 and 54 on A4, `af87ba4`) appends corrupt bytes before the framing
                // desyncs, and a prefix holding them would fail its splice and cost a tail as well as the whole file.
                return events + retire(id, backingOff: true, keepingCut: false, now: now) + promote(now: now)
            }
            guard let record else {
                break
            }
            channels[id]?.trace.parsed(record)
            events += sealed ? openFrame(record, on: id, now: now) : handlePlain(record, on: id, role: role, stage: stage, now: now)
        }
        takeTagNext(on: id)
        return events
    }

    /// One record off a plain channel, at `stage`: the record a stage expects, the sealed form's opening `KEY_SHARE` on a
    /// responder, or a stray `KEY_SHARE` or frame, which drops the link as a bad record does (`link-seal` §3).
    func handlePlain(_ record: LinkRecord, on id: ChannelID, role: Role, stage: Stage, now: Int64) -> [Event] {
        switch stage {
        case .connecting:
            return retire(id, backingOff: true, now: now)
        case .awaitingKeyShare:
            return keyShareArrived(record, on: id, now: now)
        case .awaitingHello where record.tag == .keyShare && role == .responder:
            // The dialer opened in the sealed form (`link-seal` §4, step 2).
            return answerKeyShare(record, on: id, now: now)
        case .awaitingHello where record.tag == .keyShare || record.tag == .sealed,
            .awaitingProof where record.tag == .keyShare || record.tag == .sealed:
            return strayRecord(record, on: id, now: now)
        case .awaitingHello:
            return handleHello(record, on: id, role: role, now: now)
        case .awaitingProof(let pending):
            // Re-read for the next record: once the proof verifies, what came behind it in the same read is the live
            // link's, handled after `.up`.
            return handleProof(record, pending, on: id, role: role, now: now)
        case .live(let peer):
            return dispatch(record, from: peer, on: id, now: now)
        }
    }

    func handleHello(_ record: LinkRecord, on id: ChannelID, role: Role, now: Int64) -> [Event] {
        let hello = record.tag == .hello ? Hello(payload: record.payload) : nil
        if case .dialer(let target) = role, target.expected == nil {
            return answeredTag(id, target, hello: hello, payload: record.payload, now: now)
        }
        // Whatever becomes of the link, the node at that address said who it is, which may retire a payload the radio
        // read for another (the payload lifetime's rule 2).
        if let hello, let named = NodeId(hello.nodeId) {
            radio.heardHello(from: named, told: hello.told.flatMap(NodeId.init(bytes:)), announced: aliases.announced(by: named), on: id)
        }
        switch role {
        case .dialer(let target):
            // The link's identity is what the peer says over the socket, and it must be the peer we dialed.
            guard let hello, let expected = target.expected, NodeId(hello.nodeId) == expected else {
                return retire(id, backingOff: true, now: now) + promote(now: now)
            }
            return answered(id, hello: hello, payload: record.payload, peer: expected, now: now)
        case .responder:
            guard let hello else {
                return retire(id, backingOff: false, now: now)
            }
            return admit(id, hello: hello, payload: record.payload, now: now)
        }
    }

    /// A dialer's HELLO, `payload` as it crossed: the responder's rule (`superviseAccepted`, with A1), and the proof's
    /// (the `link-hello-proof` contract, §5 and §7). The proof's checks come first, so a claim R1 refuses is counted even
    /// where today's rules would refuse it too. A dialer that proves itself is answered with our HELLO and PROOF, and
    /// registered only once its own PROOF verifies; a link it would replace stays up until then, and stays if it fails.
    func admit(_ id: ChannelID, hello: Hello, payload: [UInt8], now: Int64) -> [Event] {
        guard let dialer = NodeId(hello.nodeId), dialer != localId, !refused.contains(dialer) else {
            return retire(id, backingOff: false, now: now)
        }
        // Before R1 and today's refusals, so the link counts once (`link-seal` §7). knit-peer's `downgrade` leaves it to
        // the far end's dialer.
        if sealSwitch.refusesPlainAsResponder, refusesPlainLink(id, ours: claimsSeal, theirs: hello) {
            return sealRefused(id, claiming: dialer.string, backingOff: false, now: now)
        }
        if AdvertOrder.refusesLegacy(mine, readsTags: hello.capabilities.contains(.blindAdvert)) {
            // `RefuseLegacy` (`BleAdmissionPolicy.kt:115`), first and with no reply: it dialed a tag it cannot have meant.
            blindWriter.counts.refusedLegacy += 1
            log.log(.info, "link refused \(dialer): it reads no tags")
            return retire(id, backingOff: false, now: now)
        }
        let verdict = judgeClaim(hello, claiming: dialer)
        switch verdict {
        case .failed(let why):
            proofFailed(on: id, for: dialer, why: why)
            return retire(id, backingOff: false, now: now)
        case .refused:
            refuseClaim(dialer)
            return retire(id, backingOff: false, now: now)
        case .proves, .legacy:
            break
        }
        let proves = verdict == .proves
        // Sighted by any attribution: a clear advert, or a tag a key, claim or hint resolved to the dialer.
        let sighting = presence.isPresent(dialer, now: now) ? presence.advert(of: dialer) : nil
        let sighted = sighting != nil
        let held = liveLinks.first { $0.neighbor.nodeId == dialer }
        let claim = Claim(peer: dialer, hello: hello, sighted: sighted)
        if let held, refusesHeld(hello, from: dialer, proves: proves, held: held, now: now) {
            return retire(id, backingOff: false, now: now)
        }
        if let refusal = admissionRefusal(claim, proves: proves, sighting: sighting, held: held, on: id, now: now) {
            log.log(.info, "link refused \(dialer): \(refusal)")
            return retire(id, backingOff: false, now: now)
        }
        guard !proves else {
            let pending = PendingProof(
                claim: claim, dialerHello: payload, responderHello: ourHello(addressing: nil).payload, displacing: held?.channel)
            return answerWithProof(id, pending, now: now)
        }
        var events: [Event] = []
        if let held {
            log.log(.info, "link \(dialer) replaced its stale link \(held.channel) with \(id)")
            // Its cut attachment is kept here, before the new link registers, so an ask crossing the new link resumes.
            events += retire(held.channel, backingOff: false, now: now)
        }
        writeHello(on: id)
        return events + register(id, claim, proven: false, now: now)
    }

    /// Why today's rules refuse a dialer the proof's checks let through, or `nil` to admit it. A dialer that proves itself
    /// is not turned away only because an unproven link claims its id (R3): the cross-dial, "already linked" and "too
    /// young" refusals pass it over, and the proof, once it verifies, displaces that link. Against a proven held link today's
    /// rules stand (R2); an unproven dialer never gets this far against one, since R1 refused it.
    ///
    /// "We dial it" is judged on advertised forms (`BleAdmissionPolicy.outOfOrder`): the dialer's `t` and `a` count only
    /// when its HELLO offers a proof (``AdvertOrder/honours(offersProof:proven:late:)``; this port registers a proving
    /// dialer only after its proof, so the late pass reads the same), so a blinding Android whose real id sorts below ours
    /// is admitted even when a key sights it. While we blind, our forms are the aired snapshot's, and two rows come first:
    /// `RefuseLegacy` in ``admit(_:hello:payload:now:)`` and `RefuseHeld` (``refusesHeld(_:from:proves:held:now:)``).
    ///
    /// The relink window replaces "we dial it" alone, and only for a dialer that proves itself (``relinksOutOfOrder(_:on:now:)``):
    /// every row above it still comes first, and the rows below it still judge the dialer it lets through.
    func admissionRefusal( // swiftlint:disable:this function_parameter_count - the rows' inputs, and the channel the relink names
        _ claim: Claim, proves: Bool, sighting: AdvertPayload?, held: LiveLink?, on id: ChannelID, now: Int64
    ) -> String? {
        let hello = claim.hello
        if proves, let held, !held.proven {
            return nil
        }
        let honoured = AdvertOrder.honours(offersProof: proves, proven: false, late: false)
        let outOfOrder = AdvertOrder.outOfOrder(mine, dialer: claim.peer, told: hello.told, addressed: hello.addressed, honoured: honoured)
        if let sighting, outOfOrder || !peerFindsUs(flags: sighting.flags) {
            guard proves, relinksOutOfOrder(claim.peer, on: id, now: now) else {
                return "we dial it"
            }
        }
        guard let held else {
            return nil
        }
        if sighting != nil {
            return "already linked"
        }
        if now - held.since < configuration.replaceMinHoldMilliseconds {
            return "its link is too young to replace"
        }
        // An unproven dialer never meets a proven held link here: R1 refused it, since that link makes the id proof-capable.
        return nil
    }

    /// `RefuseHeld` (`heldLinkRow`, `BleAdmissionPolicy.kt:170-181`; `noteHeldRefusal`, `BluetoothMeshTransport.kt:4149-4178`):
    /// a dialer whose proven link we hold, and whose honoured `a` names a blinded form of ours, current or previous, missed
    /// our rotation. It is refused with no reply, and our tag goes to it over the held link instead (``TagNextSends``' resend
    /// rules), so its dial and the duplicate cannot close both links. A dialer that may not hear our tag, blocked or departed
    /// (``PresenceKeySource/hearsTagNext``), is refused all the same and sent nothing: its re-dials take this row with no
    /// resend, bounded by its own no-reply backoff, until its held link ends (xp6d, step 5b's B2); let through, an unsighted
    /// one would replace a held link 30 s old at each rotation. Never on a held link whose HELLO carried `CAP_DOORBELL`,
    /// nor on a quiet one (``heldQuiet(_:now:)``), which a dial reaches the replace for. No probe, no keepalive: Android
    /// exempts a doorbell link from its probe, and a probe would wake a suspended peer. Answers whether it refused.
    func refusesHeld(_ hello: Hello, from dialer: NodeId, proves: Bool, held: LiveLink, now: Int64) -> Bool {
        let honoured = AdvertOrder.honours(offersProof: proves, proven: false, late: false)
        let row = AdvertOrder.heldLinkRow(
            mine,
            addressed: hello.addressed,
            honoured: honoured,
            heldProven: held.proven,
            heldQuiet: heldQuiet(held, now: now),
            heldDoorbell: held.neighbor.capabilities.contains(.doorbell)
        )
        guard row else {
            return false
        }
        blindWriter.counts.refusedHeld += 1
        log.log(.info, "link refused \(dialer): it holds a link here, so it hears our tag there")
        let current = mine.current
        if current.blinded {
            sendForm(to: held, .resend, tag: current.advertised, wall: clock.wallMilliseconds())
        }
        return true
    }

    /// Registers the link on `id` to `claim`'s peer, `proven` when its PROOF verified, unless a link to that peer is up.
    func register(_ id: ChannelID, _ claim: Claim, proven: Bool, now: Int64) -> [Event] {
        let peer = claim.peer
        if liveChannel(to: peer) != nil || refused.contains(peer) {
            // Our dial landed while the peer's own link to us was already up: keep the older one. A proof displaced any
            // unproven link before it came here (``proved(_:_:now:)``), so this keeps a link as proven as the new one.
            return retire(id, backingOff: false, now: now)
        }
        let neighbor = Neighbor(nodeId: peer, protocolVersion: claim.hello.version, capabilities: claim.hello.capabilities)
        channels[id]?.stage = .live(peer)
        channels[id]?.deadline = nil
        var link = LiveLink(channel: id, neighbor: neighbor, since: now, sighted: claim.sighted, lastRead: now)
        link.heardServiceData = presence.isPresent(peer, now: now) && presence.advert(of: peer).map(Self.isServiceData) == true
        link.proven = proven
        link.blinds = claim.hello.told.flatMap(NodeId.init(bytes:)).map { $0 != peer } ?? false
        liveLinks.append(link)
        stallWatch.watch(id, written: radio.outboxLevel(on: id).writtenBytes, now: now)
        if case .dialer(let target) = channels[id]?.role {
            blindWriter.linkForms[id] = target.form
            if dialing[target.key] == id {
                dialing[target.key] = nil
            }
            // A proven dial resets every streak its failures were booked under, as Android's accepted dial does.
            for key in target.failureKeys {
                backoffs[key] = nil
            }
        }
        backoffs[.peer(.node(peer))] = nil
        crossings.forget(link: id)
        if channels[id]?.seal != nil {
            sealCounts.linksSealed += 1
        }
        if proven {
            claims.proved(peer)
            relinkWindow.relinked(peer)
            // Here, not where the PROOF verified, so it names only a link that registers, right before its `link up`.
            log.log(.info, "link \(peer) proved itself on \(id)")
        }
        if proven, channels[id]?.role == .responder {
            // A proven dialer's `t` is a hint for this link (`onAnswered`), taken once the link is the one registered under
            // its id (``BlindSightings/current(registered:link:)``) and before this registration's own promotion, which
            // would otherwise find the dialer's own tag held off by nothing and dial the phone that just linked to us.
            aliases.onAnswered(id, told: claim.hello.told.flatMap(NodeId.init(bytes:)), provenId: peer)
        }
        if channels[id]?.role == .responder {
            // The dialer's form as its HELLO tells it, its `t` honoured only on a proven link (`linkForms`).
            let told = AdvertOrder.honours(offersProof: true, proven: proven, late: true) ? claim.hello.told : nil
            blindWriter.linkForms[id] = .fromHello(peer, told: told)
        }
        radio.linkUp(peer, on: id)
        log.log(.info, "link up \(peer) on \(id)")
        if proven {
            announceToNewLink(link)
        }
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
            crossings.arrived(link: id, key: FrameKey.of(wire, envelope), now: now)
            return [.frame(InboundFrame(wire: wire, envelope: envelope, from: peer))]
        case .digest:
            guard let ids = LinkJSON.digestIds(from: record.payload) else {
                return []
            }
            // Metered per peer, so a neighbour looping digests cannot make us serve our custody over and over (ADR 2026-10.f5zs).
            guard digestBudget.admit(link: peer, now: now) else {
                refusedDigests += 1
                log.log(.debug, "link \(id) digest from \(peer) refused: over its budget")
                return []
            }
            return [.digest(ids, from: peer)]
        case .fileHeader:
            return fileHeader(record.payload, from: peer, on: id, now: now)
        case .fileChunk:
            return fileChunk(record.payload, from: peer, on: id, now: now)
        case .fileEnd:
            return fileEnd(from: peer, on: id)
        case .tagNext:
            // Held until the read's records drain, so only the newest of a backlog reaches the resolver (``takeTagNext(on:)``).
            // A record of another length dropped the link in the reader.
            tagNextHeld[id] = NodeId(bytes: record.payload)
            return []
        case .keepalive, .hello, .proof:
            // A stray HELLO or PROOF after the handshake means nothing, and a keepalive's arrival is all it says.
            return []
        case .keyShare, .sealed:
            // Never inside a seal, which fails first, and never on a plain link: the link drops as on an unknown tag.
            return strayRecord(record, on: id, now: now)
        }
    }
}
