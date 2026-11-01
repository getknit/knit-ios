import KnitStore
import KnitWire

/// Delivering a message to us (`InboundPipeline.deliverChat`), in two halves: the row, which writes the message store and
/// nothing else, and the work after it. A DM opened with the ratchet writes its row inside the store unit its open
/// commits in, and runs the rest only once that unit has committed, so a unit that fails delivers and acknowledges
/// nothing (ADR 2026-10.5sk9, phase P5a). A v1 DM, a group message and a room post run both halves at once, as before.
extension MeshEngine {
    /// Stores a delivered message and acknowledges it (`InboundPipeline.deliverChat`). A re-served frame leaves the
    /// row as it was and is not announced again, and the receipt goes out every time. A photo the message carries is
    /// fetched at once unless its bytes are already here, as they are when they were carried for someone else: asked of
    /// its author first, then of `hop`, the neighbour the frame came from, which `nil` leaves unnamed (knit-next ADR
    /// 2026-10.f7gg).
    ///
    /// Someone else's words are stored waiting for the content filter (ADR 2026-10.e4kz). Android classifies them
    /// before the row is written (`InboundPipeline.inboundModeration`); here the app screens them as it hears the
    /// event, off this actor, and nothing shows them until it has. A quote is judged against the original it names, and
    /// its words wait for the filter apart from the body's while it cannot be (knit-next ADR 2026-10.gpa3).
    func deliverChat(_ envelope: RelayEnvelope, _ delivered: DeliveredChat, sender: NodeId, recipient: NodeId?, via hop: NodeId?) {
        announce(storeDelivered(envelope, delivered, sender: sender, recipient: recipient), envelope, sender: sender, via: hop)
    }

    /// The row half of ``deliverChat(_:_:sender:recipient:via:)``: the message stored unless its id is held, and what the
    /// work after it needs. It reads and writes the message store and nothing else, so it may run inside a store unit:
    /// nothing here sends, announces, or reads or writes a blob.
    func storeDelivered(_ envelope: RelayEnvelope, _ delivered: DeliveredChat, sender: NodeId, recipient: NodeId?) -> StoredDelivery {
        // A group's thread is the group; a DM's and the room's follow from who sent it to whom.
        let conversation = envelope.group?.id ?? Conversations.id(sender: sender, recipient: recipient, me: nodeId)
        let isNew = !stores.messages.contains(envelope.id)
        // Our own limit bounds what we send, not what a peer floods.
        let body = TextLimits.truncated(delivered.body, toUTF16: TextLimits.message)
        var record = MessageRecord(
            id: envelope.id,
            senderId: sender,
            recipientId: recipient,
            conversationId: conversation,
            body: body,
            sentAt: clampFuture(envelope.sentAt),
            arrivedAt: sender == nodeId ? nil : clock.wallMilliseconds(),
            attachment: delivered.attachment,
            moderation: sender == nodeId || TextLimits.isBlank(body) ? .clear : .waiting,
            replyTo: delivered.replyTo,
            // Only the mentions the kept body still holds: that bounds a peer's list, where Android keeps any
            // (`InboundPipeline.kt:2660`, ADR 2026-10.nbhj).
            mentions: MessageMention.carried(delivered.mentions, in: body)
        )
        if isNew, sender != nodeId {
            record = quoteOnArrival(record)
        }
        stores.messages.insertIfAbsent(record)
        return StoredDelivery(record: record, isNew: isNew)
    }

    /// The half of ``deliverChat(_:_:sender:recipient:via:)`` after the row: a new message's quote, and the quotes of the
    /// replies waiting on it, are settled (``settleQuotes(after:)``), the sender's typing cue ends, a new message
    /// is announced as stored, what it carries is fetched or held, and the frame is acknowledged. For a ratchet DM it runs only once
    /// the unit that stored the row has committed, so the acceptance it reads is never read inside that unit.
    func announce(_ stored: StoredDelivery, _ envelope: RelayEnvelope, sender: NodeId, via hop: NodeId?) {
        var stored = stored
        if stored.isNew, let settled = settleQuotes(after: stored.record) {
            stored.record = settled
        }
        let conversation = stored.record.conversationId
        // Every delivery ends the sender's cue in the thread, a re-delivery too (`InboundPipeline.kt:2728`), and before
        // the message is announced, so no screen shows both.
        clearTyping(sender, in: conversation)
        if stored.isNew, sender != nodeId {
            events.append(.received(stored.record, isRequest: !mayFetch(for: conversation)))
        }
        if let attachment = stored.record.attachment {
            receiveAttachment(attachment, of: stored.record, author: sender, via: hop)
        }
        acknowledge(envelope, sender: sender)
    }

    /// Fetches what a delivered message carries, unless its bytes are here already, when a sealed one learns its
    /// plaintext's name: the one place a held sealed blob does (ADR 2026-10.f3mv), so it runs whatever the thread. Nothing
    /// more is done for a message request, or for a stranger's room photo outside the room's bound (``fetchRefusal(_:)``,
    /// knit-ios #21): its photo is fetched from its author once the thread is accepted. A key-less picture, a room post's or
    /// one forwarded under its public name, is held from our own sealed copy instead when its author was party to the
    /// conversation that copy came through (ADR 2026-10.f3mv); this is the one door to that copy. Otherwise it is a want of
    /// our own, pulled through until `record`'s deadline (``deliveredReach(_:)``).
    private func receiveAttachment(_ attachment: MessageAttachment, of record: MessageRecord, author: NodeId, via hop: NodeId?) {
        let hash = attachment.hash
        if stores.blobs.contains(hash) {
            notePlainHash(hash)
            return
        }
        if let refusal = fetchRefusal(record) {
            log.log(.debug, "mesh blob \(LinkManager.shown(hash.string)) from \(author) not fetched (\(refusal))")
            return
        }
        if attachment.key == nil, !transport.arrivingFileKeys.contains(hash), copyFromOwnStore(hash, author: author) {
            events.append(.attachmentArrived(hash))
            return
        }
        wantBlob(hash, author: author, via: hop, asker: nil, reach: deliveredReach(record))
    }

    /// The budget and deadline a delivered `record`'s photo is wanted with (`deliveredFetch`'s `until`, knit-next ADR
    /// 2026-10.2drc): the whole budget, and a deadline the delivery knows, `nil` included. A row that is no DM's (a
    /// group's, a room's) has none, and lifts an old DM's at once, with no read. A DM's folds every row naming the hash
    /// in a thread we fetch for (`PullThroughGate`), which this one is among: the row is stored before this runs, so a
    /// message request naming the same hash cannot set it. It is folded in by its id too, so a read that failed, which
    /// answers no rows, still leaves this DM's own window, never none.
    func deliveredReach(_ record: MessageRecord) -> BlobExchange.Reach {
        guard record.recipientId != nil, let hash = record.attachment?.hash else {
            return .own(until: nil, rederived: true)
        }
        let named = stores.messages.attachmentRows(among: [hash])[hash] ?? []
        let fetched = conversationsFetched(among: Set(named.map(\.conversationId)), Acquaintances(reading: self))
        var rows = named.filter { fetched.contains($0.conversationId) }
        if !rows.contains(where: { ExactKey($0.id) == ExactKey(record.id) }) {
            rows.append(
                AttachmentRow(
                    id: record.id, senderId: record.senderId, sentAt: record.sentAt, isDM: true, conversationId: record.conversationId))
        }
        return .own(until: PullThroughGate.until(rows), rederived: true)
    }

    // MARK: What a thread's photos cost

    /// Whether we may fetch photos for `conversation` (knit-ios #21): whether it is accepted rather than a message
    /// request (``Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``), with a group's blocked senders
    /// left out of the posters that accept it, as the screens leave them out (`ThreadTable`). The `.received` event's
    /// request flag reads it too, so the screens and the fetch agree.
    func mayFetch(for conversation: String) -> Bool {
        !conversationsFetched(among: [conversation], Acquaintances(reading: self)).isEmpty
    }

    /// Why `record`'s photo is not fetched, in the words a log line takes, or `nil` when it is: its thread may be fetched
    /// for (``mayFetch(for:)``), and a room post's is inside the bound on strangers' photos (``StrangerRoomPhotos``), read
    /// over every row naming a photo, this one among them. A stranger's room photo that is inside pushes the oldest out,
    /// so the wants the bound now leaves out are withdrawn first (``withdrawLeftOutRoomPhotos()``): live posts
    /// arrive oldest first, and each is its sender's newest when it lands.
    private func fetchRefusal(_ record: MessageRecord) -> String? {
        let known = Acquaintances(reading: self)
        guard !conversationsFetched(among: [record.conversationId], known).isEmpty else {
            return "message request"
        }
        guard record.conversationId == Conversations.nearby, !known.knows(record.senderId) else {
            return nil
        }
        let all = stores.messages.allAttachmentRows()
        guard !StrangerRoomPhotos.leftOut(Array(all.values.joined()), isKnown: known.knows).contains(ExactKey(record.id)) else {
            return "past the room's bound"
        }
        withdrawLeftOutRoomPhotos()
        return nil
    }

    /// Withdraws each want of our own for a room photo that a row names but no row we fetch for does: one the bound on
    /// strangers' photos now leaves out (knit-ios #21). It is forgotten and every holder still asked is sent a `blobcancel`
    /// (knit-next ADR 2026-10.nsr7), as a want the full set evicts is. Without it a want made while its photo was a
    /// stranger's newest would stand its 30 minutes, be stepped at every re-offer and land, so a flood posted oldest first
    /// would be fetched whole and crowd our other wants out of the set.
    ///
    /// An echo is an asker's, and a peer's advertised photo is wanted as a photo, so neither is touched, but a blocked
    /// person's, which is no longer wanted as theirs (``withdrawBlockedPhotos()``, knit-ios #37). Nor is a want
    /// whose bytes are already arriving: the copy is on the link already, and once landed, nothing names it and the
    /// sweep removes it. The rows and who the user knows are read in one store unit, and nothing is withdrawn unless it
    /// commits: outside one a failed read knows nobody, and every contact's room photo would read as a stranger's.
    func withdrawLeftOutRoomPhotos() {
        let unit = stores.transactor.atomically { () -> [BlobHash]? in
            let all = stores.messages.allAttachmentRows()
            let taken = rowsTaken(all, fetching: true)
            let blocked = stores.blocks.blockedNodeIds()
            let advertised = Set(stores.peers.allPeers().filter { !blocked.contains($0.nodeId) }.compactMap(\.advertisedAvatarHash))
            return all.filter { hash, rows in
                taken[hash] == nil && rows.contains { $0.conversationId == Conversations.nearby }
                    && blobExchange.wants[hash]?.origin == .own && !advertised.contains(hash)
            }.keys.sorted()
        }
        guard case .committed(let room) = unit, !room.isEmpty else {
            return
        }
        let arriving = transport.arrivingFileKeys
        for hash in room where !arriving.contains(hash) {
            log.log(.debug, "mesh blob \(LinkManager.shown(hash.string)) want withdrawn (past the room's bound)")
            withdrawAsks(hash, from: blobExchange.obtained(hash, from: nil))
        }
        syncAcceptedFiles()
    }

    /// The rows of `rows` whose photo we fetch or keep: those in a thread ``conversationsFetched(among:_:)`` (`fetching`)
    /// or ``conversationsNamed(among:_:)`` takes, less a stranger's room photo outside the room's bound. `rows` must be
    /// every row naming a blob, which the bound ranks the room's over. A hash none is left for has no entry.
    func rowsTaken(_ rows: [BlobHash: [AttachmentRow]], fetching: Bool) -> [BlobHash: [AttachmentRow]] {
        let known = Acquaintances(reading: self)
        let all = Array(rows.values.joined())
        let conversations = Set(all.map(\.conversationId))
        let taken = fetching ? conversationsFetched(among: conversations, known) : conversationsNamed(among: conversations, known)
        let leftOut = StrangerRoomPhotos.leftOut(all, isKnown: known.knows)
        return rows.compactMapValues { named in
            let kept = named.filter { taken.contains($0.conversationId) && !leftOut.contains(ExactKey($0.id)) }
            return kept.isEmpty ? nil : kept
        }
    }

    /// The threads of `conversations` whose photos we fetch: accepted, a group's blocked senders left out of its posters.
    func conversationsFetched(among conversations: Set<String>, _ known: Acquaintances) -> Set<String> {
        accepted(among: conversations, known, blocked: stores.blocks.blockedNodeIds())
    }

    /// The threads of `conversations` whose photos we keep: accepted, blocked senders counted, so a block never sweeps a
    /// thread's photos (ADR 2026-10.5wgg): a blocked person's posts were shown before, and an unblock shows them again.
    func conversationsNamed(among conversations: Set<String>, _ known: Acquaintances) -> Set<String> {
        accepted(among: conversations, known, blocked: [])
    }

    /// The threads of `conversations` that are accepted, a group's posters in `blocked` left out.
    private func accepted(among conversations: Set<String>, _ known: Acquaintances, blocked: Set<NodeId>) -> Set<String> {
        conversations.filter { conversation in
            Conversations.isAccepted(
                conversation,
                accepted: known.accepted,
                verified: known.verified,
                authored: known.authored,
                groupSenders: Conversations.isGroup(conversation) ? stores.messages.senders(in: conversation).subtracting(blocked) : []
            )
        }
    }
}

/// Who the user knows, read from the stores once for a pass, and anew for every pass, never cached: each read is the
/// caller's, so one inside a store unit fails the unit on an error where outside one it would read as nobody known.
internal struct Acquaintances {
    /// This node.
    let me: NodeId
    /// The threads the user accepted.
    let accepted: Set<String>
    /// The peers the user verified.
    let verified: Set<NodeId>
    /// The threads the user wrote in.
    let authored: Set<String>

    /// Reads them from `engine`'s stores.
    init(reading engine: MeshEngine) {
        me = engine.nodeId
        accepted = engine.stores.conversations.acceptedConversations()
        verified = engine.stores.peers.verifiedNodeIds()
        authored = engine.stores.messages.conversations(authoredBy: engine.nodeId)
    }

    /// Whether `sender` is someone the user knows (Android's `knownSenders`, `MeshManager.kt:3010` at knit-next
    /// `4408e0fca`): us, a peer whose DM thread is accepted or written in, or a verified peer.
    func knows(_ sender: NodeId) -> Bool {
        sender == me || accepted.contains(sender.string) || verified.contains(sender) || authored.contains(sender.string)
    }
}

/// A message delivered to us and stored (``MeshEngine/storeDelivered(_:_:sender:recipient:)``): its row, and whether the
/// row is new, for the work after the unit that stored it commits.
internal struct StoredDelivery {
    /// The row as delivered, and as stored once its quote is settled.
    var record: MessageRecord
    /// Whether no row held its id before: only a new message is announced.
    let isNew: Bool
}
