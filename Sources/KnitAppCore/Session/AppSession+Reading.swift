import KnitMesh
import KnitStore
import KnitWire

// The thread on screen, reading it, and Knit's icon (ADR 2026-10.frmj), apart from the class only to keep its body inside
// the lint's length.
extension AppSession {
    /// A thread came on screen: it stays quiet while it is there, it is read, and what it posted before goes.
    public func show(_ conversationId: String) async {
        visible = conversationId
        if isReading(conversationId) {
            read(conversationId)
        }
        await notifier?.withdraw(threadId: conversationId)
    }

    /// A thread left the screen.
    public func hide(_ conversationId: String) {
        if visible == conversationId {
            visible = nil
        }
    }

    /// The app came to the front or left it. Coming back to a thread still on screen takes back what it posted
    /// meanwhile, as Android's `ON_RESUME` does (`ChatViewModel.onChatForeground`): the user is reading it, and a
    /// notification left behind would make the thread's next one a quiet replacement.
    public func setActive(_ active: Bool) async {
        isActive = active
        if active, let visible {
            read(visible)
            await notifier?.withdraw(threadId: visible)
        }
    }

    /// Whether the user is reading `conversationId`: it is on screen, and Knit is in front. The ids compare by their
    /// bytes, as the store's do (ADR 2026-09.jc2x).
    func isReading(_ conversationId: String) -> Bool {
        guard isActive, let visible else {
            return false
        }
        return ExactKey(visible) == ExactKey(conversationId)
    }

    /// Reads every message of `conversationId`, as Android does whatever the scroll position (`ChatViewModel.kt:719-730`,
    /// ADR 2026-10.frmj). Only a read that changed something moves the revision, so a thread that redraws never reads
    /// itself again in a loop.
    func read(_ conversationId: String) {
        if stores.messages.markRead(in: conversationId) {
            revision += 1
            syncBadge()
        }
    }

    /// Shows on Knit's icon what nobody has read in the DMs and groups, when that changed
    /// (``ChatListAssembler/badgeTotal(_:)``, ADR 2026-10.frmj). The first call always sets it, so a launch clears what an
    /// earlier run left there. Called wherever a count, or the list's set of threads, can move.
    func syncBadge() {
        guard let notifier else {
            return
        }
        let total = ChatListAssembler.badgeTotal(threads())
        guard total != badge else {
            return
        }
        badge = total
        notifier.setBadge(total)
    }
}
