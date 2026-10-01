import KnitWire

/// A group's id (`Conversations.groupIdFor`, `Conversations.kt:160-173`): `g-` and the lowercase hex of the first 12
/// bytes of SHA-256 over `"knit-group-id-v1:"` and the founding members, sorted, de-duplicated and joined by commas.
///
/// The id is the hash of the founding roster, so every device, and anyone who re-creates a group with the same
/// people, reaches the same id, and nobody can add a member without changing it (ADR 2026-09.n393).
public enum GroupId {
    private static let salt = "knit-group-id-v1:"
    /// 12 bytes, 24 hex characters (`GROUP_ID_BYTES`).
    private static let byteCount = 12

    /// The id of the group whose founding members are `members`, in any order and with repeats.
    ///
    /// Kotlin sorts them into a `TreeSet`, which orders strings by their UTF-16 code units and treats two as one only
    /// when those units match. Swift's `<` and `==` on `String` do neither, so this sorts and de-duplicates by the
    /// units themselves (ADR 2026-09.jc2x).
    public static func derive(_ members: [String]) -> String {
        var seen = Set<[UInt16]>()
        let distinct = members.filter { seen.insert(Array($0.utf16)).inserted }
        let canonical = distinct.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.joined(separator: ",")
        return GroupInfo.idPrefix + Hex.encode(Array(sha256(salt + canonical).prefix(byteCount)))
    }
}
