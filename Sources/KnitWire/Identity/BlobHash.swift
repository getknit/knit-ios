/// A blob's content address: the lowercase hex SHA-256 of exactly the bytes a file carries, 64 characters
/// (`mesh/BlobHash.kt` in knit-next). A FILE_HEADER's key, the photo hash in a profile, a group or a message, and a
/// `blobreq`'s hash are all one.
///
/// Every hash a peer supplies passes through ``init(_:)``, which admits only the 64-character lowercase form. Two
/// hashes are therefore equal exactly when their bytes are, so the type is safe as a key where raw wire text needs
/// ``ExactKey`` (ADR 2026-09.jc2x). Android checks the shape only of a FILE_HEADER's key (`FramedLink.kt:488`); this
/// port checks every hash it keeps, a `blobreq`'s included (ADR 2026-10.nh55).
public struct BlobHash: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The hash's length in characters: lowercase hex of a 32-byte SHA-256 digest.
    public static let length = 64
    /// A SHA-256 digest's length in bytes.
    public static let digestByteCount = 32

    /// The address of an empty blob: SHA-256 of nothing at all.
    public static let empty = Self(trusted: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    /// The 64-character text.
    public let string: String

    /// The hash for its text, if that is 64 lowercase hex characters.
    public init?(_ text: String) {
        guard text.utf8.count == Self.length, Hex.decode(text) != nil else {
            return nil
        }
        string = text
    }

    /// The hash for a 32-byte SHA-256 digest.
    public init?(digest: [UInt8]) {
        guard digest.count == Self.digestByteCount else {
            return nil
        }
        string = Hex.encode(digest)
    }

    /// The hash for a SHA-256 digest a sibling target computed, unchecked because a digest is always 32 bytes. Only
    /// `KnitCrypto`'s `init(of:)` calls it, with the digest it just took.
    package init(computedDigest digest: [UInt8]) {
        string = Hex.encode(digest)
    }

    private init(trusted text: String) {
        string = text
    }

    /// The hash's text.
    public var description: String { string }

    /// Ordered by the text's bytes, as SQLite orders it and as Kotlin compares it.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
    }
}
