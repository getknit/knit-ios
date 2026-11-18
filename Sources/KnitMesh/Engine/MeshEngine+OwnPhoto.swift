import KnitCrypto
import KnitStore
public import KnitWire

/// Our own photo: set, published and pushed to each neighbour (`MeshManager.sendAvatarIfNeeded` and
/// `ProfileViewModel.saveAvatar` in knit-next; ADR 2026-10.nh55).
extension MeshEngine {
    /// The type our photo is stored and pushed as (`AVATAR_MIME`, `MeshManager.kt:3248`).
    static let avatarMime = "image/jpeg"

    /// Sets our photo, or clears it with `nil`, and floods the profile that names it (`ProfileViewModel.saveAvatar`,
    /// then `MeshManager.broadcastProfile`). The bytes go into the blob store under their hash, the version and the
    /// publish stamp move as for any edit, and the photo goes to every neighbour after the profile. The photo it
    /// replaces goes once nothing names it.
    ///
    /// With the ratchet's switch on, our sealed profile goes to our confirmed sessions only once the push is queued on
    /// every link, as Kotlin's `broadcastProfile` pushes before `watchProfileChanges` runs `broadcastSealedProfile`
    /// (`MeshManager.kt:2787`, `:2687-2688`, at knit-next `cbf2a487`). A link sends a file behind the frames written before
    /// it, so on a link with no file streaming each neighbour has the push's header before a sealed copy names the photo's
    /// hash in the clear, which an Android carrier would otherwise want and query for while our push sat queued
    /// (`InboundPipeline.onCarriedFrame`). Behind a file already streaming, the push waits for that file's END while the
    /// sealed copy goes between its chunks, as on Android, and the carrier's query is answered SENDING from the queue.
    ///
    /// A profile the store cannot read now is no profile to edit (``publishEdit(_:)``): the photo is dropped, logged, before
    /// its bytes go in, so no blob is left that nothing names, nothing is pushed or sealed, and the photo it would replace
    /// stays. The one read names both the photo replaced and the profile edited.
    public func setAvatar(_ jpeg: [UInt8]?) {
        guard let own = stores.ownProfile.loadIfReadable() else {
            log.log(.warning, "mesh left our photo as it was: our profile could not be read")
            return
        }
        let hash = jpeg.map { BlobHash(of: $0) }
        let replaced = own.avatarHash
        guard hash != replaced else {
            return
        }
        if let jpeg, let hash {
            stores.blobs.insert(jpeg, hash: hash, mime: Self.avatarMime, storedAt: clock.wallMilliseconds())
        }
        publishEdit(of: own) { $0.avatarHash = hash }
        for peer in neighborIds {
            pushAvatar(to: peer)
        }
        broadcastSealedProfile()
        if let replaced {
            releaseBlob(replaced)
        }
    }

    /// Pushes our photo to a neighbour (`MeshManager.sendAvatarIfNeeded`): once per neighbour per photo, as kind
    /// AVATAR. Android counts a push the moment it hands it over and never tries again. Here it counts once its END
    /// is out (``fileSent(_:to:)``), so a link that died mid-push pushes again at the next link-up.
    func pushAvatar(to peer: NodeId) {
        guard let hash = stores.ownProfile.load().avatarHash, avatarPushes[peer] != hash,
            let file = outboundFile(hash, kind: .avatar, from: nil)
        else {
            return
        }
        _ = transport.sendFile(file, to: peer)
    }

    /// A file we streamed left the radio whole.
    public func fileSent(_ hash: BlobHash, to peer: NodeId) {
        if hash == stores.ownProfile.load().avatarHash {
            avatarPushes[peer] = hash
        }
    }
}
