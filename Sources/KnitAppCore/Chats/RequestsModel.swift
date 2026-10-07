import KnitStore
import KnitWire
public import Observation

/// One message request: a stranger's DM thread, or a group nobody we know has written in.
public struct RequestRow: Sendable, Equatable, Identifiable {
    /// The thread's conversation id: the stranger's node id, or the group's id.
    public var id: String
    /// The stranger's label, or the group's title.
    public var title: String
    /// Whether this is a group.
    public var isGroup: Bool
    /// The newest message, on one line, or `nil` for a group of nothing but status lines.
    public var preview: String?
    /// When it was sent, by its author's clock, or when the group was made.
    public var lastMessageAt: Int64
    /// The stranger's face, or the group's.
    public var face: Face
}

/// The message requests' view model (`MessageRequestsViewModel` in knit-next): Accept, Delete, and Block and Report for a
/// stranger's DM.
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
            let reader = ChatListAssembler.Reader(directory: directory, me: me, filtering: session.filtersContent)
            return session.threads().requests.map { request in
                let preview = request.head.map { head in
                    ChatListAssembler.preview(head, namingSpeaker: request.group != nil, reader: reader)
                }
                let title = request.group.map { GroupNaming.title(of: $0, me: me, directory: directory) }
                return RequestRow(
                    id: request.id,
                    title: title ?? directory.labels.label(for: request.id).text,
                    isGroup: request.group != nil,
                    preview: preview,
                    lastMessageAt: request.lastActivity,
                    face: request.group.map(directory.face(of:)) ?? directory.face(forMember: request.id)
                )
            }
        }
    }

    /// Accepts a request: its thread moves to the chat list and notifies from now on.
    public func accept(_ conversationId: String) async {
        await session.accept(conversationId)
    }

    /// Deletes a request from this iPhone (`MessageRequestsViewModel.delete`, ADR 2026-10.u7cq). It stays a request: the
    /// sender's next message makes a new one.
    public func delete(_ conversationId: String) async {
        await session.deleteChat(conversationId)
    }

    /// Blocks the stranger whose DM this request is (`MessageRequestsViewModel.block`): the request leaves the list,
    /// and nothing they send shows. A group's request has no one to block.
    public func block(_ conversationId: String) async {
        if let peer = NodeId(conversationId) {
            await session.block(peer)
        }
    }

    /// A report of the stranger whose DM `row` is (ADR 2026-10.f6kf), or `nil` for a group's request, which has nobody
    /// to report. A message in the thread is reported from its own menu.
    public func reporting(_ row: RequestRow) -> AbuseReport? {
        guard !row.isGroup, let peer = NodeId(row.id) else {
            return nil
        }
        return AbuseReport(person: peer, name: row.title, place: .request)
    }

    /// Files `report` on this iPhone: the stranger is blocked, and their request goes with the block.
    public func report(_ report: AbuseReport) async {
        await session.report(report)
    }
}
