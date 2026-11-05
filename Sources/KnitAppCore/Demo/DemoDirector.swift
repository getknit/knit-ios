public import KnitMesh
import KnitStore
public import KnitWire

/// Plays a demo scene's script once the mesh starts (`-demoScene trailer`, ADR 2026-10.g3k9): people link, posts and
/// reactions arrive, and the user's own posts are heard. knit-next's `DemoDirector.kt` does the same for its trailer.
///
/// Each beat goes through the same path the engine's would: written to the stores, then announced on the mesh's events,
/// so the session screens it, the chat list and the thread redraw, and nothing here draws anything.
///
/// It also plays the user, as knit-next's `DemoComposer` does: a ``DemoCast/Beat/type(_:)`` beat fills the room's
/// composer a key at a time through ``composer``, which the room's ``ChatModel`` follows, then sends it. The field
/// never takes focus, so no keyboard rises over the room, which a UI test typing could not avoid. The script then waits
/// for the post to reach the mesh, so nobody answers it before it is sent.
///
/// Nor does it start before anyone can see it: the mesh starts as the app launches, before its first frame. The first
/// cue waits for ``curtain()``, which the room's ``ChatModel`` calls as it starts following.
///
/// A clip for App Review waits on the user too (ADR 2026-10.yddp): a ``DemoCast/Beat/blocks(_:)`` beat holds the script
/// until the user blocks someone, which ``DemoMesh`` reports, and a blocked person's post then stops where the engine
/// stops one, so the clip shows the block doing what it does with a real peer.
///
/// The sample chats have no script: their director only answers (ADR 2026-11.pydf). What the user sends in any thread
/// shows delivered, and someone there says one of the scene's answers back, each of which says it is a sample.
public final class DemoDirector: Sendable {
    /// What a beat changes: the demo's mesh, which shows who is linked and carries the events.
    internal protocol Stage: Sendable {
        /// Shows `peer` as linked from now on.
        func link(_ peer: NodeId) async
        /// Tells the session that `event` happened.
        func announce(_ event: MeshEvent)
    }

    private let script: [DemoCast.Cue]
    /// What the scene's people say back to the user, in turn.
    private let answers: [String]
    /// Who answers in the room, in turn.
    private let answerers: [NodeId]
    private let stores: MeshStores
    private let me: NodeId
    /// The photo each of the script's posts carries, made before the film starts.
    private let snapshots: [DemoSnapshot: [UInt8]]
    private let now: @Sendable () -> Int64
    private let wait: @Sendable (Int64) async -> Void
    private let ownPosts: AsyncStream<MessageRecord>
    private let posted: AsyncStream<MessageRecord>.Continuation
    private let shown: AsyncStream<Void>
    private let showing: AsyncStream<Void>.Continuation
    private let typing: AsyncStream<ComposerStep>.Continuation
    private let blocks: AsyncStream<NodeId>
    private let blocking: AsyncStream<NodeId>.Continuation

    /// What the user does in the room's composer, for the room's ``ChatModel`` to follow: one follower.
    public let composer: AsyncStream<ComposerStep>

    /// One thing done in the composer.
    public enum ComposerStep: Sendable, Equatable {
        /// The composer now holds these words.
        case draft(String)
        /// Send is tapped.
        case send
    }

    /// The director of `scene` over `stores`, from `me`'s side, or `nil` when the scene has no script and no answers. A post that
    /// carries a photo carries the picture `snap` makes of it, made here rather than as the post lands: a photograph takes
    /// a moment to decode, scale and encode, which the film would show as a spinner. `now` is the wall clock in
    /// milliseconds, and `wait` pauses for a cue's milliseconds.
    @preconcurrency
    public init?(
        scene: DemoScene,
        stores: MeshStores,
        me: NodeId,
        snap: @escaping @Sendable (DemoSnapshot) -> [UInt8]?,
        now: @escaping @Sendable () -> Int64,
        wait: @escaping @Sendable (Int64) async -> Void
    ) {
        let cast = scene.cast
        guard !cast.script.isEmpty || !cast.answers.isEmpty else {
            return nil
        }
        script = cast.script
        answers = cast.answers
        answerers = cast.answerers.compactMap(DemoSeed.nodeId)
        self.stores = stores
        self.me = me
        snapshots = Dictionary(
            uniqueKeysWithValues: Set(
                script.compactMap { cue in
                    if case .post(let line) = cue.beat {
                        return line.photo
                    }
                    return nil
                }
            )
            .compactMap { picture in snap(picture).map { (picture, $0) } }
        )
        self.now = now
        self.wait = wait
        (ownPosts, posted) = AsyncStream<MessageRecord>.makeStream()
        (shown, showing) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (composer, typing) = AsyncStream<ComposerStep>.makeStream()
        (blocks, blocking) = AsyncStream<NodeId>.makeStream()
    }

    deinit {
        posted.finish()
        showing.finish()
        typing.finish()
        blocking.finish()
    }

    /// The room is on screen, where the script can be seen. The first call starts it; later ones change nothing.
    public func curtain() {
        showing.yield()
    }

    /// The user sent `message`, in the room or any other thread. One sent before the script waits for it is kept for it.
    func heard(_ message: MessageRecord) {
        posted.yield(message)
    }

    /// The user blocked `peer`. A block made before the script waits for one is kept for it.
    func blocked(_ peer: NodeId) {
        blocking.yield(peer)
    }

    /// Plays the script on `stage`, then answers what the user sends, until the calling task is cancelled. A scene with no
    /// script answers at once: nothing it does waits for the room to be on screen.
    func play(on stage: some Stage) async {
        var own = ownPosts.makeAsyncIterator()
        if !script.isEmpty, await !perform(&own, on: stage) {
            return
        }
        await answer(&own, on: stage)
    }

    /// Plays the script once the room is on screen, and answers whether it reached its end.
    private func perform(_ own: inout AsyncStream<MessageRecord>.Iterator, on stage: some Stage) async -> Bool {
        var curtain = shown.makeAsyncIterator()
        guard await curtain.next() != nil else {
            return false
        }
        var blocked = blocks.makeAsyncIterator()
        var latest: MessageRecord?
        for cue in script {
            await wait(cue.after.rawValue)
            guard !Task.isCancelled else {
                return false
            }
            switch cue.beat {
            case .link(let slot):
                if let peer = DemoSeed.nodeId(slot) {
                    await stage.link(peer)
                }
            case .post(let line):
                post(line, on: stage)
            case .react(let reaction):
                react(reaction, on: stage)
            case .type(let words):
                for typed in 0..<words.count {
                    typing.yield(.draft(String(words.prefix(typed + 1))))
                    await wait(DemoCast.Wait.key.rawValue)
                }
                await wait(DemoCast.Wait.glance.rawValue)
                typing.yield(.send)
                guard let message = await own.next() else {
                    return false
                }
                latest = message
            case .heard:
                if let latest, stores.messages.markDelivered(latest.id) {
                    stage.announce(.delivered(messageId: latest.id))
                }
            case .blocks(let slot):
                guard let person = DemoSeed.nodeId(slot) else {
                    break
                }
                while !stores.blocks.blockedNodeIds().contains(person) {
                    guard await blocked.next() != nil else {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Answers what the user sends, one message at a time: it shows delivered, then someone there answers. A scene with no
    /// answers has nothing to do here.
    private func answer(_ own: inout AsyncStream<MessageRecord>.Iterator, on stage: some Stage) async {
        guard !answers.isEmpty else {
            return
        }
        var spoken = 0
        while let message = await own.next() {
            await wait(DemoCast.Wait.glance.rawValue)
            guard !Task.isCancelled else {
                return
            }
            if stores.messages.markDelivered(message.id) {
                stage.announce(.delivered(messageId: message.id))
            }
            guard let sender = answerer(of: message, turn: spoken) else {
                continue
            }
            await wait(DemoCast.Wait.reply.rawValue)
            guard !Task.isCancelled else {
                return
            }
            let recipient = message.recipientId == nil ? nil : me
            let line = answers[spoken % answers.count]
            deliver(arriving("answer-\(spoken)", from: sender, to: recipient, in: message.conversationId, body: line), on: stage)
            spoken += 1
        }
    }

    /// Who answers `message` on their turn: someone else in its group, the person it went to, or one of the room's
    /// answerers. A blocked person says nothing, so nobody answers a DM to one.
    private func answerer(of message: MessageRecord, turn: Int) -> NodeId? {
        let blocked = stores.blocks.blockedNodeIds()
        let candidates: [NodeId]
        if let group = stores.groups.group(message.conversationId) {
            candidates = group.roster.filter { !$0.departed }.compactMap { NodeId($0.nodeId) }.filter { $0 != me }
        } else if let recipient = message.recipientId {
            candidates = [recipient]
        } else {
            candidates = answerers
        }
        let open = candidates.filter { !blocked.contains($0) }
        return open.isEmpty ? nil : open[turn % open.count]
    }

    /// Someone else's room post arrives now.
    private func post(_ line: DemoCast.Line, on stage: some Stage) {
        guard let sender = DemoSeed.nodeId(line.from) else {
            return
        }
        let message = arriving(line.id, from: sender, to: nil, in: Conversations.nearby, body: line.body)
        deliver(message, photo: line.photo.flatMap { snapshots[$0] }, on: stage)
    }

    /// Someone else's message as of now, its words waiting for the filter, as the engine stores one.
    private func arriving(_ id: String, from sender: NodeId, to recipient: NodeId?, in thread: String, body: String) -> MessageRecord {
        let at = now()
        return MessageRecord(
            id: id,
            senderId: sender,
            recipientId: recipient,
            conversationId: thread,
            body: body,
            sentAt: at,
            arrivedAt: at,
            moderation: .waiting
        )
    }

    /// Lands `message`, its photo first, as the engine stores an adopted photo. A blocked person's stops at delivery, as at
    /// the engine's gate (`MeshEngine.handleChat`, ADR 2026-10.5wgg): nothing stored, nothing announced.
    private func deliver(_ message: MessageRecord, photo: [UInt8]? = nil, on stage: some Stage) {
        guard !stores.blocks.blockedNodeIds().contains(message.senderId) else {
            return
        }
        var landed = message
        landed.attachment = DemoSeed.photo(photo, in: stores, at: message.sentAt)
        stores.messages.save(landed)
        stage.announce(.received(landed, isRequest: false))
        // Its size, once the thread has it: the session measures a photo when its bytes are announced.
        if let attachment = landed.attachment {
            stage.announce(.attachmentArrived(attachment.hash))
        }
    }

    /// Someone reacts now.
    private func react(_ reaction: DemoCast.Reaction, on stage: some Stage) {
        guard let reactor = reaction.by == .me ? me : DemoSeed.nodeId(reaction.by) else {
            return
        }
        let record = ReactionRecord(messageId: reaction.line, reactor: reactor, emoji: reaction.emoji, updatedAt: now())
        if stores.messages.applyReaction(record) {
            stage.announce(.reacted(record))
        }
    }
}
