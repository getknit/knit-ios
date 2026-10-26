// v23 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v23: a voice note's length in milliseconds and its waveform, read from its bytes on this phone (knit-next
    /// ADR 034, `MessageEntity.voiceDurationMs` and `voicePeaks`, its database v5 at `KnitMigrations.kt:139-151`). Local
    /// only, like a photo's size. Android keeps the waveform as base64 text; here it is the bytes, normally 64. No index:
    /// one note's rows seek `messages_attachmentHash`, and a launch's look walks `seq` once. Every row already stored reads
    /// no description, which a launch reads again.
    static let v23 = [
        "ALTER TABLE messages ADD COLUMN voiceDurationMs INTEGER",
        "ALTER TABLE messages ADD COLUMN voicePeaks BLOB",
    ]
}
