// v19 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v19: a JPEG's EXIF-less name (ADR 2026-10.f3mv, #12). `attachmentExiflessHash` is the SHA-256 of a photo's
    /// plaintext with its EXIF APP1 segments left out, which Save writes, so a saved picture that Photos gave new EXIF is
    /// still found when it is picked again. Local only, like the plaintext's name, and indexed as v12 indexes that. Every
    /// row already stored names none: a picture saved before v19 is found only once it is saved again.
    static let v19 = [
        "ALTER TABLE messages ADD COLUMN attachmentExiflessHash BLOB",
        """
        CREATE INDEX messages_attachmentExiflessHash ON messages (attachmentExiflessHash) \
        WHERE attachmentExiflessHash IS NOT NULL
        """,
    ]
}
