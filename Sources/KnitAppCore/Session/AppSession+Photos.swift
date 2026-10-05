import KnitCrypto
import KnitMesh
import KnitStore
public import KnitWire

// A session's photos: their bytes, which the app decodes off the main actor, and their sizes, which it keeps on their
// messages so a thread holds each photo's place at its shape from its first frame (ADR 2026-10.6cas).
extension AppSession {
    /// How many photos are read before their sizes are stored and the threads redraw: a launch reading hundreds shows
    /// the latest threads' sizes first.
    private static let photosPerRead = 64

    /// The bytes of a photo the blob store holds, or `nil`. It reads the disk, so the app calls it off the main actor,
    /// as it decodes the photo.
    nonisolated public func photo(_ hash: BlobHash) -> [UInt8]? {
        stores.blobs.bytes(of: hash)
    }

    /// The bytes of a message's photo, off the main actor like ``photo(_:)``: the blob as it is for the room's, or
    /// opened in memory with `key` for a DM's or a group's, whose blob is sealed (`AttachmentCrypto`). `nil` while the
    /// blob is missing, or when the key does not open it.
    nonisolated public func attachment(_ hash: BlobHash, key: String?) -> [UInt8]? {
        let blob = stores.blobs.bytes(of: hash)
        guard let key else {
            return blob
        }
        return blob.flatMap { sealed in Base64.decode(key).flatMap { AttachmentCrypto.open(sealed, key: $0) } }
    }

    /// Reads the size of each photo in `attachments` whose bytes are here, off the main actor, and stores it on every
    /// message that carries the photo. Bytes that are missing, or are no photo, leave it unread.
    func measure(_ attachments: [MessageAttachment]) async {
        guard let photoDimensions else {
            return
        }
        let photos = attachments.filter { AttachmentKind($0) == .photo }
        for start in stride(from: 0, to: photos.count, by: Self.photosPerRead) {
            let read = photos[start..<min(start + Self.photosPerRead, photos.count)]
            var stored = false
            for size in await Self.dimensions(of: Array(read), in: self, reading: photoDimensions)
            where stores.messages.setAttachmentDimensions(size.hash, to: size.dimensions) {
                stored = true
            }
            if stored {
                revision += 1
            }
        }
    }

    @concurrent
    nonisolated private static func dimensions(
        of photos: [MessageAttachment], in session: AppSession, reading: @Sendable ([UInt8]) -> PhotoDimensions?
    ) async -> [(hash: BlobHash, dimensions: PhotoDimensions)] {
        photos.compactMap { photo in
            session.attachment(photo.hash, key: photo.key).flatMap(reading).map { (photo.hash, $0) }
        }
    }
}
