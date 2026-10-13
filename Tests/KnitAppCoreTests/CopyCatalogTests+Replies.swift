import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Replies' strings (ADR 2026-10.mn29), apart so the suite stays under the lint's length.
    static var replyStrings: [String] {
        [
            Copy.Replies.reply,
            Copy.Replies.cancel,
            Copy.Replies.replying(to: "Sam", line: "North gate"),
            Copy.Replies.replying(to: "Sam", line: nil),
            Copy.Replies.quote("Sam", line: "North gate"),
            Copy.Replies.quote("Sam", line: nil),
            Copy.Replies.showOriginal,
            Copy.Replies.blockedQuote,
            Copy.Report.emailQuote("Sam", "North gate"),
        ]
    }
}
