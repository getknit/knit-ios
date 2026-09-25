import KnitWire

/// The number two people compare to check that nobody sits between them (`SafetyNumber.kt`).
///
/// Each side hashes both identities in a fixed order, so both compute the same forty digits. The two
/// `nodeId|bundle` strings are sorted as Kotlin sorts strings, by UTF-16 code unit, and joined with a NUL.
public enum SafetyNumber {
    /// Eight groups, four digest bytes each: all of SHA-256.
    public static let groupCount = 8
    /// Each group is five decimal digits.
    public static let groupDigits = 5

    private static let bytesPerGroup = 4
    private static let modulus: UInt64 = 100_000
    private static let separator = "\u{0}"

    /// The safety number between two identities, as eight space-separated groups of five digits.
    public static func compute(selfNodeId: String, selfBundle: String, peerNodeId: String, peerBundle: String) -> String {
        let halves = ["\(selfNodeId)|\(selfBundle)", "\(peerNodeId)|\(peerBundle)"]
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        let digest = sha256(halves.joined(separator: separator))
        return (0..<groupCount)
            .map { group in
                let start = group * bytesPerGroup
                let value = digest[start..<(start + bytesPerGroup)].reduce(UInt64(0)) { $0 << UInt8.bitWidth | UInt64($1) }
                let digits = String(value % modulus)
                return String(repeating: "0", count: groupDigits - digits.count) + digits
            }
            .joined(separator: " ")
    }

    /// The safety number between our bundle and a peer's.
    public static func compute(mine: PublicKeyBundle, theirs: PublicKeyBundle) -> String {
        compute(
            selfNodeId: mine.nodeId.string,
            selfBundle: mine.encoded,
            peerNodeId: theirs.nodeId.string,
            peerBundle: theirs.encoded
        )
    }
}
