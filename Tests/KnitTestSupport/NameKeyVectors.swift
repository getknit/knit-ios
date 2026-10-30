/// knit-next's name key contract, `vectors/name-key-v1.json` (knit-next #228), copied into `Tests/Vectors/` by
/// `scripts/sync-vectors.py`: the lookalike fold and the drop ranges as literal tables, and names with the key, the
/// display blank and the cleaned name and status each must give. Every port checks its own constants and functions
/// against it.
public enum NameKeyVectors {
    /// The file's name, here and in knit-next's `vectors/`.
    public static let fileName = "name-key-v1.json"

    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// The lookalike fold, one entry per source code point.
        public let fold: [Fold]
        /// The literal drop ranges, inclusive.
        public let drop: [Range]
        /// The limits the cleaned text is cut to.
        public let limits: Limits
        /// The names.
        public let cases: [Case]
    }

    /// One fold entry: a code point written `U+0410`, and the ASCII letter it becomes.
    public struct Fold: Decodable, Sendable {
        /// The source, `U+XXXX`.
        public let from: String
        /// The ASCII letter.
        public let to: String
    }

    /// One drop range, each end written `U+XXXX`.
    public struct Range: Decodable, Sendable {
        /// The first code point.
        public let first: String
        /// The last code point.
        public let last: String
    }

    /// The UTF-16 limits, in Kotlin's names.
    public struct Limits: Decodable, Sendable {
        /// A display name's.
        public let displayName: Int
        /// A status line's.
        public let status: Int
        /// A group name's.
        public let groupName: Int
    }

    /// One name and what it must give.
    public struct Case: Decodable, Sendable {
        /// Why the case is there.
        public let label: String
        /// The name as received.
        public let input: String
        /// `NameKey.of(input)`.
        public let key: String
        /// `NameKey.isBlankName(input)`.
        public let displayBlank: Bool
        /// `TextLimits.cleanReceived(input, limits.displayName)`.
        public let cleanedName: String
        /// `TextLimits.cleanReceived(input, limits.status)`.
        public let cleanedStatus: String
    }

    /// The file, read once.
    public static let file = VectorFile.read(fileName, as: File.self)

    /// `U+XXXX` as its scalar value, or `nil` for anything else.
    public static func codePoint(_ text: String) -> UInt32? {
        guard text.hasPrefix("U+") else {
            return nil
        }
        return UInt32(text.dropFirst(2), radix: 16)
    }
}
