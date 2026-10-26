public import KnitWire

/// An attachment to send in a message, a photo or a voice note: its bytes as they leave this phone, and their type. The
/// name is the photo's, which came first; the engine is blind to what the bytes are. The app prepares a photo as Android's
/// `AttachmentStore.ingest` does: upright, at most 1280 pixels on its long side, with the metadata gone. A voice note is
/// AAC-LC in ADTS, `audio/aac`, sent as it was recorded (knit-next ADR 034). In a DM or a group either is sealed on the
/// way out (`AttachmentCrypto`), and in the room it goes as it is.
public struct OutgoingPhoto: Sendable, Equatable {
    /// The most an attachment may weigh, 8 MiB (`AttachmentStore.MAX_BYTES`): what a FILE record's receiver takes whole.
    public static let maxBytes = 8_388_608

    /// The attachment's bytes.
    public var bytes: [UInt8]
    /// Their type: `image/jpeg` for most photos, `audio/aac` for a voice note.
    public var mime: String
    /// The blob this phone already holds the same picture as, which a DM or a group sends instead of sealing it again
    /// (``MeshEngine/heldPhoto(picked:)``, ADR 2026-10.f3mv); `nil` for a picture this phone has not held.
    public var identity: PhotoIdentity?
    /// The hash of the bytes the picker handed over, when preparing them changed them: what the message remembers, so
    /// the same original picked again is found.
    public var sourceHash: BlobHash?

    /// The length the message declares, its bytes' count from ``BluetoothFetchGate/declareSizeFloor`` up and `nil` below
    /// it, so an Android receiver's "Ask before large Bluetooth downloads" can hold a large one (knit-next ADR 2026-10.js2p,
    /// `MeshManager.kt:1452-1457` and `:1531-1535` at `eac3debc`). ``bytes`` are the plaintext even for a held picture:
    /// both arms of ``MeshEngine/heldPhoto(picked:)`` hand back the picture itself, never its ciphertext, and
    /// ``MeshEngine/sealPhoto(_:at:)`` names them as the plaintext's hash, so this is Android's `Ingested.sizeBytes`.
    var declaredSize: Int64? {
        let size = Int64(bytes.count)
        return BluetoothFetchGate.declaresSize(size) ? size : nil
    }

    /// An attachment of type `mime`.
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
