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
        let prepared = await codec.chatPhoto(from: data)
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

    /// `photo` with the hash of its bytes, taken off the main actor, since a GIF may weigh megabytes.
    @concurrent
    private static func stage(_ photo: OutgoingPhoto) async -> StagedPhoto {
        StagedPhoto(photo: photo, hash: BlobHash(of: photo.bytes))
    }
}
