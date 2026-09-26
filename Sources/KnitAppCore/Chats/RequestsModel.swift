import KnitStore
import KnitWire
public import Observation

/// One message request: a stranger's DM thread.
public struct RequestRow: Sendable, Equatable, Identifiable {
    /// The thread's conversation id, the stranger's node id.
    public var id: String
    /// The stranger's label.
    public var title: String
    /// Their newest message, on one line.
    public var preview: String
    /// When it was sent, by their clock.
    public var lastMessageAt: Int64
}

/// The message requests' view model (`MessageRequestsViewModel` in knit-next, with Accept only: block and delete
/// wait for moderation).
@preconcurrency
@MainActor
@Observable
public final class RequestsModel {
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<Int, [RequestRow]>()

    /// The requests over `session`.
    public init(session: AppSession) {
        self.session = session
    }

    /// The requests, newest first.
    public var rows: [RequestRow] {
        cache.value(for: session.revision) {
            let directory = session.directory
            let me = session.identity.nodeId
            return session.threads().requests.compactMap { head in
                NodeId(head.conversationId).map { peer in
                    RequestRow(
                        id: head.conversationId,
                        title: directory.label(for: peer).text,
                        preview: ChatListAssembler.preview(head, inRoom: false, directory: directory, me: me),
                        lastMessageAt: head.sentAt
                    )
                }
            }
        }
    }

    /// Accepts a request: its thread moves to the chat list and notifies from now on.
    public func accept(_ conversationId: String) async {
        await session.accept(conversationId)
    }
}
