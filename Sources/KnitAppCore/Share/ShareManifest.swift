/// One share the share sheet took from another app, as it lies in the App Group's inbox (ADR 2026-10.z7a8): the
/// words, the thread it goes to, and whether a picture lies beside it. The sheet writes it and the app drains it, and
/// the two ship together, so a manifest of another version is one to drop rather than read.
public struct ShareManifest: Sendable, Equatable, Codable {
    /// What the share is. Its raw value is what the manifest stores, so a case keeps its number.
    public enum Kind: Int, Sendable, Codable {
        /// Words, a picture, or both, for a thread.
        case message = 1
        /// A Knit contact link, which goes to Add contact rather than a thread (ADR 2026-10.tpr5).
        case contactLink = 2
    }

    /// Why the drain held a share back for its thread's composer rather than sending it. Its raw value is what the
    /// manifest stores, so a case keeps its number.
    public enum Refusal: Int, Sendable, Codable {
        /// The room refused its words (ADR 2026-10.spcy).
        case words = 1
        /// The room refused its picture as explicit.
        case explicitPhoto = 2
        /// Its picture could not be read.
        case unreadablePhoto = 3
        /// Its picture is too large to send, even made smaller.
        case photoTooLarge = 4
        /// The thread takes nothing now: a blocked person's DM, a group we left or nobody else is in, or a request,
        /// which a send would accept.
        case closed = 5
    }

    /// The layout this build writes and reads.
    public static let currentVersion = 1

    /// The layout the manifest was written in.
    public var version: Int
    /// What the share is.
    public var kind: Kind
    /// The thread: `nearby`, a peer's node id or a group's id. Empty for a contact link.
    public var conversationId: String
    /// The words: the message, or the contact link itself.
    public var text: String
    /// Whether the picture's bytes lie beside the manifest.
    public var hasPicture: Bool
    /// When the sheet took it, in wall milliseconds.
    public var createdAt: Int64
    /// Why the drain held it, once it has.
    public var refusal: Refusal?

    /// A message of `text` for `conversationId`, with a picture beside it when `hasPicture`, taken at `createdAt`.
    public static func message(_ text: String, to conversationId: String, hasPicture: Bool, at createdAt: Int64) -> Self {
        Self(
            version: currentVersion,
            kind: .message,
            conversationId: conversationId,
            text: text,
            hasPicture: hasPicture,
            createdAt: createdAt,
            refusal: nil
        )
    }

    /// The contact link `link`, taken at `createdAt`.
    public static func contactLink(_ link: String, at createdAt: Int64) -> Self {
        Self(
            version: currentVersion,
            kind: .contactLink,
            conversationId: "",
            text: link,
            hasPicture: false,
            createdAt: createdAt,
            refusal: nil
        )
    }
}
