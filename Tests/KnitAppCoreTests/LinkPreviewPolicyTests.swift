import KnitCrypto
import KnitWire
import Testing

@testable import KnitAppCore

/// Which link gets a card, and the form a card's address is compared in: every case of knit-next's
/// `LinkPreviewPolicyTest.kt`, the IDN case turned into this phone's recorded limit (ADR 2026-11.hcvg).
@Suite struct LinkPreviewPolicyTests {
    @Test func anOrdinaryHttpsLinkNormalizesToItself() {
        #expect(LinkPreviewPolicy.normalize("https://example.com/path?q=1") == "https://example.com/path?q=1")
        #expect(LinkPreviewPolicy.normalize("https://example.com") == "https://example.com/")
        #expect(LinkPreviewPolicy.normalize("https://example.com:443") == "https://example.com/")
    }

    @Test func theFetchIsHttpsOnlySoATypedHttpLinkIsUpgraded() {
        #expect(LinkPreviewPolicy.normalize("http://example.com/a") == "https://example.com/a")
        #expect(LinkPreviewPolicy.normalize("HTTP://Example.COM/a") == "https://example.com/a")
    }

    @Test func theFragmentIsDroppedAndTheHostLowerCasedButThePathIsKeptAsTyped() {
        #expect(LinkPreviewPolicy.normalize("https://Example.com/Path/A?B=c#section") == "https://example.com/Path/A?B=c")
        #expect(LinkPreviewPolicy.normalize("https://example.com/#only-a-fragment") == "https://example.com/")
        #expect(LinkPreviewPolicy.normalize("https://example.com?q=1#x") == "https://example.com?q=1", "a query alone, as Kotlin keeps")
    }

    /// Android turns a host outside ASCII into punycode; this phone refuses it, so neither the fetch nor a reader's check
    /// takes it. A host already in punycode is ASCII, and kept.
    @Test func anInternationalHostIsLeftWithoutACardHere() {
        #expect(LinkPreviewPolicy.normalize("https://bücher.example/") == nil)
        #expect(LinkPreviewPolicy.normalize("https://xn--bcher-kva.example/") == "https://xn--bcher-kva.example/")
        #expect(!LinkPreviewPolicy.sameURL("https://bücher.example/", "https://xn--bcher-kva.example/"))
    }

    @Test(arguments: [
        ("https://user:pw@example.com/", "user-info"),
        ("https://example.com@evil.example/", "user-info spoofing a host"),
        ("https://example.com:8443/", "a non-standard port"),
        ("http://example.com:80/", "an explicit port other than 443"),
        ("https://10.0.0.1/", "an IPv4 literal"),
        ("https://127.0.0.1/", "loopback"),
        ("https://[::1]/", "an IPv6 literal"),
        ("https://localhost/", "a single label"),
        ("https://intranet/", "a single label"),
        ("https://printer.local/", ".local"),
        ("https://router.home.arpa/", ".home.arpa"),
        ("https://x.localhost/", ".localhost"),
        ("https://db.internal/", ".internal"),
        ("https://host.lan/", ".lan"),
        ("https://abc.onion/", ".onion"),
        ("https://onion/", "a bare suffix"),
        ("ftp://example.com/", "a non-http scheme"),
        ("javascript:alert(1)", "a script scheme"),
        ("https://exam ple.com/", "whitespace"),
        ("https://example.com/a\u{85}", "ART's NEL, which Kotlin's trim leaves"),
        ("https://example.com/\u{A0}b", "a no-break space inside"),
        ("https://example.com/" + String(repeating: "a", count: 2100), "an over-long URL"),
        ("", "nothing"),
        ("https://", "no authority"),
        ("https:///path", "an empty authority"),
        ("https://a..com/", "an empty label"),
        ("https://" + String(repeating: "a", count: 64) + ".com/", "a label past 63"),
        ("https://exa_mple.com/", "an underscore"),
        ("https://:443/", "a port and no host"),
        ("https://example.com:443:1/", "two colons"),
    ])
    func everyShapeThatCouldPointTheSocketSomewhereElseIsRefused(url: String, why: String) {
        #expect(LinkPreviewPolicy.normalize(url) == nil, "\(why)")
    }

    /// Kotlin's `trim()` comes first, so whitespace around the address is no reason to refuse it, and an empty port is
    /// none.
    @Test func trimmedEndsAndAnEmptyPortAreKept() {
        #expect(LinkPreviewPolicy.normalize("  https://example.com/a\n") == "https://example.com/a")
        #expect(LinkPreviewPolicy.normalize("https://example.com:/a") == "https://example.com/a")
    }

    @Test func aContactLinkIsACardOfItsOwnNotAPage() {
        let card = ContactCard.urlPrefix + "abc"
        #expect(ContactCard.looksLikeCard(card) || card.hasPrefix("https://getknit.app/c#"))
        #expect(LinkPreviewPolicy.normalize(card) == nil)
        #expect(LinkPreviewPolicy.firstEligible("meet me: \(card)") == nil)
    }

    @Test func theFirstEligibleLinkInABodyWinsAndTheBodyMayBeJustTheLink() {
        let body = "see https://10.0.0.1/admin and then https://example.com/one and https://example.com/two"
        #expect(LinkPreviewPolicy.firstEligible(body) == "https://example.com/one")
        #expect(LinkPreviewPolicy.firstEligible("https://example.com/") == "https://example.com/")
        #expect(LinkPreviewPolicy.firstEligible("www.example.com/x") == "https://www.example.com/x")
        #expect(LinkPreviewPolicy.firstEligible("no links here") == nil)
        #expect(LinkPreviewPolicy.firstEligible("mail me at someone@example.com") == nil)
    }

    @Test func onlyTheFirstFewLinksAreTried() {
        let refused = (1...LinkPreviewPolicy.candidates).map { "https://10.0.0.\($0)/" }.joined(separator: " ")
        #expect(LinkPreviewPolicy.firstEligible("\(refused) https://example.com/late") == nil)
    }

    @Test func sameURLIsTheReadersSpoofCheck() {
        #expect(LinkPreviewPolicy.sameURL("http://Example.com/a#x", "https://example.com/a"))
        #expect(LinkPreviewPolicy.sameURL("https://example.com", "https://example.com/"))
        #expect(!LinkPreviewPolicy.sameURL("https://example.com/a", "https://example.com/b"))
        #expect(!LinkPreviewPolicy.sameURL("https://bank.example/", "https://evil.example/"))
        #expect(!LinkPreviewPolicy.sameURL("https://10.0.0.1/", "https://10.0.0.1/"))
    }

    @Test func theDisplayHostIsDerivedFromTheLink() {
        #expect(LinkPreviewBlob.host(of: "https://www.example.com/a") == "example.com")
        #expect(LinkPreviewBlob.host(of: "https://News.Example.org/") == "news.example.org")
    }
}
