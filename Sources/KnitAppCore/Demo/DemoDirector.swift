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
public final class DemoDirector: Sendable {
    /// What a beat changes: the demo's mesh, which shows who is linked and carries the events.
    internal protocol Stage: Sendable {
        /// Shows `peer` as linked from now on.
        func link(_ peer: NodeId) async
        /// Tells the session that `event` happened.
        func announce(_ event: MeshEvent)
    }

    private let script: [DemoCast.Cue]
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

    /// The director of `scene` over `stores`, from `me`'s side, or `nil` when the scene has no script. A post that
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
        guard !scene.cast.script.isEmpty else {
            return nil
        }
        script = scene.cast.script
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

    /// The user posted `message` in the room. A post made before the script waits for one is kept for it.
    func heard(_ message: MessageRecord) {
        posted.yield(message)
    }

    /// The user blocked `peer`. A block made before the script waits for one is kept for it.
    func blocked(_ peer: NodeId) {
        blocking.yield(peer)
    }

    /// Plays the script on `stage`, until it ends or the calling task is cancelled.
    func play(on stage: some Stage) async {
        var curtain = shown.makeAsyncIterator()
        guard await curtain.next() != nil else {
            return
        }
        var own = ownPosts.makeAsyncIterator()
        var blocked = blocks.makeAsyncIterator()
        var latest: MessageRecord?
        for cue in script {
            await wait(cue.after.rawValue)
            guard !Task.isCancelled else {
                return
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
                    return
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
                        return
                    }
                }
            }
        }
    }

    /// Someone else's room post arrives now, its photo first, as the engine stores an adopted photo. A blocked person's
    /// stops at delivery, as at the engine's gate (`MeshEngine.handleChat`, ADR 2026-10.5wgg): nothing stored, nothing
    /// announced.
    private func post(_ line: DemoCast.Line, on stage: some Stage) {
        guard let sender = DemoSeed.nodeId(line.from), !stores.blocks.blockedNodeIds().contains(sender) else {
            return
        }
        let at = now()
        let attachment = DemoSeed.photo(line.photo.flatMap { snapshots[$0] }, in: stores, at: at)
        let message = MessageRecord(
            id: line.id,
            senderId: sender,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: line.body,
            sentAt: at,
            arrivedAt: at,
            attachment: attachment,
            moderation: .waiting
        )
        stores.messages.save(message)
        stage.announce(.received(message, isRequest: false))
        // Its size, once the thread has it: the session measures a photo when its bytes are announced.
        if let attachment {
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
