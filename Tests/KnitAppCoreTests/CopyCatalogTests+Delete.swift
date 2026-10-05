import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Deleting's strings (ADR 2026-10.u7cq), apart so the suite stays under the lint's length.
    static var deleteStrings: [String] {
        [
            Copy.Chat.copy,
            Copy.Delete.delete,
            Copy.Delete.clear,
            Copy.Delete.messageTitle,
            Copy.Delete.messageBody,
            Copy.Delete.chatTitle,
            Copy.Delete.directBody,
            Copy.Delete.groupBody,
            Copy.Delete.roomTitle,
            Copy.Delete.roomBody,
            Copy.Delete.requestTitle,
            Copy.Delete.requestBody,
        ]
    }
}

extension AccessibilityIDTests {
    /// Deleting's identifiers (ADR 2026-10.u7cq), the iPhone's own: Android deletes from long-press menus with no tags.
    @Test func eachDeleteNamesWhatItDeletes() {
        #expect(AccessibilityID.chatRowDelete("nearby") == "contact_delete_nearby")
        #expect(AccessibilityID.chatRowDelete("abc") != AccessibilityID.chatRow("abc"))
        #expect(AccessibilityID.requestDelete("abc") == "request_delete_abc")
        #expect(AccessibilityID.chatMessageDelete == "chat_message_delete" && AccessibilityID.chatMessageCopy == "chat_message_copy")
    }
}
