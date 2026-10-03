public import Foundation
import KnitCrypto
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
    /// The author's label, over someone else's message in the room or a group; `nil` in a DM, where the title says who.
    public var authorLabel: String?
    /// How far it got, when it is ours.
    public var status: DeliveryStatus?
    /// A status line's words, which the thread shows in place of a bubble; `nil` for a message.
    public var notice: String?
    /// The author's face, beside someone else's message in the room or a group; `nil` in a DM, for our own messages,
    /// and for a status line.
    public var authorFace: Face?
    /// What the message carries beside its words, or `nil`.
    public var attachment: ChatAttachment?
}

/// What a thread is.
public enum ThreadKind: Sendable, Equatable {
    /// The Nearby room.
    case room
    /// A DM.
    case direct
    /// A group.
    case group
}

/// A thread, as one value.
public struct ChatState: Sendable, Equatable {
    /// The room's name, the peer's label, or the group's title.
    public var title: String
    /// What the thread is.
    public var kind: ThreadKind
    /// The DM's peer, or `nil` for the room and a group.
    public var peer: NodeId?
    /// The messages and status lines in reading order.
    public var messages: [ChatMessage]
    /// Whether this DM or group is a stranger's message request, which waits for Accept.
    public var isRequest: Bool
    /// What a request's bar says.
    public var requestTitle: String
    /// What accepting the request does.
    public var requestBody: String
    /// Whether the DM's peer is linked now.
    public var isLinked: Bool
    /// Whether the DM's peer is verified.
    public var isVerified: Bool
    /// How many people a group holds, us included; `nil` outside a group.
    public var memberCount: Int?
    /// Whether everyone else has left the group, so nothing can be sent.
    public var nobodyElse: Bool
    /// Whether the group is still ours: `false` once we left it, or for one we never held.
    public var exists: Bool
    /// The thread's face, beside its title: the room's, the peer's, or the group's.
    public var face = Face.room

    /// Whether this is the room.
    public var isRoom: Bool { kind == .room }
    /// Whether this is a group.
    public var isGroup: Bool { kind == .group }
}

/// A thread's view model: its messages and status lines, the composer, and a request's Accept.
@preconcurrency
@MainActor
@Observable
public final class ChatModel {
    /// The thread: `nearby`, the peer's node id, or the group's id.
    public let conversationId: String
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let codec: (any ImageCodec)?
    @ObservationIgnored private var cache = Cached<Int, ChatState>()
    private var text = ""
    /// The photo the composer holds, which Send sends with the draft or alone.
    public private(set) var staged: StagedPhoto?
    /// Whether the last photo picked could not be read, which the screen says until it is dismissed.
    public var photoFailed = false

    /// The thread `conversationId` over `session`, making picked photos ready to send through `codec`.
    public init(conversationId: String, session: AppSession, codec: (any ImageCodec)? = nil) {
        self.conversationId = conversationId
        self.session = session
        self.codec = codec
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

    /// Whether Send has anything to send, to anyone.
    public var canSend: Bool {
        (Composer.body(of: text) != nil || staged != nil) && !state.nobodyElse
    }

    /// Whether the composer's button adds a photo rather than sending: nothing is typed and no photo is held, so there
    /// is nothing to send (`SendAction.Attach` in knit-next).
    public var offersPhoto: Bool {
        Composer.body(of: text) == nil && staged == nil
    }

    /// The thread, rebuilt only when something changed.
    public var state: ChatState {
        let linked = session.neighbors.contains { $0.nodeId.string == conversationId }
        var reading = cache.value(for: session.revision) { build() }
        reading.isLinked = linked
        return reading
    }

    /// Sends the draft and the photo held, and clears each once the message is stored, unless it changed meanwhile.
    public func send() async {
        let sending = text
        let photo = staged
        guard await session.send(sending, photo: photo?.photo, in: conversationId) != nil else {
            return
        }
        if text == sending {
            text = ""
        }
        if staged == photo {
            staged = nil
        }
    }

    /// Makes a picked photo ready to send (`AttachmentStore.ingest`) and holds it in the composer, in place of any held
    /// before. One the picker could not hand over, or the codec cannot read, says so.
    public func choosePhoto(_ data: Data?) async {
        guard let data, let codec, let photo = await codec.chatPhoto(from: data) else {
            photoFailed = true
            return
        }
        staged = await Self.stage(photo)
    }

    /// Takes the held photo out of the composer.
    public func removePhoto() {
        staged = nil
    }

    /// `photo` with the hash of its bytes, taken off the main actor, since a GIF may weigh megabytes.
    @concurrent
    private static func stage(_ photo: OutgoingPhoto) async -> StagedPhoto {
        StagedPhoto(photo: photo, hash: BlobHash(of: photo.bytes))
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
        let threads = session.threads()
        let peer = NodeId(conversationId)
        let group = threads.group(conversationId)
        let kind: ThreadKind = Conversations.isGroup(conversationId) ? .group : peer == nil ? .room : .direct
        let stored = session.stores.messages.messages(in: conversationId)
        let held = session.stores.blobs.held(among: Set(stored.compactMap(\.attachment?.hash)))
        let messages = stored.compactMap { message in
            chatMessage(message, kind: kind, me: me, directory: directory, held: held)
        }
        let members = group?.members ?? []
        var built = ChatState(
            title: peer.map { directory.label(for: $0).text } ?? Copy.ChatList.nearby,
            kind: kind,
            peer: peer,
            messages: messages,
            isRequest: peer != nil && !messages.isEmpty && threads.isRequest(conversationId),
            requestTitle: Copy.Chat.requestTitle(peer.map { directory.label(for: $0).text } ?? ""),
            requestBody: Copy.Chat.requestBody,
            isLinked: false,
            isVerified: peer.map(directory.verified.contains) ?? false,
            memberCount: nil,
            nobodyElse: false,
            exists: kind != .group || group != nil,
            face: peer.map(directory.face(for:)) ?? (kind == .group ? .group(conversationId, photo: nil, members: []) : .room)
        )
        if let group {
            built.face = directory.face(of: group)
            built.title = GroupNaming.title(of: group, me: me, directory: directory)
            built.isRequest = threads.isRequest(conversationId)
            built.requestTitle = Copy.Groups.requestTitle(GroupNaming.starter(of: group, me: me, directory: directory))
            built.requestBody = Copy.Groups.requestBody
            built.memberCount = members.count
            built.nobodyElse = !members.contains { ExactKey($0) != ExactKey(me.string) }
        }
        return built
    }

    /// One row of the thread: a message, or a status line this build has words for.
    private func chatMessage(
        _ message: MessageRecord, kind: ThreadKind, me: NodeId, directory: Directory, held: Set<BlobHash>
    ) -> ChatMessage? {
        let isMine = message.senderId == me
        guard message.kind.isNotice else {
            let named = kind != .direct && !isMine
            return ChatMessage(
                id: message.id,
                body: message.body,
                sentAt: message.sentAt,
                isMine: isMine,
                author: message.senderId,
                authorLabel: named ? directory.label(for: message.senderId).text : nil,
                status: isMine ? DeliveryStatus(message) : nil,
                authorFace: named ? directory.face(for: message.senderId) : nil,
                attachment: message.attachment.flatMap { ChatAttachment($0, isHeld: held.contains($0.hash)) }
            )
        }
        return GroupNaming.notice(message, me: me, directory: directory).map { words in
            ChatMessage(id: message.id, body: "", sentAt: message.sentAt, isMine: false, author: message.senderId, notice: words)
        }
    }
}
