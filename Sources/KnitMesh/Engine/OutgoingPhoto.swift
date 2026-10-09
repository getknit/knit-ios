public import KnitWire

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
    /// The blob this phone already holds the same picture as, which a DM or a group sends instead of sealing it again
    /// (``MeshEngine/heldPhoto(picked:)``, ADR 2026-10.f3mv); `nil` for a picture this phone has not held.
    public var identity: PhotoIdentity?
    /// The hash of the bytes the picker handed over, when preparing them changed them: what the message remembers, so
    /// the same original picked again is found.
    public var sourceHash: BlobHash?

    /// A photo of type `mime`.
    public init(bytes: [UInt8], mime: String, identity: PhotoIdentity? = nil, sourceHash: BlobHash? = nil) {
        self.bytes = bytes
        self.mime = mime
        self.identity = identity
        self.sourceHash = sourceHash
    }
}

/// A picture as this phone already holds it: its blob's hash, and the key that opens it when it is sealed, or `nil`
/// for a room post's, whose blob is the picture (knit-next `AttachmentIdentities.Held`).
public struct PhotoIdentity: Sendable, Equatable {
    /// The blob's hash.
    public var hash: BlobHash
    /// The base64 key that opens it, or `nil` for a plaintext blob.
    public var key: String?

    /// An identity.
    public init(hash: BlobHash, key: String?) {
        self.hash = hash
        self.key = key
    }
}
