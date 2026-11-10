import Foundation
import Testing

@testable import KnitAppCore

/// Android's rule for which words are a web address (ADR 2026-11.w5ew): the `findUrls` cases of knit-next's
/// `MentionTextTest.kt:189-237`, then where ART's regex and UTF-16 offsets put a link, which those JVM tests cannot say.
@Suite struct LinkTextTests {
    /// The words each link covers in `text`.
    private func written(_ text: String) -> [String] {
        LinkText.links(in: text).map { $0.written(in: text) }
    }

    // MARK: knit-next's cases

    @Test func detectsHttpAndHttpsUrls() {
        let links = LinkText.links(in: "go http://example.com or https://example.org/path?q=1")
        #expect(links.map(\.url) == ["http://example.com", "https://example.org/path?q=1"])
    }

    @Test func reportsDisplayRangeOfMatch() throws {
        let link = try #require(LinkText.links(in: "see https://a.com now").first)
        #expect(link.range == 4..<17)
        #expect(written("see https://a.com now") == ["https://a.com"])
    }

    /// The written range stays as the sender typed it, without the scheme the tap adds.
    @Test func bareWwwLinkResolvesToHttps() {
        #expect(LinkText.links(in: "visit www.example.com").map(\.url) == ["https://www.example.com"])
        #expect(written("visit www.example.com") == ["www.example.com"])
    }

    @Test func trimsTrailingSentencePunctuation() {
        #expect(LinkText.links(in: "open https://a.com.").map(\.url) == ["https://a.com"])
        #expect(written("open https://a.com.") == ["https://a.com"])
    }

    @Test func trimsUnbalancedClosingParenButKeepsBalancedOnes() {
        let links = LinkText.links(in: "(see https://en.wikipedia.org/wiki/Mesh_(networking))")
        #expect(links.map(\.url) == ["https://en.wikipedia.org/wiki/Mesh_(networking)"])
    }

    @Test func ignoresEmailsAndPlainText() {
        #expect(LinkText.links(in: "ping me at foo@bar.com about it").isEmpty)
    }

    /// A position's card is what opens it; its `geo:` words are no link.
    @Test func aGeoUriIsNotALinkTheCardIsItsAffordance() {
        #expect(LinkText.links(in: "at geo:37.421998,-122.084000;u=12 now").isEmpty)
        #expect(LinkText.links(in: "geo:37.42,-122.08?q=37.42,-122.08(Home)").isEmpty)
    }

    // MARK: The match

    /// `(?i)` reads the prefix in any case, and the tap opens the words as written.
    @Test func thePrefixMatchesInAnyCase() {
        #expect(LinkText.links(in: "HTTPS://A.COM and WwW.b.org").map(\.url) == ["HTTPS://A.COM", "https://WwW.b.org"])
    }

    /// A prefix with nothing after it is no link, and nor is one whose words are all trimmed away.
    @Test func aPrefixAloneIsNoLink() {
        #expect(LinkText.links(in: "https:// and www. and http://").isEmpty)
        #expect(LinkText.links(in: "www.. and https://. and http://)").isEmpty)
        #expect(LinkText.links(in: "").isEmpty)
    }

    /// The regex scans from each position in turn, so a prefix inside a word starts a link where it starts.
    @Test func aPrefixInsideAWordStartsTheLinkThere() {
        #expect(written("xhttps://a.com wwww.b.com") == ["https://a.com", "www.b.com"])
    }

    /// `<` and `>` end an address, so one wrapped in angle brackets drops them.
    @Test func angleBracketsEndALink() {
        #expect(written("<https://a.com>") == ["https://a.com"])
        #expect(written("https://a.com<b>https://c.com") == ["https://a.com", "https://c.com"])
    }

    /// Each sentence ending comes off, the closing quotes included, however many there are.
    @Test func everyTrailingSentenceMarkComesOff() {
        #expect(written("“https://a.com/x”, she said") == ["https://a.com/x"])
        #expect(written("try https://a.com/x?!…") == ["https://a.com/x?!…"])
        #expect(written("try https://a.com/x?!\"'’»;:,.") == ["https://a.com/x"])
    }

    /// Each kind of bracket counts apart, and only a closing one the address does not open comes off.
    @Test func eachBracketCountsApart() {
        #expect(written("[see https://a.com/[1]]") == ["https://a.com/[1]"])
        #expect(written("{https://a.com/{x}}") == ["https://a.com/{x}"])
        #expect(written("(https://a.com/(x)])") == ["https://a.com/(x)"])
        #expect(written("https://a.com/[x)") == ["https://a.com/[x"])
        #expect(written("https://a.com/x)).") == ["https://a.com/x"])
    }

    // MARK: ART's text

    /// Whitespace is regex `\s` on ART, Unicode White_Space (ADR 2026-10.7uyt): a no-break space and U+0085 end a link,
    /// and U+001C, which Kotlin's `isWhitespace` takes but the regex does not, sits inside one.
    @Test func whitespaceIsWhatArtsRegexSays() {
        #expect(written("https://a.com\u{A0}b") == ["https://a.com"])
        #expect(written("https://a.com\u{85}b") == ["https://a.com"])
        #expect(written("https://a.com\u{3000}b") == ["https://a.com"])
        #expect(written("https://a.com\u{2028}b") == ["https://a.com"])
        #expect(written("https://a.com\u{1C}b") == ["https://a.com\u{1C}b"])
        #expect(written("https://a.com\u{180E}b") == ["https://a.com\u{180E}b"])
    }

    /// Offsets count UTF-16 code units, as Kotlin's do: an emoji before a link moves it two, and one inside it stays whole.
    @Test func offsetsCountUTF16Units() throws {
        let link = try #require(LinkText.links(in: "😀 https://a.com/😀 x").first)
        #expect(link.range == 3..<19)
        #expect(link.url == "https://a.com/😀")
    }

    // MARK: Opening

    /// Words that no longer hold a link's range name it by its address.
    @Test func aLinkPastTheWordsIsNamedByItsAddress() throws {
        let link = try #require(LinkText.links(in: "see www.a.com").first)
        #expect(link.written(in: "see") == "https://www.a.com")
    }

    /// Foundation reads what a tap opens, percent-encoding a path that is not ASCII.
    @Test func eachLinkHasATarget() throws {
        let links = LinkText.links(in: "www.example.com and https://a.com/café")
        #expect(links.map { $0.target?.host() } == ["www.example.com", "a.com"])
        let cafe = try #require(links.last?.target)
        #expect(cafe.absoluteString == "https://a.com/caf%C3%A9")
    }
}
