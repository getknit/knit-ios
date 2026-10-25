import KnitSync
public import KnitWire

// The names a picture goes by on this phone (ADR 2026-10.f3mv), apart from the class only to keep its file inside the
// lint's length.
extension MemoryMessageStore {
    /// The most rows one look for a picture's names reads, as `SQLMessageStore` reads them.
    private static let identityLimit = 16

    /// The pictures held under a name `bytesHash` could be, best first (``MessageStore/identities(matching:)``).
    public func identities(matching bytesHash: BlobHash) -> [MessageAttachment] {
        identities { attachment in
            attachment.plainHash == bytesHash || attachment.sourceHash == bytesHash
                || (attachment.key == nil && attachment.hash == bytesHash)
        }
    }

    /// The pictures Save named by EXIF-less name `exiflessHash`, best first (``MessageStore/identities(exifless:)``).
    public func identities(exifless exiflessHash: BlobHash) -> [MessageAttachment] {
        identities { $0.exiflessHash == exiflessHash }
    }

    /// The pictures `isNamed` picks, under `identityFor`'s guard and in its order: a moving one first, then a room
    /// post's, then the earliest, at most ``identityLimit``.
    private func identities(where isNamed: (MessageAttachment) -> Bool) -> [MessageAttachment] {
        state.withLock { state in
            let named = state.rows.values.map(\.record).filter { record in
                guard let attachment = record.attachment, attachment.mime != nil else {
                    return false
                }
                // A sealed row that does not know its plaintext names nothing (`identityFor`'s guard).
                guard attachment.key == nil || attachment.plainHash != nil else {
                    return false
                }
                return isNamed(attachment)
            }
            return named.sorted { lhs, rhs in
                let lhsMoves = lhs.attachment?.dimensions?.animated == true
                let rhsMoves = rhs.attachment?.dimensions?.animated == true
                if lhsMoves != rhsMoves {
                    return lhsMoves
                }
                let lhsSealed = lhs.attachment?.key != nil
                let rhsSealed = rhs.attachment?.key != nil
                if lhsSealed != rhsSealed {
                    return !lhsSealed
                }
                return Self.precedes(lhs, rhs)
            }
            .prefix(Self.identityLimit)
            .compactMap(\.attachment)
        }
    }

    /// The messages carrying a sealed copy of plaintext `plainHash` (``MessageStore/sealedCopies(of:)``).
    public func sealedCopies(of plainHash: BlobHash) -> [MessageRecord] {
        state.withLock { state in
            state.rows.values.map(\.record)
                .filter { $0.attachment?.key != nil && $0.attachment?.mime != nil && $0.attachment?.plainHash == plainHash }
                .sorted(by: Self.precedes)
        }
    }

    /// The key of a sealed message carrying `hash` with no plaintext name (``MessageStore/keyWantingPlainHash(_:)``).
    public func keyWantingPlainHash(_ hash: BlobHash) -> String? {
        state.withLock { state in
            state.rows.values.lazy.compactMap(\.record.attachment)
                .first { $0.hash == hash && $0.key != nil && $0.plainHash == nil }?.key
        }
    }

    /// Names the plaintext of sealed blob `hash` (``MessageStore/setAttachmentPlainHash(_:to:)``).
    @discardableResult
    public func setAttachmentPlainHash(_ hash: BlobHash, to plainHash: BlobHash) -> Bool {
        state.withLock { state in
            var changed = false
            for (key, row) in state.rows
            where row.record.attachment?.hash == hash && row.record.attachment?.key != nil && row.record.attachment?.plainHash == nil {
                state.rows[key]?.record.attachment?.plainHash = plainHash
                changed = true
            }
            return changed
        }
    }

    /// Names the EXIF-less JPEG in blob `hash` under `key` (``MessageStore/setAttachmentExiflessHash(_:key:to:)``). The key
    /// is compared by its bytes, as the SQL store compares it.
    @discardableResult
    public func setAttachmentExiflessHash(_ hash: BlobHash, key: String?, to exiflessHash: BlobHash) -> Bool {
        let opened = key.map(ExactKey.init)
        return state.withLock { state in
            var changed = false
            for (rowKey, row) in state.rows {
                guard let attachment = row.record.attachment, attachment.hash == hash, attachment.key.map(ExactKey.init) == opened,
                    attachment.exiflessHash != exiflessHash
                else {
                    continue
                }
                state.rows[rowKey]?.record.attachment?.exiflessHash = exiflessHash
                changed = true
            }
            return changed
        }
    }
}
