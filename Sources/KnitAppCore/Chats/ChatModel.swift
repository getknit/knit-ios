import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// One message as a thread shows it.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    /// The frame id.
    public var id: String
    /// The text.
    public var body: String
    /// When it was sent, by its author's clock.
    public var sentAt: Int64
    /// Whether we wrote it.
    public var isMine: Bool
    /// Who wrote it.
    public var author: NodeId
    /// The author's label, over someone else's message in the room; `nil` in a DM, where the title says who.
    public var authorLabel: String?
    /// How far it got, when it is ours.
    public var status: DeliveryStatus?
}

/// A thread, as one value.
public struct ChatState: Sendable, Equatable {
    /// The room's name, or the peer's label.
    public var title: String
    /// The DM's peer, or `nil` for the room.
    public var peer: NodeId?
    /// The messages in reading order.
    public var messages: [ChatMessage]
    /// Whether this DM is a stranger's message request, which waits for Accept.
    public var isRequest: Bool
    /// Whether the DM's peer is linked now.
    public var isLinked: Bool
    /// Whether the DM's peer is verified.
    public var isVerified: Bool

    /// Whether this is the room.
    public var isRoom: Bool { peer == nil }
}

/// A thread's view model: its messages, the composer, and a request's Accept.
@preconcurrency
@MainActor
@Observable
public final class ChatModel {
    /// The thread: `nearby`, or the peer's node id.
    public let conversationId: String
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<Int, ChatState>()
    private var text = ""

    /// The thread `conversationId` over `session`.
    public init(conversationId: String, session: AppSession) {
        self.conversationId = conversationId
        self.session = session
    }

    /// What the composer holds, cut at the limit as it is typed.
    public var draft: String {
        get { text }
        set { text = Composer.clamp(newValue) }
    }

    /// How much room the draft has left, once it nears the limit.
    public var remaining: Int? {
        Composer.remaining(text)
    }

    /// Whether Send has anything to send.
    public var canSend: Bool {
        Composer.body(of: text) != nil
    }

    /// The thread, rebuilt only when something changed.
    public var state: ChatState {
        let linked = session.neighbors.contains { $0.nodeId.string == conversationId }
        var reading = cache.value(for: session.revision) { build() }
        reading.isLinked = linked
        return reading
    }

    /// Sends the draft, and clears it once the message is stored.
    public func send() async {
        let sending = text
        if await session.send(sending, in: conversationId) != nil, text == sending {
            text = ""
        }
    }

    /// Accepts the request this thread is.
    public func accept() async {
        await session.accept(conversationId)
    }

    /// The thread came on screen.
    public func appear() async {
        await session.show(conversationId)
    }

    /// The thread left the screen.
    public func disappear() {
        session.hide(conversationId)
    }

    private func build() -> ChatState {
        let me = session.identity.nodeId
        let directory = session.directory
        let peer = NodeId(conversationId)
        let messages = session.stores.messages.messages(in: conversationId).map { message in
            let isMine = message.senderId == me
            return ChatMessage(
                id: message.id,
                body: message.body,
                sentAt: message.sentAt,
                isMine: isMine,
                author: message.senderId,
                authorLabel: peer == nil && !isMine ? directory.label(for: message.senderId).text : nil,
                status: isMine ? DeliveryStatus(message) : nil
            )
        }
        return ChatState(
            title: peer.map { directory.label(for: $0).text } ?? Copy.ChatList.nearby,
            peer: peer,
            messages: messages,
            isRequest: peer != nil && !messages.isEmpty && session.threads().isRequest(conversationId),
            isLinked: false,
            isVerified: peer.map(directory.verified.contains) ?? false
        )
    }
}
