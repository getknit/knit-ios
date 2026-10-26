import Foundation
import GRDB
public import KnitStore
public import KnitWire

// What this phone reads from an attachment's own bytes, a photo's size (schema v10) and a voice note's length and
// waveform (schema v20), apart from the class only to keep its body inside the lint's length.
extension SQLMessageStore {
    /// What the messages carry whose size this phone has not read, each blob once (``MessageStore/unsizedAttachments(named:)``).
    public func unsizedAttachments(named hash: BlobHash?) -> [MessageAttachment] {
        let named = hash.map { _ in "AND attachmentHash = ?" } ?? ""
        return database.read(or: []) { db in
            var seen = Set<BlobHash>()
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.attachmentColumns)
                    FROM messages
                    WHERE attachmentHash IS NOT NULL AND (attachmentWidth IS NULL OR attachmentAnimated IS NULL) \(named)
                    ORDER BY seq DESC
                    """,
                arguments: StatementArguments(hash.map { [StoredText.bytes($0.string)] } ?? [])
            ).compactMap(Self.attachment).filter { seen.insert($0.hash).inserted }
        }
    }

    /// Records a photo's size on every message carrying `hash` (``MessageStore/setAttachmentDimensions(_:to:)``).
    @discardableResult
    public func setAttachmentDimensions(_ hash: BlobHash, to dimensions: PhotoDimensions) -> Bool {
        database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET attachmentWidth = ?, attachmentHeight = ?, attachmentAnimated = ?
                    WHERE attachmentHash = ?
                        AND (attachmentWidth IS NOT ? OR attachmentHeight IS NOT ? OR attachmentAnimated IS NOT ?)
                    """,
                arguments: [
                    dimensions.width, dimensions.height, dimensions.animated, StoredText.bytes(hash.string), dimensions.width,
                    dimensions.height, dimensions.animated,
                ]
            )
            return db.changesCount > 0
        }
    }

    /// Every message carrying a voice note with no length yet, the latest stored first
    /// (``MessageStore/undescribedVoiceNotes(named:)``).
    ///
    /// The type is tested on its bytes, not with `LIKE`, which folds ASCII case where Kotlin's `startsWith` does not
    /// (`VoiceAudio.kt:126` at knit-next `e63f15f4`): `attachmentMime` is a UTF-8 `BLOB` (``StoredText``), `substr` of a
    /// `BLOB` counts bytes and answers a `BLOB`, and the cast is `audio/`'s UTF-8, so the `=` is a `memcmp`. The prefix is
    /// written into the SQL rather than bound, as it never varies. There is no limit, so a note that never gets described
    /// cannot hide one that would (design pass 2026-10-26, blocking 2), and no index: blob `hash`'s rows seek
    /// `messages_attachmentHash`, and a launch's read walks `seq` once, as ``unsizedAttachments(named:)`` does.
    public func undescribedVoiceNotes(named hash: BlobHash?) -> [MessageAttachment] {
        let named = hash.map { _ in "AND attachmentHash = ?" } ?? ""
        return database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.attachmentColumns)
                    FROM messages
                    WHERE attachmentHash IS NOT NULL AND voiceDurationMs IS NULL
                        AND substr(attachmentMime, 1, 6) = CAST('audio/' AS BLOB) \(named)
                    ORDER BY seq DESC
                    """,
                arguments: StatementArguments(hash.map { [StoredText.bytes($0.string)] } ?? [])
            ).compactMap(Self.attachment)
        }
    }

    /// Records a voice note's description on every message carrying `hash` (``MessageStore/setVoiceDescription(_:named:)``):
    /// both columns as given, so a duration alone clears a waveform, as `setVoiceMeta` does, and only on a row where either
    /// differs, so the same description again changes nothing.
    @discardableResult
    public func setVoiceDescription(_ description: VoiceDescription, named hash: BlobHash) -> Bool {
        guard !description.isEmpty else {
            return false
        }
        let peaks = description.peaks.map { Data($0) }
        return database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET voiceDurationMs = ?, voicePeaks = ?
                    WHERE attachmentHash = ? AND (voiceDurationMs IS NOT ? OR voicePeaks IS NOT ?)
                    """,
                arguments: [description.durationMs, peaks, StoredText.bytes(hash.string), description.durationMs, peaks]
            )
            return db.changesCount > 0
        }
    }

    /// The description a row holds, or `nil` when it holds neither half. It never throws: one row that failed would fail
    /// ``record(_:)``, and `read(or: [])` would then answer a whole thread, the thread heads or a key's queue as empty.
    /// So a value of any other type reads as missing, as does an empty waveform, and the waveform's length is not checked.
    static func voice(_ row: Row) -> VoiceDescription? {
        let durationValue: DatabaseValue = row["voiceDurationMs"]
        let peaksValue: DatabaseValue = row["voicePeaks"]
        var durationMs: Int?
        if case .int64(let stored) = durationValue.storage {
            durationMs = Int(exactly: stored)
        }
        var peaks: [UInt8]?
        if case .blob(let stored) = peaksValue.storage {
            peaks = [UInt8](stored)
        }
        let description = VoiceDescription(durationMs: durationMs, peaks: peaks)
        return description.isEmpty ? nil : description
    }
}
