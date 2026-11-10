import KnitTestSupport
import Testing

@testable import KnitWire

/// The card container's contract (`LinkPreviewBlobTest.kt` in knit-next, every case): round trips, the additive rule,
/// and the decode boundary that keeps a sender's text and the one address a reader opens honest.
@Suite struct LinkPreviewBlobTests {
    private func card(
        url: String = "https://www.example.com/article?id=7", title: String = "An article", description: String? = "About things",
        image: [UInt8]? = Array(0..<16), imageMime: String? = "image/webp"
    ) -> LinkPreviewBlob {
        LinkPreviewBlob(url: url, title: title, description: description, image: image, imageMime: imageMime)
    }

    @Test func aFullCardRoundTripsThroughItsBytes() throws {
        let original = card()
        #expect(try #require(LinkPreviewBlob.decode(original.encoded)) == original)
    }

    @Test func aTextOnlyCardRoundTripsAndCarriesNoImageBytes() throws {
        let original = card(image: nil, imageMime: nil)
        let decoded = try #require(LinkPreviewBlob.decode(original.encoded))
        #expect(decoded == original)
        #expect(decoded.image == nil && decoded.imageMime == nil)
        #expect(original.encoded.count < card().encoded.count)
    }

    @Test func theVersionIsAlwaysOnTheWire() {
        let encoded = LinkPreviewBlob(url: "https://example.com/").encoded
        let key: [UInt8] = [0x61, UInt8(ascii: "v"), UInt8(LinkPreviewBlob.currentVersion)]
        #expect((0...(encoded.count - key.count)).contains { encoded[$0..<($0 + key.count)].elementsEqual(key) })
    }

    @Test func anUnknownFieldIsIgnoredButAnUnknownLayoutIsRefused() throws {
        func future(version: Int, extra: String?) -> [UInt8] {
            var entries: [CBOR.Entry] = [
                .init(key: .text("v"), value: CBOR(Int64(version))),
                .init(key: .text("url"), value: .text("https://example.com/")),
                .init(key: .text("title"), value: .text("T")),
            ]
            if let extra {
                entries.append(.init(key: .text("extra"), value: .text(extra)))
            }
            return CBOR.map(entries).encoded
        }
        #expect(try #require(LinkPreviewBlob.decode(future(version: 1, extra: "later"))).title == "T")
        #expect(LinkPreviewBlob.decode(future(version: 2, extra: nil)) == nil)
        #expect(LinkPreviewBlob.decode(future(version: 0, extra: nil)) == nil)
    }

    @Test func oversizeOrMalformedBytesDecodeToNil() {
        #expect(LinkPreviewBlob.decode([]) == nil)
        #expect(LinkPreviewBlob.decode([UInt8](repeating: 0, count: LinkPreviewBlob.maxBytes + 1)) == nil)
        #expect(LinkPreviewBlob.decode([0x01, 0x02, 0x03]) == nil)
    }

    @Test(arguments: [
        "javascript:alert(1)", "intent://scan/#Intent;scheme=zxing;end", "https://bank.example@evil.example/", "https://exam ple.com/",
        "https:///nohost", "ftp://example.com/", "https://example.com/\u{202E}path", "",
    ])
    func onlyAPlainHttpAddressSurvivesAsTheCardsURL(bad: String) {
        #expect(!LinkPreviewBlob.isSafeHttpURL(bad))
        #expect(LinkPreviewBlob.decode(card(url: bad).encoded) == nil)
    }

    @Test(arguments: ["https://example.com/a?b=c#d", "http://example.com/", "https://xn--bcher-kva.example/"])
    func aPlainWebAddressIsSafe(url: String) {
        #expect(LinkPreviewBlob.isSafeHttpURL(url))
    }

    @Test func anImageOfTheWrongTypeOrSizeIsDroppedNotRefused() throws {
        let gif = try #require(LinkPreviewBlob.decode(card(imageMime: "image/gif").encoded))
        #expect(gif.image == nil && gif.imageMime == nil)
        #expect(gif.title == "An article")
        let big = try #require(LinkPreviewBlob.decode(card(image: [UInt8](repeating: 0, count: LinkPreviewBlob.imageMaxBytes + 1)).encoded))
        #expect(big.image == nil && big.imageMime == nil)
        #expect(try #require(LinkPreviewBlob.decode(card(image: []).encoded)).image == nil)
    }

    @Test func textIsCleanedAtTheDecodeBoundary() throws {
        let decoded = try #require(
            LinkPreviewBlob.decode(
                card(title: "  Read \u{202E}this\u{200B} now\t\tplease ", description: "line one\n\nline two   ").encoded))
        #expect(decoded.title == "Read this now please")
        #expect(decoded.description == "line one line two")
        #expect(try #require(LinkPreviewBlob.decode(card(description: " \n ").encoded)).description == nil)
    }

    @Test func textIsCappedWithoutSplittingASurrogatePair() throws {
        let long = String(repeating: "a", count: LinkPreviewBlob.titleMax + 50)
        #expect(try #require(LinkPreviewBlob.decode(card(title: long).encoded)).title.utf16.count == LinkPreviewBlob.titleMax)
        let emojiAtTheEdge = String(repeating: "b", count: LinkPreviewBlob.titleMax - 1) + "😀"
        let cut = try #require(LinkPreviewBlob.decode(card(title: emojiAtTheEdge).encoded)).title
        #expect(cut.utf16.count == LinkPreviewBlob.titleMax - 1)
        #expect(cut.unicodeScalars.last == "b")
        let longDescription = String(repeating: "c", count: LinkPreviewBlob.descriptionMax + 1)
        let description = try #require(LinkPreviewBlob.decode(card(description: longDescription).encoded)).description
        #expect(description?.utf16.count == LinkPreviewBlob.descriptionMax)
    }

    @Test func theCardIsLabelledByItsOwnHostNeverByThePage() throws {
        let decoded = try #require(LinkPreviewBlob.decode(card().encoded))
        #expect(decoded.host == "example.com")
        #expect(decoded.displayTitle == "An article")
        #expect(decoded.image != nil)
        #expect(card(title: "", image: nil, imageMime: nil).displayTitle == "example.com")
        #expect(LinkPreviewBlob.host(of: "https://XN--BCHER-KVA.example/x") == "xn--bcher-kva.example")
        #expect(LinkPreviewBlob.host(of: "not a url").isEmpty)
    }

    @Test func theModerationTextJoinsTitleAndDescriptionAndSkipsBlanks() {
        #expect(card().moderationText == "An article\nAbout things")
        #expect(card(description: nil).moderationText == "An article")
        #expect(card(title: "").moderationText == "About things")
        #expect(card(title: "", description: nil).moderationText.isEmpty)
    }

    // MARK: What this port adds

    /// A control between the words goes after the whitespace collapses, as Kotlin's order has it, so its neighbours'
    /// spaces both stay; a format character past the BMP stays, since Kotlin's per-unit filter sees two surrogates.
    @Test func cleaningKeepsKotlinsOrderAndItsUnitView() {
        #expect(LinkPreviewBlob.clean("a \u{01} b", limit: 50) == "a  b")
        #expect(LinkPreviewBlob.clean("tag\u{E0041}", limit: 50) == "tag\u{E0041}")
        #expect(LinkPreviewBlob.clean("a\u{85}b", limit: 50) == "a b")
        #expect(LinkPreviewBlob.clean("abc   def", limit: 4) == "abc")
    }

    @Test func aCardWithANullTitleIsRefusedAsKotlinxRefusesIt() {
        let nullTitle = CBOR.map([
            .init(key: .text("v"), value: CBOR(Int64(1))), .init(key: .text("url"), value: .text("https://example.com/")),
            .init(key: .text("title"), value: .null),
        ])
        #expect(LinkPreviewBlob.decode(nullTitle.encoded) == nil)
    }

    @Test func textThatIsNotUTF8RefusesTheCard() {
        var bytes = LinkPreviewBlob(url: "https://example.com/", title: "Tx").encoded
        let at = bytes.count - 1
        bytes[at] = 0xFF
        #expect(LinkPreviewBlob.decode(bytes) == nil)
    }
}

/// ``JavaURI`` against what OpenJDK 21's `java.net.URI` found in each address (`new URI(s)`, then `getScheme`,
/// `getRawUserInfo`, `getHost`), run on 2026-11-10. ART's parser is the same for all of these; it differs from the
/// desktop JDK only by taking an underscore in a host label, which ``JavaURITests/anUnderscoreIsAHostCharacterOnART()``
/// covers.
@Suite struct JavaURITests {
    struct Case: Sendable, CustomTestStringConvertible {
        let input: String
        /// `nil` where Java throws.
        let parts: Parts?
        var testDescription: String { input }
    }

    struct Parts: Sendable, Equatable {
        var scheme: String?
        var userInfo: String?
        var host: String?
    }

    static let cases: [Case] = [
        .init(input: "https://example.com/a?b=c#d", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "http://example.com/", parts: .init(scheme: "http", host: "example.com")),
        .init(input: "javascript:alert(1)", parts: .init(scheme: "javascript")),
        .init(input: "intent://scan/#Intent;scheme=zxing;end", parts: .init(scheme: "intent", host: "scan")),
        .init(input: "https://bank.example@evil.example/", parts: .init(scheme: "https", userInfo: "bank.example", host: "evil.example")),
        .init(input: "https://exam ple.com/", parts: nil),
        .init(input: "https:///nohost", parts: .init(scheme: "https")),
        .init(input: "", parts: .init()),
        .init(input: "https://b\u{FC}cher.de/", parts: .init(scheme: "https")),
        .init(input: "https://example.com/a|b", parts: nil),
        .init(input: "https://example.com/a[b]", parts: nil),
        .init(input: "https://example.com/?a[b]=1", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://example.com/a%zz", parts: nil),
        .init(input: "https://example.com/a%2Fb", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://@example.com/", parts: .init(scheme: "https", userInfo: "", host: "example.com")),
        .init(input: "https://example.com:99999999999/", parts: .init(scheme: "https")),
        .init(input: "https://example.com:8080/", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://1.2.3.4/", parts: .init(scheme: "https", host: "1.2.3.4")),
        .init(input: "https://1.2.3.400/", parts: .init(scheme: "https")),
        .init(input: "https://1.2.3.4.5/", parts: .init(scheme: "https")),
        .init(input: "https://123abc.com/", parts: .init(scheme: "https", host: "123abc.com")),
        .init(input: "https://a-.com/", parts: .init(scheme: "https")),
        .init(input: "https://-a.com/", parts: .init(scheme: "https")),
        .init(input: "https://a.b-c.com/", parts: .init(scheme: "https", host: "a.b-c.com")),
        .init(input: "https://example.com./", parts: .init(scheme: "https", host: "example.com.")),
        .init(input: "https://a.1com/", parts: .init(scheme: "https")),
        .init(input: "https://a.123/", parts: .init(scheme: "https")),
        .init(input: "https://example.com/caf\u{E9}", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://example.com/\u{A0}", parts: nil),
        .init(input: "https://example.com", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://example.com?x", parts: .init(scheme: "https", host: "example.com")),
        .init(input: "https://example.com/\"q\"", parts: nil),
        .init(input: "https://ex%41mple.com/", parts: .init(scheme: "https")),
        .init(input: "https:example.com", parts: .init(scheme: "https")),
        .init(input: "HTTPS://Example.COM/", parts: .init(scheme: "HTTPS", host: "Example.COM")),
        .init(input: "https://e.com/a#b#c", parts: nil),
        .init(input: "https://e.com/{x}", parts: nil),
        .init(input: "https://e.com/a^b", parts: nil),
        .init(input: "https://e.com/a`b", parts: nil),
        .init(input: "https://e.com/a\\b", parts: nil),
        .init(input: "https://e.com:/", parts: .init(scheme: "https", host: "e.com")),
        .init(input: "https://e.com:abc/", parts: .init(scheme: "https")),
        .init(input: "https://e.com/\u{1F600}", parts: .init(scheme: "https", host: "e.com")),
        .init(input: "1https://e.com/", parts: nil),
        .init(input: "https://u:p@e.com/", parts: .init(scheme: "https", userInfo: "u:p", host: "e.com")),
        .init(input: "//e.com/x", parts: .init(host: "e.com")),
        .init(input: "https://e.com/%", parts: nil),
        .init(input: "https://localhost/", parts: .init(scheme: "https", host: "localhost")),
        .init(input: "https://e.com/a;b=c", parts: .init(scheme: "https", host: "e.com")),
        .init(input: "https://e.com/@x", parts: .init(scheme: "https", host: "e.com")),
        .init(input: "https://e..com/", parts: .init(scheme: "https")),
        .init(input: "https://.e.com/", parts: .init(scheme: "https")),
    ]

    @Test(arguments: cases)
    func readsAsJavaReadsIt(sample: Case) {
        let parsed = JavaURI(sample.input).map { Parts(scheme: $0.scheme, userInfo: $0.userInfo, host: $0.host) }
        #expect(parsed == sample.parts)
    }

    /// ART's `parseHostname` takes `_` inside a label (`L_UNDERSCORE`, android-37.2); OpenJDK does not.
    @Test func anUnderscoreIsAHostCharacterOnART() {
        #expect(JavaURI("https://my_host.example.com/")?.host == "my_host.example.com")
        #expect(JavaURI("https://_a.com/")?.host == nil)
    }

    /// The one deviation: an IPv6 literal, which Java reads as a host, throws here (see ``JavaURI``).
    @Test func anIPv6LiteralIsRefused() {
        #expect(JavaURI("https://[::1]/") == nil)
    }
}
