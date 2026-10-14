// What a thread lays over a message once it is built, apart so `ChatModel` stays inside the lint's length.
extension ChatMessage {
    /// The message with `chips` under it, unless it is a status line, which takes none.
    func reacted(_ chips: [ReactionChip]) -> Self {
        var copy = self
        copy.reactions = notice == nil ? chips : []
        return copy
    }

    /// The message with `quote` above its words, unless it is a status line, which quotes nothing.
    func quoting(_ quote: ChatQuote?) -> Self {
        var copy = self
        copy.quote = notice == nil ? quote : nil
        return copy
    }
}
