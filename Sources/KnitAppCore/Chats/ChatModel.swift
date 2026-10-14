import Foundation
import KnitCrypto
import KnitMesh
public import KnitStore
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
    /// The emoji people reacted with, each where it first appeared; empty for none and for a status line
    /// (ADR 2026-10.ehe6).
    public var reactions: [ReactionChip] = []
    /// The message it replies to, as its author quoted it, or `nil` (ADR 2026-10.mn29). Its words hide with the reply's.
    public var quote: ChatQuote?
    /// Where the names it mentions sit in ``body``, in UTF-16 offsets, which the bubble sets apart (ADR 2026-10.nbhj).
    public var mentionSpans: [Range<Int>] = []
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
    /// Who is typing here now, in name order: the row at the thread's foot.
    public var typing: [Typist] = []

    /// Whether this is the room.
    public var isRoom: Bool { kind == .room }
    /// Whether this is a group.
    public var isGroup: Bool { kind == .group }
    /// Whether its messages take a reaction: wherever the composer is, so not on a request, a blocked person's DM or a
    /// group nobody else is left in (ADR 2026-10.ehe6).
    public var canReact: Bool { exists && !isRequest && !isBlocked && !nobodyElse }
    /// Whether its messages take a reply: wherever the composer is, as for a reaction (ADR 2026-10.mn29).
    public var canReply: Bool { canReact }
}

/// A thread's view model: its messages and status lines, the composer, and a request's Accept.
@preconcurrency
@MainActor
@Observable
public final class ChatModel {
    /// The thread: `nearby`, the peer's node id, or the group's id.
    public let conversationId: String
    @ObservationIgnored let session: AppSession
    @ObservationIgnored let codec: (any ImageCodec)?
    @ObservationIgnored let screening: PhotoScreening?
    /// The thread as last built, with whose reactions and typing it shows.
    @ObservationIgnored private var cache = Cached<Int, (state: ChatState, audience: ReactionAudience)>()
    private var text = ""
    /// The photo the composer holds, which Send sends with the draft or alone.
    public internal(set) var staged: StagedPhoto?
    /// The quote the composer holds, which Send sends with the draft and the photo (ADR 2026-10.mn29).
    public internal(set) var replying: ComposerReply?
    /// How many replies were started here, so the composer's field takes focus at each.
    public internal(set) var repliesStarted = 0
    /// The people picked in the composer since its last Send, whose names keep their chips while the draft holds them
    /// (`pendingMentions` in `ChatScreen.kt`, ADR 2026-10.nbhj).
    public internal(set) var pendingMentions: [MessageMention] = []
    /// The field's selection in UTF-16 offsets, which the field keeps up to date: where the "@" word ends.
    public var selection = 0..<0
    /// The people the thread offers to mention, rebuilt when the session moves.
    @ObservationIgnored var offeredCache = Cached<Int, [MentionCandidate]>()
    /// Why the last photo picked cannot be sent, which the screen says until it is dismissed.
    public var photoFailure: PhotoFailure?
    /// Whether a picked photo is being made ready to send: a GIF's frames take a moment to shrink.
    public internal(set) var preparingPhoto = false
    /// Counts picks, so a slow one that finishes after a later pick leaves the later one in the composer.
    @ObservationIgnored var picks = 0
    /// Whether the last photo picked looked explicit in the room, which refuses it; the screen says so until it is
    /// dismissed.
    public var photoRefused = false
    /// Whether the last Send in the room was refused for abusive words, which the screen says until it is dismissed. The
    /// draft and the photo stay in the composer (`ChatViewModel.send`).
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

    /// What the composer holds, cut at the limit as it is typed. Each change that leaves words in it tells the thread we
    /// are typing (``cueTyping()``). A selection past the new words' end comes back to it.
    public var draft: String {
        get { text }
        set {
            let typed = Composer.clamp(newValue)
            let changed = typed != text
            text = typed
            let end = typed.utf16.count
            if selection.upperBound > end {
                selection = min(selection.lowerBound, end)..<end
            }
            if changed {
                cueTyping()
            }
        }
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

    /// The thread, rebuilt only when something changed. Who is linked and who is typing are laid over it each time, since
    /// neither moves the session's revision.
    public var state: ChatState {
        let linked = session.neighbors.contains { $0.nodeId.string == conversationId }
        let built = cache.value(for: session.revision) { build() }
        var reading = built.state
        reading.isLinked = linked
        reading.typing = typists(shownBy: built.audience)
        return reading
    }

    /// Sends the draft, the photo and the quote held, and clears each once the message is stored, unless it changed
    /// meanwhile.
    ///
    /// Words that look abusive are not posted in the room, whatever the content filter says, which governs only what we
    /// are shown (`MeshManager.sendChat`). A DM or a group sends them unread: the receiver's phone screens what arrives,
    /// and its filter decides (ADR 2026-10.spcy). Words the model could not read go.
    public func send() async {
        guard !isSending else {
            return
        }
        isSending = true
        defer { isSending = false }
        let sending = text
        let photo = staged
        let reply = replying
        // The picks the words still hold, in the order they were picked, read from the words as typed
        // (`ChatScreen.kt:535-540`).
        let mentions = MessageMention.carried(pendingMentions, in: sending)
        if state.isRoom, await session.textScreening?.isAbusive(sending, inRoom: true) ?? false {
            wordsRefused = true
            return
        }
        guard await session.send(sending, photo: photo?.photo, replyTo: reply?.reply, mentions: mentions, in: conversationId) != nil
        else {
            return
        }
        if text == sending {
            text = ""
            pendingMentions = []
            selection = 0..<0
        }
        if staged == photo {
            staged = nil
        }
        if replying == reply {
            replying = nil
        }
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

    /// Reacts to `message` with `emoji`, or takes our reaction back when it is the one we hold, from its bubble's menu or
    /// a chip (ADR 2026-10.ehe6). A status line takes none.
    public func react(to message: ChatMessage, with emoji: String) async {
        guard message.notice == nil, state.canReact else {
            return
        }
        await session.react(to: message.id, with: emoji)
    }

    /// Files `report` on this iPhone: the message goes and its author is blocked.
    public func report(_ report: AbuseReport) async {
        await session.report(report)
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

    /// The thread came on screen. In the room, under `-demoScene trailer`, it then follows the director's composer
    /// until it leaves the screen (ADR 2026-10.g3k9).
    public func appear() async {
        await session.show(conversationId)
        if let director = session.director, state.isRoom {
            await follow(director)
        }
    }

    /// Raises `director`'s curtain and does in the composer what it does: the words it types, and Send.
    func follow(_ director: DemoDirector) async {
        director.curtain()
        for await step in director.composer {
            switch step {
            case .draft(let words):
                draft = words
            case .send:
                await send()
            }
        }
    }

    /// The thread left the screen.
    public func disappear() {
        session.hide(conversationId)
    }

    private func build() -> (state: ChatState, audience: ReactionAudience) {
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
        let audience = ReactionAudience.of(conversationId, kind: kind, group: group, me: me)
        let chips = ReactionChips.chips(
            session.stores.messages.reactions(in: conversationId), me: me, audience: audience, blocked: directory.blocked)
        // The messages a quote can take the thread to: the ones it shows, status lines aside.
        let shown = Set(stored.filter { !$0.kind.isNotice }.map { ExactKey($0.id) })
        let messages = stored.compactMap { message in
            chatMessage(message, kind: kind, directory: directory, held: held, filtering: filtering)
                .map { $0.reacted(chips[ExactKey(message.id)] ?? []) }
                .map { $0.quoting(message.replyTo.map { ChatQuote($0, me: me, directory: directory, shown: shown) }) }
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
        return (built, audience)
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
                hiddenWords: message.hidesWords(filtering: filtering, me: me) ? HiddenWords(message.moderation) : nil,
                mentionSpans: MentionText.spans(in: message.body, mentions: message.mentions)
            )
        }
        return GroupNaming.notice(message, me: me, directory: directory).map { words in
            ChatMessage(id: message.id, body: "", sentAt: message.sentAt, isMine: false, author: message.senderId, notice: words)
        }
    }
}
