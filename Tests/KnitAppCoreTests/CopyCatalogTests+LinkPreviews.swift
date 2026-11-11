import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// A link's preview card's strings (ADR 2026-11.hcvg), apart so the suite stays under the lint's length.
    static var linkPreviewStrings: [String] {
        [
            Copy.LinkPreviews.card(title: "A page", host: "example.com"),
            Copy.LinkPreviews.hidden,
            Copy.LinkPreviews.hiddenValue,
            Copy.LinkPreviews.show,
        ]
    }

    /// VoiceOver names a card by the page's title, then the site, as Android's TalkBack does.
    @Test func aCardIsNamedByItsTitleThenItsSite() {
        #expect(Copy.LinkPreviews.card(title: "A page", host: "example.com") == "Link preview: A page, example.com")
    }
}
