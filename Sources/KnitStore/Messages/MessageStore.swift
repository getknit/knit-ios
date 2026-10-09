public import KnitWire

/// What a thread row is (`MessageEntity.kind`, `MessageEntity.kt:225-277`): an ordinary message, or a status line
/// this node wrote about an event, such as a member leaving a group.
///
/// The codes are knit-next's, and never leave this phone. Anything but ``message`` is a notice, including a code
/// this build has no words for, which a newer build may have written. Reading one never fails, because one row
/// that failed would empty a whole thread (ADR 2026-09.n393).
public struct MessageKind: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// An ordinary message (`KIND_NORMAL`).
    public static let message: Self = 0
    /// A member left a group by their own signed `groupleave` (`KIND_MEMBER_LEFT`).
    public static let memberLeft: Self = 1
    /// A member renamed a group; the row's body is the new name (`KIND_GROUP_RENAMED`).
    public static let groupRenamed: Self = 4
    /// A group was created (`KIND_GROUP_CREATED`).
    public static let groupCreated: Self = 6
    /// A member who left came back by a frame of their own (`KIND_MEMBER_REJOINED`).
    public static let memberRejoined: Self = 9

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }

    /// Whether the row is a status line rather than a message: never a preview, never acknowledged, and never what
    /// makes someone a sender in a thread (`isStatusNotice`).
    public var isNotice: Bool { self != .message }
}

/// What the content filter made of a message's words (`MessageEntity.moderation`, ADR 2026-10.e4kz): clear, flagged, or
/// not yet asked.
///
/// The first two codes are knit-next's, and none leaves this phone. Android classifies a message before it stores it,
/// so it never needs ``waiting``; here the engine stores someone else's message first, and the app screens it before it
/// shows or notifies it. A code this build does not know reads as ``clear``, as an unknown kind reads as a notice.
public struct MessageModeration: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// The words passed, or were never screened: our own, a status line, a message stored before v7, or one the model
    /// could not score (`MODERATION_NONE`).
    public static let clear: Self = 0
    /// The on-device text filter flagged the words (`MODERATION_TEXT_FLAGGED`).
    public static let flagged: Self = 1
    /// Someone else's words, stored and not yet screened. Nothing shows them while the filter is on.
    public static let waiting: Self = 2

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }
}

/// What a message carries besides its text (`MessageEntity.attachment*` in knit-next): a photo, or a file or voice
/// note this build shows only as a label.
///
/// A room post's photo is public: its blob is the photo itself. A DM's or a group message's is sealed
/// (`AttachmentCrypto`): its blob is the ciphertext, and ``key`` opens it, which only the sealed message carried.
public struct MessageAttachment: Sendable, Equatable {
    /// The blob's hash: of the photo in the room, of its ciphertext in a DM or a group.
    public var hash: BlobHash
    /// The type the sender gave it, `image/jpeg` for most photos; `nil` when it gave none.
    public var mime: String?
    /// The base64 key that opens a sealed blob, or `nil` for a room post's.
    public var key: String?
    /// A file's name, which only a file carries.
    public var name: String?
    /// A file's size in bytes, before sealing, which only a file carries.
    public var size: Int64?
    /// A photo's size, and whether it moves, read from its bytes on this phone: `nil` until they are here and have been
    /// read, and for anything but a photo. It never crosses the wire, as knit-next's voice-note fields never do.
    public var dimensions: PhotoDimensions?
    /// The SHA-256 of a sealed blob's plaintext, which names the picture apart from any one seal: written as we seal
    /// it, as its bytes land, or as it is saved, and `nil` for a room post's, whose ``hash`` already is that (knit-next
    /// `MessageEntity.attachmentPlainHash`, ADR 2026-10.f3mv). Local only.
    public var plainHash: BlobHash?
    /// The hash of the bytes the picker handed over for one of our sends, when preparing them changed them, so the
    /// same original picked again is found (`attachmentSourceHash`). Local only.
    public var sourceHash: BlobHash?

    /// An attachment.
    public init(
        hash: BlobHash, mime: String? = nil, key: String? = nil, name: String? = nil, size: Int64? = nil,
        dimensions: PhotoDimensions? = nil, plainHash: BlobHash? = nil, sourceHash: BlobHash? = nil
    ) {
        self.hash = hash
        self.mime = mime
        self.key = key
        self.name = name
        self.size = size
        self.dimensions = dimensions
        self.plainHash = plainHash
        self.sourceHash = sourceHash
    }
}

/// A photo's size in pixels, upright: turned as its orientation says, so a portrait stands taller than it is wide. A
/// thread holds a photo's place at this shape from its first frame, before the photo decodes. Read beside it, from
/// the same bytes, is whether the photo moves, which a line about the message names a GIF (knit-next `0b9d19ea`).
public struct PhotoDimensions: Sendable, Hashable {
    /// The width, in pixels.
    public let width: Int
    /// The height, in pixels.
    public let height: Int
    /// Whether it has more than one frame: a GIF, an animated WebP or an APNG that plays.
    public let animated: Bool

    /// A size, or `nil` unless both sides are at least a pixel.
    public init?(width: Int, height: Int, animated: Bool = false) {
        guard width > 0, height > 0 else {
            return nil
        }
        self.width = width
        self.height = height
        self.animated = animated
    }
}

/// A message in a thread (`MessageEntity` in knit-next, the fields this port reads): ours, one delivered to us, or
/// a status line about an event (``kind``).
public struct MessageRecord: Sendable, Equatable {
    /// The frame id, which a receipt acknowledges.
    public var id: String
    /// The author.
    public var senderId: NodeId
    /// The recipient, for a DM; `nil` for a room post.
    public var recipientId: NodeId?
    /// The thread (``Conversations``).
    public var conversationId: String
    /// The text, at most 2000 UTF-16 units.
    public var body: String
    /// The author's clock, clamped to five minutes past ours on the way in, so a far-future post cannot pin
    /// itself to the top of a thread.
    public var sentAt: Int64
    /// When it reached us by our own clock, or `nil` for our own message.
    public var arrivedAt: Int64?
    /// Ours only: a receipt came back. For a DM that means its recipient has it; for a room post, that someone
    /// does.
    public var delivered: Bool
    /// Ours only: waiting for a key, sealed and sent once one pins. A DM waits for its recipient's, and a group
    /// message for any member's.
    public var pendingKey: Bool
    /// A message, or a status line. For a status line, ``senderId`` is whom the event is about.
    public var kind: MessageKind
    /// The photo or file it carries, or `nil`.
    public var attachment: MessageAttachment?
    /// What the content filter made of its words.
    public var moderation: MessageModeration

    /// Makes a record.
    public init(
        id: String,
        senderId: NodeId,
        recipientId: NodeId?,
        conversationId: String,
        body: String,
        sentAt: Int64,
        arrivedAt: Int64? = nil,
        delivered: Bool = false,
        pendingKey: Bool = false,
        kind: MessageKind = .message,
        attachment: MessageAttachment? = nil,
        moderation: MessageModeration = .clear
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.conversationId = conversationId
        self.body = body
        self.sentAt = sentAt
        self.arrivedAt = arrivedAt
        self.delivered = delivered
        self.pendingKey = pendingKey
        self.kind = kind
        self.attachment = attachment
        self.moderation = moderation
    }
}

/// The message threads (`MessageRepository` in knit-next).
public protocol MessageStore: AnyObject, Sendable {
    /// The message `id`, or `nil`.
    func message(_ id: String) -> MessageRecord?

    /// Whether `id` is held, or was deleted and is still remembered: the gate that keeps a re-served frame from
    /// notifying twice, and a deleted one from coming back (ADR 2026-10.u7cq).
    func contains(_ id: String) -> Bool

    /// Stores `message` unless its id is held or remembered as deleted, and answers whether it did. A re-served frame
    /// carries the same signed bytes, so it can never say anything new.
    @discardableResult
    func insertIfAbsent(_ message: MessageRecord) -> Bool

    /// Stores `message`, replacing any row with its id.
    func save(_ message: MessageRecord)

    /// Marks our message `id` delivered, and answers whether that changed anything.
    @discardableResult
    func markDelivered(_ id: String) -> Bool

    /// Our DMs to `recipient` still waiting for their key, oldest first.
    func pendingKey(to recipient: NodeId) -> [MessageRecord]

    /// Our messages in the thread `conversationId` still waiting for a key, oldest first: a group's.
    func pendingKey(in conversationId: String) -> [MessageRecord]

    /// Clears `id`'s pending-key flag once it has been sealed and sent.
    func clearPendingKey(_ id: String)

    /// The threads `author` has written in: part of what makes a thread accepted rather than a request. A status
    /// line counts, as on Android (`MessageDao.kt:294`), so the creator's own "created" line accepts a group.
    func conversations(authoredBy author: NodeId) -> Set<String>

    /// Who wrote an ordinary message in `conversationId`; status lines never count (`MessageDao.sendersIn`). A group
    /// is accepted when one of them is someone we know.
    func senders(in conversationId: String) -> Set<NodeId>

    /// A thread's messages in reading order: by `sentAt`, ties in the order they were stored.
    func messages(in conversationId: String) -> [MessageRecord]

    /// The newest message of every thread, newest thread first, never one `blocked` wrote: what a list row shows for
    /// its thread (`observeNewestPerConversation` in knit-next). A thread's newest is the last in its reading order, and
    /// a status line is never one, so a thread of nothing but status lines, or of nothing but what blocked people
    /// wrote, has no head (`observeDistinctConversations`).
    func threadHeads(excludingSenders blocked: Set<NodeId>) -> [MessageRecord]

    /// Removes the message `id` at `now`, with its reactions, and answers what it was, or `nil` when nothing is held
    /// under that id. An ordinary message's id is remembered until ``DeletedMessages/expiry(sentAt:deletedAt:limits:)``,
    /// so a carrier that re-serves its frame cannot bring it back (ADR 2026-10.u7cq). A status line's is not: its id is
    /// our own, and a later change to the group must be able to write it again.
    @discardableResult
    func deleteMessage(_ id: String, at now: Int64) -> MessageRecord?

    /// Removes every row of `conversationId` at `now`, status lines and reactions included, remembering each ordinary
    /// message's id as ``deleteMessage(_:at:)`` does, and answers what it removed: what deleting a chat and leaving a
    /// group do to its thread.
    @discardableResult
    func deleteMessages(in conversationId: String, at now: Int64) -> [MessageRecord]

    /// Forgets every deleted id remembered only until before `now`: no carrier holds those frames any more.
    func pruneDeleted(before now: Int64)

    /// The photos the deleted messages still remembered carried, by their frames' ids' bytes.
    func deletedAttachments() -> [DeletedAttachment]

    /// Every thread with a row of any kind, status lines included. A group whose thread was deleted has none, and
    /// leaves the chat list until its next row (ADR 2026-10.u7cq).
    func conversationIds() -> Set<String>

    /// The blobs the messages carry: what keeps a photo from being swept, and what is fetched while its bytes are
    /// missing (`MessageDao.attachmentHashes`).
    func attachmentHashes() -> Set<BlobHash>

    /// Who sent the earliest message carrying each of `hashes`, by `sentAt` and then by id, its bytes compared
    /// (`MessageDao.attachmentsNeedingFetch`): the one holder a fetch of that blob can name (knit-next ADR 2026-10.f7gg).
    /// A hash no message carries has no entry.
    func attachmentSenders(among hashes: Set<BlobHash>) -> [BlobHash: NodeId]

    /// What the messages carry whose size this phone has not read, each blob once with the key that opens it, the latest
    /// stored first: all of it for a launch to read the sizes of, or only blob `hash`'s, which has just landed. Files and
    /// voice messages are among them, and never get a size.
    func unsizedAttachments(named hash: BlobHash?) -> [MessageAttachment]

    /// Records the size of the photo in blob `hash` on every message that carries it, and answers whether that changed
    /// anything.
    @discardableResult
    func setAttachmentDimensions(_ hash: BlobHash, to dimensions: PhotoDimensions) -> Bool

    /// The pictures held under a name `bytesHash` could be, best first (`MessageDao.identityFor`, ADR 2026-10.f3mv): a
    /// sealed one whose plaintext it is, one of our sends whose picked bytes it is, or a room post's, which it names
    /// outright. A room post's wins, since its public name is the one most phones nearby hold, then a moving one, then
    /// the earliest. A sealed one that has no plaintext name never answers, or its ciphertext's hash would stand for
    /// the plaintext's. Whether each blob is still held is the caller's to ask.
    func identities(matching bytesHash: BlobHash) -> [MessageAttachment]

    /// The messages that carry a sealed copy of the plaintext `plainHash`, the earliest first by `sentAt` and then by
    /// id (`MessageDao.sealedHolding`, before its author's test).
    func sealedCopies(of plainHash: BlobHash) -> [MessageRecord]

    /// The key of a message carrying sealed blob `hash` that does not know its plaintext yet, or `nil` when none
    /// wants it (`MessageDao.attachmentKeyWantingPlain`).
    func keyWantingPlainHash(_ hash: BlobHash) -> String?

    /// Records `plainHash` on every sealed message carrying blob `hash` that has none, and answers whether that changed
    /// anything (`MessageDao.setAttachmentPlainHash`).
    @discardableResult
    func setAttachmentPlainHash(_ hash: BlobHash, to plainHash: BlobHash) -> Bool

    /// Records what the content filter made of message `id`'s words, and answers whether that changed anything.
    @discardableResult
    func setModeration(_ id: String, to moderation: MessageModeration) -> Bool

    /// The messages still ``MessageModeration/waiting`` to be screened, in the order they were stored: what a launch
    /// screens when the app stopped before it could.
    func waitingForModeration() -> [MessageRecord]

    /// Stores `reaction` unless the one held for its message and reactor is as new or newer, or its message is
    /// remembered as deleted, and answers whether it did (`ReactionRepository.apply`). Strictly newer wins and a tie
    /// keeps what is held, so out-of-order adds, replacements and retractions converge, and a re-served frame changes
    /// nothing. Android reads, then writes, in one transaction; here the check and the write are one statement.
    @discardableResult
    func applyReaction(_ reaction: ReactionRecord) -> Bool

    /// The reaction `reactor` holds on message `messageId`, a retraction included, or `nil` when they never reacted.
    func reaction(on messageId: String, by reactor: NodeId) -> ReactionRecord?

    /// The reactions standing on the ordinary messages of `conversationId` held now, oldest first, ties by the
    /// message's id and then the reactor's, both by their bytes. Retractions, reactions to status lines and reactions
    /// whose message is not held are left out.
    func reactions(in conversationId: String) -> [ReactionRecord]

    /// Forgets every reaction, retractions included, updated before `cutoff` whose message is not held
    /// (`ReactionDao.deleteOrphansOlderThan`).
    func pruneOrphanReactions(updatedBefore cutoff: Int64)
}

extension MessageStore {
    /// The newest message of every thread, newest thread first, whoever wrote it.
    public func threadHeads() -> [MessageRecord] {
        threadHeads(excludingSenders: [])
    }
}
