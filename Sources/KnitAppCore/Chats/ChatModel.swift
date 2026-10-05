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
    /// Why the content filter keeps its words out of sight, or `nil` while they show (ADR 2026-10.e4kz).
    public var hiddenWords: HiddenWords?
}

/// Why a thread keeps someone else's words out of sight while the content filter is on.
public enum HiddenWords: Sendable, Equatable {
    /// The filter flagged them, and a tap shows them.
    case flagged
    /// The filter has not read them yet, which takes a moment after they land; they show, or stay hidden, once it has.
    case unscreened

    /// Why words the filter `moderation` describes are hidden, given that they are.
    init(_ moderation: MessageModeration) {
        self = moderation == .flagged ? .flagged : .unscreened
    }
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
    /// Whether the DM's peer is blocked: the thread shows only what we wrote, and Unblock in the composer's place
    /// (ADR 2026-10.5wgg).
    public var isBlocked = false

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
    @ObservationIgnored private let screening: PhotoScreening?
    @ObservationIgnored private var cache = Cached<Int, ChatState>()
    private var text = ""
    /// The photo the composer holds, which Send sends with the draft or alone.
    public private(set) var staged: StagedPhoto?
    /// Whether the last photo picked could not be read, which the screen says until it is dismissed.
    public var photoFailed = false
    /// Whether the last photo picked looked explicit in the room, which refuses it; the screen says so until it is
    /// dismissed.
    public var photoRefused = false
    /// A photo picked in a DM or a group that looked explicit, held out of the composer until the sender says to send it
    /// anyway or drops it (ADR 2026-10.rpmq).
    private(set) var explicitPhoto: OutgoingPhoto?
    /// Whether the screen asks about ``explicitPhoto``. Its answer is ``keepExplicitPhoto()`` or
    /// ``dropExplicitPhoto()``; dismissing the question changes neither.
    public var asksAboutExplicitPhoto = false
    /// Whether the last Send was refused for abusive words, which the screen says until it is dismissed. The draft and
    /// the photo stay in the composer (`ChatViewModel.send`).
    public var wordsRefused = false
    /// Whether a Send is under way, from the tap until the message is stored or refused (`ChatViewModel.isSending`).
    /// The words are checked first, and the first check in a while waits for the model to load, so the screen shows it
    /// working. A tap meanwhile sends nothing more.
    public private(set) var isSending = false

    /// The thread `conversationId` over `session`, making picked photos ready to send through `codec` and checking them
    /// with `screening`.
    public init(conversationId: String, session: AppSession, codec: (any ImageCodec)? = nil, screening: PhotoScreening? = nil) {
        self.conversationId = conversationId
        self.session = session
        self.codec = codec
        self.screening = screening
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
        let thread = state
        return (Composer.body(of: text) != nil || staged != nil) && !thread.nobodyElse && !thread.isBlocked
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
    ///
    /// Words that look abusive are not sent, in any thread and whatever the content filter says, which governs only
    /// what we are shown (`MeshManager.sendChat`). The room adds its word list. Words the model could not read go.
    public func send() async {
        guard !isSending else {
            return
        }
        isSending = true
        defer { isSending = false }
        let sending = text
        let photo = staged
        if await session.textScreening?.isAbusive(sending, inRoom: state.isRoom) ?? false {
            wordsRefused = true
            return
        }
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
    ///
    /// The prepared photo is checked whatever the content filter says (`ChatViewModel.stage`). One that looks explicit
    /// is refused in the room, which floods to everyone in range, and held for a DM or a group until the sender answers.
    public func choosePhoto(_ data: Data?) async {
        guard let data, let codec, let photo = await codec.chatPhoto(from: data) else {
            photoFailed = true
            return
        }
        guard await screening?.isExplicit(outgoing: photo.bytes) == true else {
            staged = await Self.stage(photo)
            return
        }
        if state.isRoom {
            photoRefused = true
        } else {
            explicitPhoto = photo
            asksAboutExplicitPhoto = true
        }
    }

    /// Holds the explicit photo in the composer after all: the sender said to send it anyway.
    public func keepExplicitPhoto() async {
        guard let photo = explicitPhoto else {
            return
        }
        explicitPhoto = nil
        staged = await Self.stage(photo)
    }

    /// Drops the explicit photo, which never reached the composer.
    public func dropExplicitPhoto() {
        explicitPhoto = nil
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

    /// Deletes `message` from this iPhone (ADR 2026-10.u7cq), from its bubble's menu. A status line is not a message, and
    /// stays.
    public func delete(_ message: ChatMessage) async {
        guard message.notice == nil else {
            return
        }
        await session.deleteMessage(message.id)
    }

    /// Blocks the DM's peer: from a request's bar.
    public func block() async {
        if let peer = NodeId(conversationId) {
            await session.block(peer)
        }
    }

    /// Unblocks the DM's peer: from the bar a blocked DM shows.
    public func unblock() async {
        if let peer = NodeId(conversationId) {
            await session.unblock(peer)
        }
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
        // What blocked people wrote stays stored and hidden, and shows again once they are unblocked
        // (`ChatViewModel.kt:780-795`).
        let stored = session.stores.messages.messages(in: conversationId).filter { !directory.blocked.contains($0.senderId) }
        let held = session.stores.blobs.held(among: Set(stored.compactMap(\.attachment?.hash)))
        let filtering = session.filtersContent
        let messages = stored.compactMap { message in
            chatMessage(message, kind: kind, directory: directory, held: held, filtering: filtering)
        }
        let members = group?.members ?? []
        let isBlocked = peer.map(directory.blocked.contains) ?? false
        var built = ChatState(
            title: peer.map { directory.label(for: $0).text } ?? Copy.ChatList.nearby,
            kind: kind,
            peer: peer,
            messages: messages,
            isRequest: peer != nil && !isBlocked && !messages.isEmpty && threads.isRequest(conversationId),
            requestTitle: Copy.Chat.requestTitle(peer.map { directory.label(for: $0).text } ?? ""),
            requestBody: Copy.Chat.requestBody,
            isLinked: false,
            isVerified: peer.map(directory.verified.contains) ?? false,
            memberCount: nil,
            nobodyElse: false,
            exists: kind != .group || group != nil,
            face: peer.map(directory.face(for:)) ?? (kind == .group ? .group(conversationId, photo: nil, members: []) : .room),
            isBlocked: isBlocked
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
        _ message: MessageRecord, kind: ThreadKind, directory: Directory, held: Set<BlobHash>, filtering: Bool
    ) -> ChatMessage? {
        let me = session.identity.nodeId
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
                attachment: message.attachment.flatMap { ChatAttachment($0, isHeld: held.contains($0.hash)) },
                hiddenWords: message.hidesWords(filtering: filtering, me: me) ? HiddenWords(message.moderation) : nil
            )
        }
        return GroupNaming.notice(message, me: me, directory: directory).map { words in
            ChatMessage(id: message.id, body: "", sentAt: message.sentAt, isMine: false, author: message.senderId, notice: words)
        }
    }
}
