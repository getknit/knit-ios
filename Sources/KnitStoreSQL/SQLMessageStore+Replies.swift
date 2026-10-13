import GRDB
import KnitStore

extension SQLMessageStore {
    /// The quote a row's reply carries, or `nil` when it replies to nothing: a row is a reply when `replyToId` is set
    /// (schema v13, ADR 2026-10.mn29). A missing name or snippet reads as empty, as `MessageEntity.replyRef()` reads one.
    static func reply(_ row: Row) throws -> MessageReply? {
        try row.optionalText("replyToId").map { id in
            MessageReply(
                messageId: id,
                authorId: try row.optionalText("replyToAuthorId") ?? "",
                author: try row.optionalText("replyToAuthor") ?? "",
                snippet: try row.optionalText("replyToSnippet") ?? "",
                hasAttachment: try row.decode(Bool.self, forColumn: "replyToHasAttachment")
            )
        }
    }
}
