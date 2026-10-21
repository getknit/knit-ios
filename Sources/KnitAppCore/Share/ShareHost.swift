public import Foundation
import Observation

/// The app's side of the share sheet (ADR 2026-10.z7a8): it keeps the chats the sheet offers up to date in the App
/// Group, drains what the sheet left whenever the session moves, which every background wake does, and says by
/// notification when a share was held back for its chat's composer.
@preconcurrency
@MainActor
public final class ShareHost {
    /// The drain it runs.
    public let drain: ShareDrain
    private let session: AppSession
    private let onboarded: @MainActor () -> Bool
    /// What a pass waits after it, so a burst of moves in a background wake runs a pass a second, not one a frame.
    private let pause: @Sendable () async -> Void
    /// The passes under way, from the first move of a burst until a pause passes with no move.
    private var queued: Task<Void, Never>?
    /// Whether the session moved since the running pass began.
    private var movedAgain = false

    /// The host of `inbox` for `session`, making pictures ready with `codec` and checking them with `screening`, reading
    /// the wall clock in milliseconds from `now`, offering chats only once `onboarded` says so, and waiting `pause` after
    /// each pass.
    @preconcurrency
    public init(
        inbox: ShareInbox,
        session: AppSession,
        codec: (any ImageCodec)?,
        screening: PhotoScreening?,
        now: @escaping @Sendable () -> Int64,
        onboarded: @escaping @MainActor () -> Bool,
        pause: @escaping @Sendable () async -> Void
    ) {
        self.session = session
        self.onboarded = onboarded
        self.pause = pause
        let notifier = session.notifier
        drain = ShareDrain(inbox: inbox, session: session, codec: codec, screening: screening, now: now) { thread, refusal in
            let title = ChatModel(conversationId: thread, session: session).state.title
            let notification = LocalNotification(
                id: Self.heldId(thread), threadId: thread, conversationId: thread, title: title, body: Copy.Share.held(refusal))
            Task { await notifier?.post(notification) }
        }
    }

    /// The id of the notification that says a share for `conversationId` is waiting in its composer. Its thread is the
    /// chat's, so opening the chat withdraws it.
    public static func heldId(_ conversationId: String) -> String {
        "share:" + conversationId
    }

    /// Lists the chats, drains what waits, and from then on does both each time the session moves.
    public func start() {
        sessionMoved()
        watch()
    }

    /// Sends what waits, and answers a contact link waiting for Add contact when Knit is `atFront`.
    public func drain(atFront: Bool) async -> String? {
        await drain.drain(atFront: atFront)
    }

    /// The oldest share held for `conversationId`'s composer, taken.
    public func takeHeld(for conversationId: String) -> (manifest: ShareManifest, picture: Data?)? {
        drain.takeHeld(for: conversationId)
    }

    /// The session moved, or the sheet said it left a share: list the chats again and drain what waits. A move during a
    /// pass, or during the pause after it, runs one more pass once the pause is over, so a background wake's burst of
    /// frames pays for a pass a second at most. A pass's own send moves the session too, which costs one empty pass.
    public func sessionMoved() {
        guard queued == nil else {
            movedAgain = true
            return
        }
        queued = Task {
            repeat {
                movedAgain = false
                await Task.yield()
                publishChats()
                if drain.inbox.pendingCount() > 0 {
                    await drain.drain(atFront: false)
                }
                await pause()
            } while movedAgain
            queued = nil
        }
    }

    /// Writes the chats the sheet offers, or none before onboarding is done, when there is no one to send to.
    func publishChats() {
        guard onboarded() else {
            ChatSnapshot.remove(from: drain.inbox)
            return
        }
        let list = ChatListAssembler.state(
            threads: session.threads(),
            directory: session.directory,
            me: session.identity.nodeId,
            linked: [],
            filtering: session.filtersContent
        )
        ChatSnapshot(list).write(to: drain.inbox)
    }

    /// Calls ``sessionMoved()`` at the session's next move, and again at each one after it.
    private func watch() {
        withObservationTracking {
            _ = session.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionMoved()
                self?.watch()
            }
        }
    }
}
