import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// One row of the chat list: the room, or an accepted DM.
public struct ChatRow: Sendable, Equatable, Identifiable {
    /// The thread's conversation id.
    public var id: String
    /// The room's name, or the peer's label.
    public var title: String
    /// Whether this is the Nearby room.
    public var isRoom: Bool
    /// The newest message, with its speaker when the title does not already say who: `nil` for an empty thread.
    public var preview: String?
    /// When the newest message was sent, by its author's clock.
    public var lastMessageAt: Int64?
    /// How far the newest message got, when it is ours.
    public var lastStatus: DeliveryStatus?
    /// Whether a DM's peer is linked now.
    public var isLinked: Bool
    /// Whether a DM's peer is verified.
    public var isVerified: Bool
}

/// The chat list, as one value.
public struct ChatListState: Sendable, Equatable {
    /// The rows: the room first, always, then the accepted DMs, newest first.
    public var rows: [ChatRow]
    /// How many message requests wait.
    public var requestCount: Int
    /// Whether to show the first-run card: nothing in the room, no DM and no request yet.
    public var showsGettingStarted: Bool
}

/// Folds the thread table into the chat list's rows (`ChatListAssembler.kt` in knit-next, the MVP's threads). Pure
/// over its inputs, so the rules are tested without a view.
public enum ChatListAssembler {
    /// The list for `threads`, from `me`'s side, with `linked` peers linked now.
    public static func state(threads: ThreadTable, directory: Directory, me: NodeId, linked: Set<NodeId>) -> ChatListState {
        let room = threads.heads.first { $0.conversationId == Conversations.nearby }
        var rows = [row(Conversations.nearby, head: room, directory: directory, me: me, linked: linked)]
        var requests = 0
        for head in threads.heads where head.conversationId != Conversations.nearby {
            // A thread named for something other than a node id is none the MVP shows, a group's say.
            guard NodeId(head.conversationId) != nil else {
                continue
            }
            if threads.isRequest(head.conversationId) {
                requests += 1
            } else {
                rows.append(row(head.conversationId, head: head, directory: directory, me: me, linked: linked))
            }
        }
        return ChatListState(rows: rows, requestCount: requests, showsGettingStarted: rows.count == 1 && room == nil && requests == 0)
    }

    static func row(_ id: String, head: MessageRecord?, directory: Directory, me: NodeId, linked: Set<NodeId>) -> ChatRow {
        let peer = NodeId(id)
        return ChatRow(
            id: id,
            title: peer.map { directory.label(for: $0).text } ?? Copy.ChatList.nearby,
            isRoom: peer == nil,
            preview: head.map { preview($0, inRoom: peer == nil, directory: directory, me: me) },
            lastMessageAt: head?.sentAt,
            lastStatus: head.flatMap { $0.senderId == me ? DeliveryStatus($0) : nil },
            isLinked: peer.map(linked.contains) ?? false,
            isVerified: peer.map(directory.verified.contains) ?? false
        )
    }

    /// "Speaker: body" on one line (`speakerLabel` in knit-next). An incoming DM names nobody, since the row's title
    /// already does; our own messages say "You".
    static func preview(_ message: MessageRecord, inRoom: Bool, directory: Directory, me: NodeId) -> String {
        let body = TextLimits.normalizeSingleLine(message.body)
        if message.senderId == me {
            return Copy.ChatList.preview(speaker: Copy.Common.you, body: body)
        }
        guard inRoom else {
            return body
        }
        return Copy.ChatList.preview(speaker: directory.label(for: message.senderId).text, body: body)
    }
}

/// The chat list's view model.
@preconcurrency
@MainActor
@Observable
public final class ChatListModel {
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<ListKey, ChatListState>()

    private struct ListKey: Equatable {
        var revision: Int
        var linked: Set<NodeId>
    }

    /// The chat list over `session`.
    public init(session: AppSession) {
        self.session = session
    }

    /// The rows, the requests entry and the first-run card, rebuilt only when something changed.
    public var state: ChatListState {
        let linked = Set(session.neighbors.map(\.nodeId))
        let key = ListKey(revision: session.revision, linked: linked)
        return cache.value(for: key) {
            ChatListAssembler.state(threads: session.threads(), directory: session.directory, me: session.identity.nodeId, linked: linked)
        }
    }

    /// The status line.
    public var status: ConnectionStatus {
        ConnectionStatus(radio: session.radioState, isRunning: session.isRunning, linked: session.neighbors.count)
    }

    /// Starts a stopped mesh, from the status line.
    public func start() async {
        await session.start()
    }
}
