/// knit-next's name screen contract, `vectors/name-screen-v1.json` (knit-next ADR 2026-11.y4pc), copied into
/// `Tests/Vectors/` by `scripts/sync-vectors.py`: names with the verdict the screen gives each over the shipped word
/// lists, and a digest of each list's terms, so a port reading other lists fails before it disagrees.
public enum NameScreenVectors {
    /// The file's name, here and in knit-next's `vectors/`.
    public static let fileName = "name-screen-v1.json"

    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// Each list's digest, by its file name in knit-next's `assets/moderation/`: SHA-256 of its terms sorted and
        /// joined with `\n`.
        public let lists: [String: String]
        /// The names.
        public let cases: [Case]
    }

    /// One name, who reads it, and what the screen finds.
    public struct Case: Decodable, Sendable {
        /// The name.
        public let name: String
        /// `PUBLIC` or `MEMBERS`.
        public let audience: String
        /// `NONE`, `SLUR` or `PROFANITY`.
        public let verdict: String
    }

    /// The file, read once.
    public static let file = VectorFile.read(fileName, as: File.self)
}
