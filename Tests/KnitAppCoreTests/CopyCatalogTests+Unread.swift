import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Unread counts' strings (ADR 2026-10.frmj), apart so the suite stays under the lint's length.
    static var unreadStrings: [String] {
        [
            Copy.ChatList.unreadCount(1),
            Copy.ChatList.unreadCount(3),
        ]
    }

    @Test func theUnreadCountReadsInTheRightNumber() {
        #expect(Copy.ChatList.unreadCount(1) == "1 unread message")
        #expect(Copy.ChatList.unreadCount(3) == "3 unread messages")
    }
}
