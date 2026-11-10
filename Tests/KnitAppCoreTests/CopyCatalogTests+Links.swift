import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// A message's links' strings (ADR 2026-11.w5ew), apart so the suite stays under the lint's length.
    static var linkStrings: [String] {
        [Copy.Chat.openLink("https://example.org/path")]
    }

    /// VoiceOver names each link's action by the address as the sender wrote it, so two links in one message differ.
    @Test func aLinksActionNamesItsAddress() {
        #expect(Copy.Chat.openLink("www.example.com") == "Open www.example.com")
    }
}
