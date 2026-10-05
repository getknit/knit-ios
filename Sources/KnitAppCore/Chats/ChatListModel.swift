import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// One row of the chat list: the room, an accepted DM, or a group we are in.
public struct ChatRow: Sendable, Equatable, Identifiable {
    /// The thread's conversation id.
    public var id: String
    /// The room's name, the peer's label, or the group's title.
    public var title: String
    /// Whether this is the Nearby room.
    public var isRoom: Bool
    /// Whether this is a group.
    public var isGroup = false
    /// The newest message, with its speaker when the title does not already say who: `nil` for an empty thread.
    public var preview: String?
    /// When the newest message was sent, by its author's clock, or when an empty group was made.
    public var lastMessageAt: Int64?
    /// How far the newest message got, when it is ours.
    public var lastStatus: DeliveryStatus?
    /// Whether a DM's peer is linked now.
    public var isLinked: Bool
    /// Whether a DM's peer is verified.
    public var isVerified: Bool
    /// The thread's face: the room's, the peer's, or the group's.
    public var face = Face.room
}

/// The chat list, as one value.
public struct ChatListState: Sendable, Equatable {
    /// The rows: the room first, always, then the accepted DMs and groups, newest first.
    public var rows: [ChatRow]
    /// How many message requests wait.
    public var requestCount: Int
    /// Whether to show the first-run card: nothing in the room, no DM and no request yet.
    public var showsGettingStarted: Bool
}

/// Folds the thread table into the chat list's rows (`ChatListAssembler.kt` in knit-next). Pure over its inputs, so
/// the rules are tested without a view.
public enum ChatListAssembler {
    /// What every row reads besides its thread: who is who, whose side the list is from, and whether the content filter
    /// hides flagged words in a line (ADR 2026-10.e4kz).
    struct Reader {
        let directory: Directory
        let me: NodeId
        let filtering: Bool
    }

    /// The list for `threads`, from `me`'s side, with `linked` peers linked now, its lines hiding what the content filter
    /// hides while `filtering`.
    public static func state(
        threads: ThreadTable, directory: Directory, me: NodeId, linked: Set<NodeId>, filtering: Bool
    ) -> ChatListState {
        let reader = Reader(directory: directory, me: me, filtering: filtering)
        let room = threads.heads.first { $0.conversationId == Conversations.nearby }
        var rows: [ChatRow] = []
        for head in threads.heads where NodeId(head.conversationId) != nil && !threads.isRequest(head.conversationId) {
            rows.append(row(head.conversationId, head: head, linked: linked, reader: reader))
        }
        // Group rows come from the groups we hold rather than from messages, so a group shows before its first one, but
        // not once its chat was deleted, until its next row (ADR 2026-10.u7cq).
        for group in threads.listedGroups where !threads.isRequest(group.id) {
            let head = threads.heads.first { ExactKey($0.conversationId) == ExactKey(group.id) }
            rows.append(row(group, head: head, reader: reader))
        }
        // Newest first, a tie keeping the order above. A thread named for nothing this build knows is left out.
        let ordered = rows.enumerated()
            .sorted { ($1.element.lastMessageAt ?? 0, $0.offset) < ($0.element.lastMessageAt ?? 0, $1.offset) }
            .map(\.element)
        let requests = threads.requests.count
        let all = [row(Conversations.nearby, head: room, linked: linked, reader: reader)] + ordered
        return ChatListState(rows: all, requestCount: requests, showsGettingStarted: all.count == 1 && room == nil && requests == 0)
    }

    /// A group's row: its title, and its newest message with its speaker.
    static func row(_ group: GroupRecord, head: MessageRecord?, reader: Reader) -> ChatRow {
        ChatRow(
            id: group.id,
            title: GroupNaming.title(of: group, me: reader.me, directory: reader.directory),
            isRoom: false,
            isGroup: true,
            preview: head.map { preview($0, namingSpeaker: true, reader: reader) },
            lastMessageAt: head?.sentAt ?? group.createdAt,
            lastStatus: head.flatMap { $0.senderId == reader.me ? DeliveryStatus($0) : nil },
            isLinked: false,
            isVerified: false,
            face: reader.directory.face(of: group)
        )
    }

    static func row(_ id: String, head: MessageRecord?, linked: Set<NodeId>, reader: Reader) -> ChatRow {
        let peer = NodeId(id)
        let directory = reader.directory
        return ChatRow(
            id: id,
            title: peer.map { directory.label(for: $0).text } ?? Copy.ChatList.nearby,
            isRoom: peer == nil,
            preview: head.map { preview($0, namingSpeaker: peer == nil, reader: reader) },
            lastMessageAt: head?.sentAt,
            lastStatus: head.flatMap { $0.senderId == reader.me ? DeliveryStatus($0) : nil },
            isLinked: peer.map(linked.contains) ?? false,
            isVerified: peer.map(directory.verified.contains) ?? false,
            face: peer.map(directory.face(for:)) ?? .room
        )
    }

    /// "Speaker: body" on one line (`speakerLabel` in knit-next). An incoming DM names nobody, since the row's title
    /// already does; the room and a group name the speaker, and our own messages say "You". A message with no words
    /// says what it carries (`messagePreview`), and words the content filter hides say only that.
    static func preview(_ message: MessageRecord, namingSpeaker: Bool, reader: Reader) -> String {
        let hiding = message.hidesWords(filtering: reader.filtering, me: reader.me)
        let body = TextLimits.normalizeSingleLine(AttachmentKind.line(of: message, hiding: hiding))
        if message.senderId == reader.me {
            return Copy.ChatList.preview(speaker: Copy.Common.you, body: body)
        }
        guard namingSpeaker else {
            return body
        }
        return Copy.ChatList.preview(speaker: reader.directory.label(for: message.senderId).text, body: body)
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
            ChatListAssembler.state(
                threads: session.threads(),
                directory: session.directory,
                me: session.identity.nodeId,
                linked: linked,
                filtering: session.filtersContent
            )
        }
    }

    /// Our own face, on the button that opens Settings, where Signal puts it (ADR 2026-10.5waw).
    public var ownFace: Face {
        session.directory.face(for: session.identity.nodeId)
    }

    /// The status line.
    public var status: ConnectionStatus {
        ConnectionStatus(radio: session.radioState, isRunning: session.isRunning, linked: session.neighbors.count)
    }

    /// Starts a stopped mesh, from the status line.
    public func start() async {
        await session.start()
    }

    /// Deletes `row`'s thread from this iPhone (`ChatListViewModel.deleteConversation`, ADR 2026-10.u7cq): a DM or a
    /// group leaves the list until its next message, and the room empties and stays.
    public func delete(_ row: ChatRow) async {
        await session.deleteChat(row.id)
    }
}
