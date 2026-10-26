public import Foundation
import KnitCrypto
import KnitMesh
import KnitWire

// The composer's photo: picked, made ready and held (ADR 2026-10.m4ah), apart so `ChatModel` stays under the lint's
// length.
extension ChatModel {
    /// Makes a picked photo ready to send (`AttachmentStore.ingest`) and holds it in the composer, in place of any held
    /// before. One the picker could not hand over, or the codec cannot send, says why. While a pick is being made ready
    /// another may replace it, and the last one picked is the one held.
    ///
    /// A picture this phone already holds goes as that blob, undecoded, so it keeps its frames, its quality and its
    /// identity (`AttachmentStore.ingestPicked`, ADR 2026-10.f3mv). Any other goes through the codec, and remembers the
    /// picked bytes' hash when the codec changed them, so the same original picked again is found.
    ///
    /// In the room, which floods to everyone in range, the prepared photo is checked whatever the content filter says,
    /// and one that looks explicit is refused (`ChatViewModel.stage`). A DM or a group takes it unchecked: the receiver's
    /// phone screens it (ADR 2026-10.spcy).
    public func choosePhoto(_ data: Data?) async {
        picks += 1
        let pick = picks
        guard let data, let codec else {
            preparingPhoto = false
            photoFailure = .unreadable
            return
        }
        preparingPhoto = true
        defer {
            if pick == picks {
                preparingPhoto = false
            }
        }
        let prepared: Result<OutgoingPhoto, PhotoFailure>
        if let identified = await session.heldPhoto(picked: data) {
            prepared = .success(identified)
        } else {
            prepared = await Self.prepare(data, with: codec)
        }
        guard pick == picks else {
            return
        }
        let photo: OutgoingPhoto
        switch prepared {
        case .success(let ready):
            photo = ready
        case .failure(let failure):
            photoFailure = failure
            return
        }
        if state.isRoom, await screening?.isExplicit(outgoing: photo.bytes) == true {
            if pick == picks {
                photoRefused = true
            }
            return
        }
        let held = await Self.stage(photo)
        if pick == picks {
            staged = held
        }
    }

    /// Takes the held photo out of the composer.
    public func removePhoto() {
        staged = nil
    }

    /// Whether a photo in the thread, or a voice note where this build plays them, is still on its way, so the thread
    /// samples how far it has got (``AppSession/sampleArrivals()``). The set `ChatViewModel.awaitedHashes` gates its
    /// `arrivals` on: a settled thread never samples. A voice note in the room, which never plays, shows no ring.
    public var awaitsPhotos: Bool {
        let voiceRings = voice != nil && !state.isRoom
        return state.messages.contains { message in
            message.attachment.map { !$0.isHeld && ($0.kind == .photo || voiceRings && $0.playsAsVoice) } ?? false
        }
    }

    /// Reads once how far the photos streaming in have got, and answers how long to wait before the next read
    /// (``AppSession/sampleArrivals()``). The thread loops on it while ``awaitsPhotos``.
    public func sampleArrivals() async -> Duration {
        await session.sampleArrivals()
    }

    /// `data` made ready by `codec`, remembering the picked bytes' hash when they changed, off the main actor, since a
    /// GIF may weigh megabytes.
    @concurrent
    private static func prepare(_ data: Data, with codec: any ImageCodec) async -> Result<OutgoingPhoto, PhotoFailure> {
        await codec.chatPhoto(from: data).map { ready in
            var photo = ready
            let source = BlobHash(of: [UInt8](data))
            if source != BlobHash(of: photo.bytes) {
                photo.sourceHash = source
            }
            return photo
        }
    }

    /// `photo` with the hash of its bytes, taken off the main actor, since a GIF may weigh megabytes.
    @concurrent
    private static func stage(_ photo: OutgoingPhoto) async -> StagedPhoto {
        StagedPhoto(photo: photo, hash: BlobHash(of: photo.bytes))
    }
}
