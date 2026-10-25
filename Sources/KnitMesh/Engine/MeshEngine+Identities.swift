import KnitCrypto
import KnitStore
public import KnitWire

// A picture keeps the identity it arrived under (ADR 2026-10.f3mv, knit-next ADR 2026-10.mptm): a phone seals a given
// plaintext once. A pick this phone already holds goes out as that blob, and a key-less frame from someone who knows we
// hold the picture is shown from our own sealed copy.
extension MeshEngine {
    // MARK: Picking

    /// `picked` as the picture this phone already holds it as, ready to send under that blob's identity, or `nil` when
    /// it holds no such picture (`AttachmentStore.reused`). Asked before the app prepares a pick, so a held picture is
    /// never decoded: a forwarded GIF keeps moving and a forwarded photo loses nothing.
    ///
    /// The picked bytes are the picture itself, or our own original that preparing changed, found by the hash the send
    /// remembered; then the plaintext is opened out of the held blob. A blob that is gone, or will not open to the
    /// plaintext its message names, is no identity, and the next is tried. Android also refuses a still matched by a
    /// source that moves, a send flattened before #133; here a source is only ever remembered since moving pictures go
    /// as such.
    ///
    /// Only when nothing matches exactly is the pick looked up by its EXIF-less name (``exiflessHeldPhoto(picked:hash:)``),
    /// for a saved JPEG whose EXIF Photos rewrote on import (#12).
    public func heldPhoto(picked: [UInt8]) -> OutgoingPhoto? {
        let bytesHash = BlobHash(of: picked)
        for held in stores.messages.identities(matching: bytesHash) where stores.blobs.contains(held.hash) {
            let plainHash = held.plainHash ?? held.hash
            guard let mime = held.mime,
                let plain = bytesHash == plainHash ? picked : plaintext(of: held, named: plainHash)
            else {
                continue
            }
            log.log(.debug, "mesh picked picture held as \(held.hash)\(held.key == nil ? " (public)" : "")")
            return OutgoingPhoto(
                bytes: plain,
                mime: mime,
                identity: PhotoIdentity(hash: held.hash, key: held.key),
                sourceHash: bytesHash == plainHash ? nil : bytesHash
            )
        }
        return exiflessHeldPhoto(picked: picked, hash: bytesHash)
    }

    /// `picked`, whose SHA-256 is `bytesHash` and which matched nothing exactly, as a JPEG this phone holds that differs
    /// from it only in EXIF, or `nil` (ADR 2026-10.f3mv, #12). Photos rewrites a JPEG's EXIF APP1 when it imports one, so
    /// a picture saved from Knit comes back from the picker under another hash. Save named each row's plaintext by its
    /// EXIF-less hash (``MessageAttachment/exiflessHash``), and the rows that name the pick's are tried in
    /// ``MessageStore/identities(exifless:)``'s order.
    ///
    /// **The stored name is never trusted on its own.** Each blob is opened as the exact match opens one, and its
    /// plaintext named again: only the same EXIF-less hash and the same orientation answer, so a row whose name no
    /// longer fits, or a key-less row naming a sealed blob's hash, whose "plaintext" is ciphertext, never does. A picked
    /// orientation of 1 against a held 6 would draw a quarter turn apart, so the orientations must be equal, no tag
    /// counting as 1. A (blob, key) pair is opened once a call, though a picture forwarded into many chats has a row in
    /// each.
    ///
    /// What goes is the held plaintext, under the held identity, and `bytesHash` is remembered as its source, so the next
    /// pick of the same Photos file matches exactly. The name answers only a pick: no want, `blobreq`, re-want or copy
    /// from our own store reads it.
    private func exiflessHeldPhoto(picked: [UInt8], hash bytesHash: BlobHash) -> OutgoingPhoto? {
        guard let name = ExiflessJPEG.name(of: picked) else {
            return nil
        }
        var opened = Set<OpenedBlob>()
        for held in stores.messages.identities(exifless: name.hash) where stores.blobs.contains(held.hash) {
            guard opened.insert(OpenedBlob(hash: held.hash, key: held.key.map(ExactKey.init))).inserted, let mime = held.mime,
                let plain = plaintext(of: held, named: held.plainHash ?? held.hash), ExiflessJPEG.name(of: plain) == name
            else {
                continue
            }
            log.log(.debug, "mesh picked picture held as \(held.hash)\(held.key == nil ? " (public)" : ""), its EXIF aside")
            return OutgoingPhoto(bytes: plain, mime: mime, identity: PhotoIdentity(hash: held.hash, key: held.key), sourceHash: bytesHash)
        }
        return nil
    }

    /// A blob and the key it was opened with, by the key's bytes.
    private struct OpenedBlob: Hashable {
        let hash: BlobHash
        let key: ExactKey?
    }

    // MARK: Naming the plaintext

    /// Records the plaintext's name on the messages that carry sealed blob `hash` and lack one, opening it once, now
    /// that its bytes are here (`AttachmentIdentities.notePlain`). A blob no sealed message wants costs one read.
    func notePlainHash(_ hash: BlobHash) {
        guard let key = stores.messages.keyWantingPlainHash(hash),
            let plain = plaintext(of: MessageAttachment(hash: hash, key: key), named: nil)
        else {
            return
        }
        stores.messages.setAttachmentPlainHash(hash, to: BlobHash(of: plain))
    }

    // MARK: Copying from our own store

    /// Holds key-less blob `hash`, a picture's plaintext, from a sealed copy this phone already has, if `author`, who
    /// named it, was party to the conversation that copy came through, and answers whether it did
    /// (`InboundPipeline.copyFromOwnStore`, `MessageDao.sealedHolding`). The author is its sender, the DM's other side
    /// (who we got it from or sent it to), or a member of its group.
    ///
    /// **The author's test is load-bearing.** A copy made here is seen: this phone then serves bytes nobody saw it pull.
    /// Anyone holding a file could post it and watch which phones answer without asking, so only a frame's author who
    /// already knows we hold the picture may set it off, and only from `deliverChat`. Never from a want, a `blobreq`,
    /// which nobody signs, or a re-want, which no longer knows the author.
    func copyFromOwnStore(_ hash: BlobHash, author: NodeId) -> Bool {
        for copy in stores.messages.sealedCopies(of: hash) where Self.isParty(author, to: copy, groups: stores.groups) {
            guard let attachment = copy.attachment, let mime = attachment.mime, let plain = plaintext(of: attachment, named: hash)
            else {
                continue
            }
            stores.blobs.insert(plain, hash: hash, mime: mime, storedAt: clock.wallMilliseconds())
            return true
        }
        return false
    }

    /// Whether `author` was party to the conversation `message` came through: its sender, the other side of its DM,
    /// or a member of its group, each compared by bytes.
    static func isParty(_ author: NodeId, to message: MessageRecord, groups: any GroupStore) -> Bool {
        if message.senderId == author {
            return true
        }
        let conversation = message.conversationId
        if Conversations.isGroup(conversation) {
            return groups.group(conversation)?.member(author.string).map { !$0.departed } ?? false
        }
        return conversation != Conversations.nearby && ExactKey(conversation) == ExactKey(author.string)
    }

    /// The plaintext in held blob `attachment.hash`: the blob itself when it has no key, else the blob opened with it,
    /// and `nil` unless it hashes to `plainHash` when one is given (`AttachmentIdentities.plaintextOf`).
    private func plaintext(of attachment: MessageAttachment, named plainHash: BlobHash?) -> [UInt8]? {
        guard let blob = stores.blobs.bytes(of: attachment.hash) else {
            return nil
        }
        let plain: [UInt8]?
        if let key = attachment.key {
            plain = Base64.decode(key).flatMap { AttachmentCrypto.open(blob, key: $0) }
        } else {
            plain = blob
        }
        guard let plain, plainHash.map({ BlobHash(of: plain) == $0 }) ?? true else {
            return nil
        }
        return plain
    }
}

/// A JPEG's EXIF-less name: the SHA-256 of its bytes with the EXIF APP1 segments left out, and the orientation that EXIF
/// gave it (ADR 2026-10.f3mv, #12). Save writes the hash, and ``MeshEngine/heldPhoto(picked:)`` names both the pick and
/// each held plaintext with it, so the two can never drift. Here and not in KnitWire, which takes no hash.
extension ExiflessJPEG {
    /// What a JPEG is named by apart from its EXIF.
    public struct Name: Sendable, Equatable {
        /// The SHA-256 of ``ExiflessJPEG/kept``.
        public let hash: BlobHash
        /// The orientation its EXIF gave it, 1 without one.
        public let orientation: Int
    }

    /// The name of `plaintext`, or `nil` for anything but a JPEG ``read(_:)`` understands.
    public static func name(of plaintext: [UInt8]) -> Name? {
        read(plaintext).map { Name(hash: BlobHash(of: $0.kept), orientation: $0.orientation) }
    }
}
