import KnitWire

/// The friendly name for a node id, such as `OptimallyArtfulFox` (`Alias.kt`).
///
/// SHA-256 of `"knit-alias-v2:" + nodeId` is 32 bytes, and each byte is a whole index into one of three
/// frozen 256-word lists (``AliasWords``), three bytes to a token. Every device derives the same alias for the
/// same id with nothing exchanged. The first token is the alias everyone sees; ``phrase(for:count:)`` adds more
/// when two people's labels would otherwise read the same.
public enum Alias {
    /// Tokens the digest carries: 32 bytes at three per token.
    public static let maxTokens = 10

    private static let salt = "knit-alias-v2:"
    /// One word from each list makes a token, in this order.
    private static let lists = [AliasWords.adverbs, AliasWords.adjectives, AliasWords.nouns]

    /// The alias for `nodeId`: the first token of its phrase.
    public static func alias(for nodeId: String) -> String {
        tokens(for: nodeId, count: 1).joined()
    }

    /// The first `count` tokens of `nodeId`'s phrase, separated by spaces. Each phrase is a prefix of the next.
    public static func phrase(for nodeId: String, count: Int) -> String {
        tokens(for: nodeId, count: count).joined(separator: " ")
    }

    /// The first `count` tokens, 1 to ``maxTokens``. Token `t` is adverb `d[3t]`, adjective `d[3t + 1]` and noun
    /// `d[3t + 2]` over the digest `d`.
    public static func tokens(for nodeId: String, count: Int = maxTokens) -> [String] {
        precondition((1...maxTokens).contains(count), "an alias phrase has 1 to \(maxTokens) tokens")
        let digest = sha256(salt + nodeId).map(Int.init)
        return (0..<count)
            .map { token in
                let start = token * lists.count
                return zip(lists, digest[start..<(start + lists.count)]).map { list, index in list[index] }.joined()
            }
    }

    /// knit-next's `displayNameFor`: the stored profile name, or the alias when the name is missing or blank.
    public static func displayName(stored name: String?, nodeId: String) -> String {
        guard let name, !TextLimits.isBlank(name) else {
            return alias(for: nodeId)
        }
        return name
    }
}
