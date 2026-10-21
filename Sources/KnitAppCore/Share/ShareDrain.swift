public import Foundation
import KnitStore
import KnitWire

/// Sends what the share sheet left in the inbox (ADR 2026-10.z7a8), through the same rules a send from the composer
/// meets: a headless ``ChatModel`` for the thread, seeded with the words, takes the picture through
/// ``ChatModel/choosePhoto(_:)`` and sends with ``ChatModel/send()``. So the room screens the picture and the words
/// (ADR 2026-10.spcy), a picture already held goes as its blob (ADR 2026-10.f3mv), and a closed thread takes nothing. A
/// share a check refused is held for its thread's composer.
///
/// Never call ``AppSession/send(_:photo:replyTo:mentions:in:)`` from here: it skips the photo's screening, which runs in
/// `choosePhoto`, and every check the thread makes.
@preconcurrency
@MainActor
public final class ShareDrain {
    /// What became of one share.
    enum Outcome: Equatable {
        case sent
        case held(ShareManifest.Refusal)
        /// Nothing to send, or no thread it could be for.
        case dropped
    }

    /// The inbox it drains.
    public let inbox: ShareInbox
    private let session: AppSession
    private let codec: (any ImageCodec)?
    private let screening: PhotoScreening?
    private let now: @Sendable () -> Int64
    /// Called with a thread's id when a share for it is held, so a notification can say so.
    private let held: @MainActor (String) -> Void
    private var draining = false

    /// Drains `inbox` into `session`'s threads, making pictures ready with `codec` and checking them with `screening`,
    /// reading the wall clock in milliseconds from `now`, and calling `held` with the thread of each share held back.
    @preconcurrency
    public init(
        inbox: ShareInbox, session: AppSession, codec: (any ImageCodec)?, screening: PhotoScreening?,
        now: @escaping @Sendable () -> Int64, held: @escaping @MainActor (String) -> Void
    ) {
        self.inbox = inbox
        self.session = session
        self.codec = codec
        self.screening = screening
        self.now = now
        self.held = held
    }

    /// Sends every waiting share, oldest first, and answers the first contact link waiting when Knit is `atFront`, for
    /// Add contact. A contact link waits for the front, where Add contact can open. A drain under way makes a second
    /// one return at once.
    @discardableResult
    public func drain(atFront: Bool) async -> String? {
        guard !draining else {
            return nil
        }
        draining = true
        defer { draining = false }
        inbox.sweep(now: now())
        var link: String?
        for item in inbox.pending() {
            switch item.manifest.kind {
            case .contactLink:
                guard atFront, link == nil, let claimed = inbox.claim(item) else {
                    continue
                }
                inbox.finish(claimed)
                if AddContactModel.isContactLink(claimed.manifest.text) {
                    link = claimed.manifest.text
                }
            case .message:
                guard let claimed = inbox.claim(item) else {
                    continue
                }
                switch await send(claimed) {
                case .sent, .dropped:
                    inbox.finish(claimed)
                case .held(let refusal):
                    inbox.hold(claimed, because: refusal)
                    held(claimed.manifest.conversationId)
                }
            }
        }
        return link
    }

    /// The shares held for thread `conversationId`, taken out of the inbox for its composer, oldest first.
    public func takeHeld(for conversationId: String) -> [(manifest: ShareManifest, picture: Data?)] {
        inbox.held(in: conversationId).map { share in
            let picture = inbox.picture(of: share)
            inbox.release(share)
            return (share.manifest, picture)
        }
    }

    /// Sends one claimed share as the composer would.
    func send(_ claimed: ShareInbox.Item) async -> Outcome {
        let id = claimed.manifest.conversationId
        guard id == Conversations.nearby || Conversations.isGroup(id) || NodeId(id).map({ $0 != session.identity.nodeId }) == true else {
            return .dropped
        }
        let model = ChatModel(conversationId: id, session: session, codec: codec, screening: screening, draft: claimed.manifest.text)
        let thread = model.state
        // A request is closed too: a send would accept it (`Conversations.isAccepted`'s `authored`).
        guard thread.exists, !thread.isRequest, !thread.isBlocked, !thread.nobodyElse else {
            return .held(.closed)
        }
        if claimed.manifest.hasPicture {
            await model.choosePhoto(inbox.picture(of: claimed))
            if model.photoRefused {
                return .held(.explicitPhoto)
            }
            switch model.photoFailure {
            case .tooLarge:
                return .held(.photoTooLarge)
            case .unreadable:
                return .held(.unreadablePhoto)
            case nil:
                break
            }
        }
        guard model.canSend else {
            return .dropped
        }
        if await model.send() {
            return .sent
        }
        return .held(model.wordsRefused ? .words : .closed)
    }
}
