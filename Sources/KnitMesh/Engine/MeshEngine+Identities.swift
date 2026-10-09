import KnitCrypto
import KnitStore
import KnitWire

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
        return nil
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
