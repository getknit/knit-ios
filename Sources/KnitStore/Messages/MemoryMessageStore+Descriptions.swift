import KnitSync
public import KnitWire

// What this phone reads from an attachment's own bytes, a photo's size and a voice note's length and waveform, apart from
// the class only to keep its body inside the lint's length.
extension MemoryMessageStore {
    /// What the messages carry whose size this phone has not read, each blob once (``MessageStore/unsizedAttachments(named:)``).
    public func unsizedAttachments(named hash: BlobHash?) -> [MessageAttachment] {
        state.withLock { state in
            var seen = Set<BlobHash>()
            return state.rows.values.sorted { $0.order > $1.order }.compactMap(\.record.attachment)
                .filter { $0.dimensions == nil && (hash == nil || $0.hash == hash) && seen.insert($0.hash).inserted }
        }
    }

    /// Records a photo's size on every message carrying `hash` (``MessageStore/setAttachmentDimensions(_:to:)``).
    @discardableResult
    public func setAttachmentDimensions(_ hash: BlobHash, to dimensions: PhotoDimensions) -> Bool {
        state.withLock { state in
            var changed = false
            for (key, row) in state.rows where row.record.attachment?.hash == hash && row.record.attachment?.dimensions != dimensions {
                state.rows[key]?.record.attachment?.dimensions = dimensions
                changed = true
            }
            return changed
        }
    }

    /// Every message carrying a voice note with no length yet, the latest stored first
    /// (``MessageStore/undescribedVoiceNotes(named:)``). The type is tested on its UTF-8 bytes, as the SQL store's `substr`
    /// tests them and Kotlin's `startsWith` tests its code units: `String.hasPrefix` compares by grapheme, which a
    /// combining mark after the slash would fail.
    public func undescribedVoiceNotes(named hash: BlobHash?) -> [MessageAttachment] {
        state.withLock { state in
            state.rows.values.sorted { $0.order > $1.order }.compactMap(\.record.attachment)
                .filter { attachment in
                    (hash == nil || attachment.hash == hash) && attachment.voice?.durationMs == nil
                        && attachment.mime.map { $0.utf8.starts(with: Self.voicePrefix.utf8) } == true
                }
        }
    }

    /// Records a voice note's description on every message carrying `hash` (``MessageStore/setVoiceDescription(_:named:)``).
    @discardableResult
    public func setVoiceDescription(_ description: VoiceDescription, named hash: BlobHash) -> Bool {
        guard !description.isEmpty else {
            return false
        }
        return state.withLock { state in
            var changed = false
            for (key, row) in state.rows where row.record.attachment?.hash == hash && row.record.attachment?.voice != description {
                state.rows[key]?.record.attachment?.voice = description
                changed = true
            }
            return changed
        }
    }

    /// What a voice note's type starts with (`VoiceAudio.isVoice`, `VoiceAudio.kt:126` at knit-next `e63f15f4`).
    private static let voicePrefix = "audio/"
}
