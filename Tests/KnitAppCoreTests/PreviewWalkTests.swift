import KnitWire
import Testing

@testable import KnitAppCore

/// The two bounded GETs a card takes (`OkHttpPreviewFetcherTest.kt` and `OkHttpPreviewFetcherDnsTest.kt` in knit-next,
/// ADR 2026-11.hcvg): what goes out, the hand-walked redirects, the caps, the picture's type, and the address rules on
/// every hop.
@Suite struct PreviewWalkTests {
    private static let page = "https://example.com/story"
    private static let picture = "https://cdn.example.com/a.jpg"
    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 60)
    private static let html: [String: String] = ["Content-Type": "text/html; charset=utf-8"]

    private func walk(_ transport: ScriptedTransport, resolver: TableResolver = TableResolver()) -> PreviewWalk {
        PreviewWalk(transport: transport, resolver: resolver)
    }

    private static func ok(_ headers: [String: String], _ body: [UInt8], remote: [UInt8]? = nil) -> ScriptedTransport.HTTPReplyScript {
        .response(status: 200, headers: headers, body: body, remote: remote)
    }

    private static func redirect(to location: String?) -> ScriptedTransport.HTTPReplyScript {
        .response(status: 302, headers: location.map { ["Location": $0] } ?? [:], body: [], remote: nil)
    }

    // MARK: A page

    @Test func aPageIsFetchedWithNothingIdentifyingInTheRequest() async {
        let transport = ScriptedTransport([Self.page: Self.ok(Self.html, Array("<title>Hi</title>".utf8))])
        let fetched = await walk(transport).fetchPage(Self.page)
        #expect(fetched == .html(bytes: Array("<title>Hi</title>".utf8), contentType: "text/html", finalURL: Self.page))
        #expect(transport.requests.map(\.headers) == [["User-Agent: WhatsApp/2", "Accept: \(PreviewWalk.acceptPage)"]])
        #expect(transport.requests.first?.limit == PreviewWalk.maxPageBytes + 1)
    }

    @Test func aResponseThatIsNotHtmlIsNotAPageAndAServerErrorIsAFailure() async {
        let transport = ScriptedTransport([
            Self.page: Self.ok(["Content-Type": "application/json"], Array("{}".utf8)),
            "https://example.com/broken": .response(status: 500, headers: Self.html, body: [], remote: nil),
            "https://example.com/xhtml": Self.ok(["Content-Type": "Application/XHTML+xml"], [1]),
        ])
        #expect(await walk(transport).fetchPage(Self.page) == .notHTML)
        #expect(await walk(transport).fetchPage("https://example.com/broken") == .failed("http 500"))
        #expect(await walk(transport).fetchPage("https://example.com/xhtml") != .notHTML, "XHTML is a page, its type's case aside")
        #expect(transport.requests.map(\.read) == [false, false, true], "a body nobody takes is never read")
    }

    @Test func redirectsAreWalkedByHandUpToTheCap() async {
        let transport = ScriptedTransport()
        for hop in 0..<PreviewWalk.maxPageHops {
            transport.answer("https://example.com/\(hop)", with: Self.redirect(to: "/\(hop + 1)"))
        }
        transport.answer("https://example.com/\(PreviewWalk.maxPageHops)", with: Self.ok(Self.html, [1]))
        let fetched = await walk(transport).fetchPage("https://example.com/0")
        #expect(fetched == .html(bytes: [1], contentType: "text/html", finalURL: "https://example.com/\(PreviewWalk.maxPageHops)"))
        #expect(transport.requests.allSatisfy { $0.headers.count == 2 }, "every hop sends the same two headers, and no cookie")
        transport.answer("https://example.com/\(PreviewWalk.maxPageHops)", with: Self.redirect(to: "/end"))
        #expect(await walk(transport).fetchPage("https://example.com/0") == .tooManyRedirects)
    }

    /// Every `Location` is resolved against its hop and run through the link rules again: http is upgraded, and a port, a
    /// literal or another scheme ends the walk.
    @Test(arguments: [
        ("http://example.com/next", true),
        ("https://example.com:8443/admin", false),
        ("https://10.0.0.1/", false),
        ("ftp://example.com/", false),
        ("//other.example/next", true),
    ])
    func aHopThePolicyRefusesEndsTheWalk(location: String, follows: Bool) async {
        let transport = ScriptedTransport([
            Self.page: Self.redirect(to: location),
            "https://example.com/next": Self.ok(Self.html, [1]),
            "https://other.example/next": Self.ok(Self.html, [2]),
        ])
        let fetched = await walk(transport).fetchPage(Self.page)
        if follows {
            #expect(transport.requests.count == 2, "\(location)")
            #expect(transport.requests.last?.url.hasPrefix("https://") == true)
        } else {
            #expect(fetched == .tooManyRedirects, "\(location)")
            #expect(transport.requests.count == 1)
        }
    }

    @Test func aRedirectWithoutALocationIsAFailureNotALoop() async {
        let transport = ScriptedTransport([
            Self.page: Self.redirect(to: nil),
            "https://example.com/odd": Self.redirect(to: "https://exa mple.com/"),
        ])
        #expect(await walk(transport).fetchPage(Self.page) == .failed("redirect without location"))
        #expect(await walk(transport).fetchPage("https://example.com/odd") == .failed("bad redirect"), "a Location Java cannot read")
    }

    /// A success whose body never came is a failure, and an address no link rule wrote has no host to resolve.
    @Test func aSuccessWithNoBodyFailsAndAnAddressTheRulesNeverWroteHasNoHost() async {
        let transport = ScriptedTransport([Self.page: .headOnly(status: 200, headers: Self.html)])
        #expect(await walk(transport).fetchPage(Self.page) == .failed("read"))
        #expect(await walk(transport).fetchPage("http://example.com/") == .failed("dns"))
        #expect(await walk(transport).fetchPage("https://") == .failed("dns"))
        #expect(transport.requests.count == 1)
    }

    @Test func aLongPageIsCutAtTheCap() async {
        let long = [UInt8](repeating: 0x61, count: PreviewWalk.maxPageBytes + 100)
        let transport = ScriptedTransport([Self.page: Self.ok(Self.html, long)])
        guard case .html(let bytes, _, _) = await walk(transport).fetchPage(Self.page) else {
            Issue.record("no page")
            return
        }
        #expect(bytes.count == PreviewWalk.maxPageBytes)
    }

    // MARK: A picture

    @Test func anImageOverTheCapIsRefusedByItsLengthBeforeReadingAndByCountWithout() async {
        let big = Self.jpeg + [UInt8](repeating: 0, count: PreviewWalk.maxImageBytes)
        let transport = ScriptedTransport([
            Self.picture: Self.ok(["Content-Type": "image/jpeg", "Content-Length": "\(big.count)"], big),
            "https://cdn.example.com/b.jpg": Self.ok(["Content-Type": "image/jpeg"], big),
            "https://cdn.example.com/c.jpg": Self.ok(["Content-Type": "image/jpeg"], Self.jpeg),
        ])
        #expect(await walk(transport).fetchImage(Self.picture) == .tooLarge)
        #expect(transport.requests.last?.read == false, "refused by its header, unread")
        #expect(await walk(transport).fetchImage("https://cdn.example.com/b.jpg") == .tooLarge)
        #expect(transport.requests.last?.limit == PreviewWalk.maxImageBytes + 1)
        #expect(await walk(transport).fetchImage("https://cdn.example.com/c.jpg") == .image(Self.jpeg, contentType: "image/jpeg"))
        #expect(transport.requests.last?.headers.last == "Accept: \(PreviewWalk.acceptImage)")
    }

    @Test func aPictureMustBeATypeTheCardDrawsAndSniffAsOne() async {
        let webP = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8 ".utf8)
        let transport = ScriptedTransport([
            "https://cdn.example.com/svg": Self.ok(["Content-Type": "image/svg+xml"], Array("<svg/>".utf8)),
            "https://cdn.example.com/text": Self.ok(["Content-Type": "text/plain"], Self.jpeg),
            "https://cdn.example.com/lies": Self.ok(["Content-Type": "image/png"], Array("<html>".utf8)),
            "https://cdn.example.com/webp": Self.ok(["Content-Type": "image/webp"], webP),
        ])
        #expect(await walk(transport).fetchImage("https://cdn.example.com/svg") == .notImage)
        #expect(await walk(transport).fetchImage("https://cdn.example.com/text") == .notImage)
        #expect(await walk(transport).fetchImage("https://cdn.example.com/lies") == .notImage)
        #expect(await walk(transport).fetchImage("https://cdn.example.com/webp") == .image(webP, contentType: "image/webp"))
    }

    @Test func aPictureRedirectedPastItsShorterCapFailsAndAMissingOneFails() async {
        let transport = ScriptedTransport()
        for hop in 0...PreviewWalk.maxImageHops {
            transport.answer("https://cdn.example.com/\(hop)", with: Self.redirect(to: "/\(hop + 1)"))
        }
        #expect(await walk(transport).fetchImage("https://cdn.example.com/0") == .failed("redirects"))
        #expect(await walk(transport).fetchImage("https://cdn.example.com/missing") == .failed("http 404"))
    }

    /// Signatures and the type each sniffs as, of the four a card draws.
    private static let signatures: [(bytes: [UInt8], type: String?)] = [
        ([0xFF, 0xD8, 0xFF, 0xDB], "image/jpeg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
        (Array("GIF87a".utf8), "image/gif"),
        (Array("GIF89a".utf8), "image/gif"),
        (Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBP".utf8), "image/webp"),
        (Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WAVE".utf8), nil),
        (Array("BM12".utf8), nil),
        ([0xFF, 0xD8, 0xFF], nil),
        ([], nil),
    ]

    @Test(arguments: signatures)
    func picturesSniffAsAndroidSniffsThem(bytes: [UInt8], type: String?) {
        #expect(PreviewWalk.renderedType(of: bytes) == type)
    }

    // MARK: Failures

    @Test(arguments: [
        (HTTPFailure.timeout, PageFetch.failed("timeout")),
        (.cancelled, .transient),
        (.offline, .offline),
        (.unresolved, .failed("dns")),
        (.other("TLS"), .failed("TLS")),
    ])
    func aFailureSaysWhatItWas(failure: HTTPFailure, fetched: PageFetch) async {
        let transport = ScriptedTransport([Self.page: .failed(failure)])
        #expect(await walk(transport).fetchPage(Self.page) == fetched)
    }

    @Test(arguments: [
        (HTTPFailure.timeout, ImageFetch.failed("timeout")),
        (.cancelled, .transient),
        (.offline, .offline),
    ])
    func aPicturesFailureSaysWhatItWas(failure: HTTPFailure, fetched: ImageFetch) async {
        let transport = ScriptedTransport([Self.picture: .failed(failure)])
        #expect(await walk(transport).fetchImage(Self.picture) == fetched)
    }

    // MARK: Addresses

    /// A name is refused whole when any address it resolves to is not public, or it resolves to none, before a request
    /// goes to it, on the first hop or any later one.
    @Test func aNameWithOnePrivateAddressIsRefusedBeforeAnyRequest() async {
        let resolver = TableResolver(table: [
            "mixed.example": [TableResolver.publicAddress, [192, 168, 1, 1]],
            "nowhere.example": [],
            "inside.example": [[0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1]],
        ])
        let transport = ScriptedTransport([Self.page: Self.redirect(to: "https://inside.example/")])
        #expect(await walk(transport, resolver: resolver).fetchPage("https://mixed.example/") == .failed("dns"))
        #expect(await walk(transport, resolver: resolver).fetchPage("https://nowhere.example/") == .failed("dns"))
        #expect(transport.requests.isEmpty)
        #expect(await walk(transport, resolver: resolver).fetchPage(Self.page) == .failed("dns"))
        #expect(transport.requests.map(\.url) == [Self.page], "the redirect's host is refused before its request")
        #expect(await walk(transport, resolver: resolver).fetchImage("https://mixed.example/a.jpg") == .failed("dns"))
    }

    /// The address the transport connected to is judged again: a name that answered differently the second time leaves
    /// its response unread by any card.
    @Test func aResponseFromAnAddressThatIsNotPublicIsThrownAway() async {
        let transport = ScriptedTransport([
            Self.page: Self.ok(Self.html, [1], remote: [10, 0, 0, 7]),
            "https://example.com/known": Self.ok(Self.html, [2], remote: TableResolver.publicAddress),
            "https://example.com/unknown": Self.ok(Self.html, [3], remote: nil),
            "https://example.com/hop": .response(status: 301, headers: ["Location": "/known"], body: [], remote: [127, 0, 0, 1]),
        ])
        #expect(await walk(transport).fetchPage(Self.page) == .failed("address"))
        #expect(await walk(transport).fetchPage("https://example.com/known") != .failed("address"))
        #expect(await walk(transport).fetchPage("https://example.com/unknown") != .failed("address"), "none said: the first check stands")
        #expect(await walk(transport).fetchPage("https://example.com/hop") == .failed("address"))
    }

    @Test func aHeadReadsItsTypeAndLengthAsOkHttpDoes() {
        let head = HTTPHead(status: 200, headers: ["CONTENT-TYPE": " Text/HTML ; charset=x", "Content-Length": " 12 "])
        #expect(head.mediaType == "text/html" && head.contentLength == 12)
        #expect(HTTPHead(status: 200, headers: ["Content-Type": ";x"]).mediaType == nil)
        #expect(HTTPHead(status: 200, headers: ["Content-Length": "many"]).contentLength == nil)
        #expect(HTTPHead(status: 200).mediaType == nil)
    }
}
