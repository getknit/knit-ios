/// A photo to send in a message: its bytes as they leave this phone, and their type. The app prepares it as Android's
/// `AttachmentStore.ingest` does: upright, at most 1280 pixels on its long side, with the metadata gone. In a DM or a
/// group it is sealed on the way out (`AttachmentCrypto`), and in the room it goes as it is.
public struct OutgoingPhoto: Sendable, Equatable {
    /// The most a photo may weigh, 8 MiB (`AttachmentStore.MAX_BYTES`): what a FILE record's receiver takes whole.
    public static let maxBytes = 8_388_608

    /// The photo's bytes.
    public var bytes: [UInt8]
    /// Their type, `image/jpeg` for most.
    public var mime: String

    /// A photo of type `mime`.
    public init(bytes: [UInt8], mime: String) {
        self.bytes = bytes
        self.mime = mime
    }
}
