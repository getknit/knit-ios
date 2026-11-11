import KnitWire

/// What the blinded advert's writer tells its links (ADR 2026-11.prsp, "The link"): `TAG_NEXT` sends on ``TagNextSends``'
/// rules, the form each link's peer airs as its accepted announcements make it (``LinkFormNotes``), and how quiet a held
/// link is, which `RefuseHeld` reads.
extension LinkManager {
    /// How long a held link may go with no byte read before `RefuseHeld` passes it over (`LinkSilence.QUIET_MS`,
    /// `LinkSilence.kt:396` at `cad69c77b`), counted only while Knit runs (``LiveLink/lastRead``).
    static let heldQuietMilliseconds: Int64 = 90_000

    /// Writes our advertised `tag` to the link on `id` as a `TAG_NEXT` (tag 9, exactly 16 bytes; ADR 2026-11.prsp). A link
    /// record, never a frame, so it rings no doorbell (ADR 2026-09.khjj): a rotation never wakes a suspended iPhone. It waits
    /// behind whatever the link holds, first in first out, as Android's `FramedLink.sendTagNext` queues it, so a back-fill can
    /// carry it past the edge; how often it waited is counted. ``sendForm(to:_:tag:wall:)`` decides whether it goes.
    func sendTagNext(_ tag: NodeId, on id: ChannelID) {
        if radio.outboxLevel(on: id).queuedBytes > 0 {
            blindWriter.counts.tagNextBehindQueue += 1
        }
        if let record = LinkRecord(.tagNext, payload: tag.bytes).encoded {
            write(record, on: id)
        }
    }

    // MARK: TAG_NEXT

    /// One `TAG_NEXT` of `kind` naming `tag` to `link`, if ``TagNextSends`` lets it go: proven, tag-aware, its peer neither
    /// blocked nor departed now, a key held, the receiver's limit kept. Counted either way; the line names the recipient,
    /// never the tag.
    ///
    /// With a key held, a random tag on the air (a mark that would not write, a slot out of restarts) is sent too, as Android
    /// sends it (`BluetoothMeshTransport.kt:1626`): a linked peer that reads it attributes it to us and does not dial it. With
    /// no key held nothing is sent, since the departures an unsettled pass keeps can miss a fresh leaver.
    func sendForm(to link: LiveLink, _ kind: TagNextSends<ChannelID>.Kind, tag: NodeId, wall: Int64) {
        let peer = link.neighbor.nodeId
        let hears = blindWriter.source.map { $0.hearsTagNext(peer) } == true
        let eligible = TagNextSends<ChannelID>.eligible(
            proven: link.proven, readsTags: link.neighbor.capabilities.contains(.blindAdvert), hears: hears)
        let outcome = blindWriter.sends.decide(
            link.channel,
            kind: kind,
            eligible: eligible,
            hasKey: blindWriter.ownKey != nil,
            wall: wall,
            announceDueAt: blindWriter.rotation.announceDueAt,
            announcing: blindWriter.announcedTag != nil
        )
        blindWriter.counts.sent(kind, outcome)
        guard outcome == .sent else {
            return
        }
        sendTagNext(tag, on: link.channel)
        log.log(.info, "link tag next to \(peer) on \(link.channel)")
    }

    /// A link came up: the announcement standing goes to it too, so it holds the coming tag before it airs.
    func announceToNewLink(_ link: LiveLink) {
        guard let tag = blindWriter.announcedTag else {
            return
        }
        sendForm(to: link, .announce, tag: tag, wall: clock.wallMilliseconds())
    }

    // MARK: The link's form

    /// A `TAG_NEXT` the resolver answered `outcome` to, on `id`: accepted (held pending, or a key's own answer), it becomes
    /// the link's form at its edge, or at once when it names the form on the air now (`noteLinkForm`).
    func noteLinkForm(_ id: ChannelID, tag: NodeId, outcome: AdvertAliases<ChannelID>.ClaimOutcome) {
        guard LinkFormNotes<ChannelID>.notes(outcome) else {
            return
        }
        if blindWriter.notes.offer(id, tag: tag, wall: clock.wallMilliseconds()) == nil {
            blindWriter.linkForms[id] = AdvertOrder.Form(advertised: tag, blinded: true)
        }
    }

    /// The link forms whose edge has come: each applies if its note is still that link's and that tag, the link is still
    /// the one registered under its peer's id, and the tag still stands for it.
    func applyDueLinkForms() {
        let wall = clock.wallMilliseconds()
        for (id, tag) in blindWriter.notes.due(wall: wall) {
            guard blindWriter.notes.take(id, tag: tag, wall: wall), let link = liveLinks.first(where: { $0.channel == id }),
                aliases.stillAnnounced(id, provenId: link.neighbor.nodeId, tag: tag)
            else {
                continue
            }
            blindWriter.linkForms[id] = AdvertOrder.Form(advertised: tag, blinded: true)
            blindWriter.counts.linkFormsApplied += 1
        }
    }

    // MARK: Quiet links

    /// Whether `link` has gone ``heldQuietMilliseconds`` with no byte read, counting only time Knit ran: each read stamps
    /// it, and so do the front, a ring and a late write-stall check, after which the time iOS held Knit suspended is not
    /// counted.
    func heldQuiet(_ link: LiveLink, now: Int64) -> Bool {
        now - link.lastRead >= Self.heldQuietMilliseconds
    }

    /// Knit runs again after a time iOS may have held it suspended: every link's quiet starts from now.
    func restampReads(now: Int64) {
        for index in liveLinks.indices {
            liveLinks[index].lastRead = max(liveLinks[index].lastRead, now)
        }
    }
}
