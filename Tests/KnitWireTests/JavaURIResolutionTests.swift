import Testing

@testable import KnitWire

/// ``JavaURIResolution`` against `new URI(base).resolve(reference).toString()`. Where ART's `URI.java` (android-37.2)
/// and OpenJDK 21 agree, each case is what OpenJDK 21.0.13 printed on 2026-11-10. Where they differ, the case follows
/// ART, read from ART's own `URI.java` compiled and run beside the JDK's, and keeps what OpenJDK printed beside it.
@Suite struct JavaURIResolutionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let base: String
        let reference: String
        /// `nil` where Java throws.
        let resolved: String?
        /// What OpenJDK 21 printed, where it differs from ART.
        let openJDK: String?

        init(_ base: String, _ reference: String, _ resolved: String?) {
            self.base = base
            self.reference = reference
            self.resolved = resolved
            openJDK = nil
        }

        init(_ base: String, _ reference: String, art: String, openJDK: String) {
            self.base = base
            self.reference = reference
            resolved = art
            self.openJDK = openJDK
        }

        var testDescription: String { "\(reference) against \(base)" }
    }

    /// RFC 3986 §5.4's examples against its base, and the forms a page's picture takes, where ART and OpenJDK agree.
    static let agreed: [Case] = [
        .init("http://a/b/c/d;p?q", "g:h", "g:h"),
        .init("http://a/b/c/d;p?q", "g", "http://a/b/c/g"),
        .init("http://a/b/c/d;p?q", "./g", "http://a/b/c/g"),
        .init("http://a/b/c/d;p?q", "g/", "http://a/b/c/g/"),
        .init("http://a/b/c/d;p?q", "/g", "http://a/g"),
        .init("http://a/b/c/d;p?q", "//g", "http://g"),
        .init("http://a/b/c/d;p?q", "g?y", "http://a/b/c/g?y"),
        .init("http://a/b/c/d;p?q", "#s", "http://a/b/c/d;p?q#s"),
        .init("http://a/b/c/d;p?q", "g#s", "http://a/b/c/g#s"),
        .init("http://a/b/c/d;p?q", "g?y#s", "http://a/b/c/g?y#s"),
        .init("http://a/b/c/d;p?q", ";x", "http://a/b/c/;x"),
        .init("http://a/b/c/d;p?q", "g;x", "http://a/b/c/g;x"),
        .init("http://a/b/c/d;p?q", "g;x?y#s", "http://a/b/c/g;x?y#s"),
        .init("http://a/b/c/d;p?q", ".", "http://a/b/c/"),
        .init("http://a/b/c/d;p?q", "./", "http://a/b/c/"),
        .init("http://a/b/c/d;p?q", "..", "http://a/b/"),
        .init("http://a/b/c/d;p?q", "../", "http://a/b/"),
        .init("http://a/b/c/d;p?q", "../g", "http://a/b/g"),
        .init("http://a/b/c/d;p?q", "../..", "http://a/"),
        .init("http://a/b/c/d;p?q", "../../", "http://a/"),
        .init("http://a/b/c/d;p?q", "../../g", "http://a/g"),
        .init("http://a/b/c/d;p?q", "g.", "http://a/b/c/g."),
        .init("http://a/b/c/d;p?q", ".g", "http://a/b/c/.g"),
        .init("http://a/b/c/d;p?q", "g..", "http://a/b/c/g.."),
        .init("http://a/b/c/d;p?q", "..g", "http://a/b/c/..g"),
        .init("http://a/b/c/d;p?q", "./../g", "http://a/b/g"),
        .init("http://a/b/c/d;p?q", "./g/.", "http://a/b/c/g/"),
        .init("http://a/b/c/d;p?q", "g/./h", "http://a/b/c/g/h"),
        .init("http://a/b/c/d;p?q", "g/../h", "http://a/b/c/h"),
        .init("http://a/b/c/d;p?q", "g;x=1/./y", "http://a/b/c/g;x=1/y"),
        .init("http://a/b/c/d;p?q", "g;x=1/../y", "http://a/b/c/y"),
        .init("http://a/b/c/d;p?q", "g?y/./x", "http://a/b/c/g?y/./x"),
        .init("http://a/b/c/d;p?q", "g?y/../x", "http://a/b/c/g?y/../x"),
        .init("http://a/b/c/d;p?q", "g#s/./x", "http://a/b/c/g#s/./x"),
        .init("http://a/b/c/d;p?q", "g#s/../x", "http://a/b/c/g#s/../x"),
        .init("http://a/b/c/d;p?q", "http:g", "http:g"),
        .init("http://a/b/c/d;p?q", "#", "http://a/b/c/d;p?q#"),
        .init("http://a/b/c/d;p?q", "///x", "http://a/x"),
        .init("http://a/b/c/d;p?q", "//g/h/../i", "http://g/h/../i"),
        .init("http://a/b/c/d;p?q", "g//h", "http://a/b/c/g/h"),
        .init("https://example.com/articles/one", "../img/pic.jpg", "https://example.com/img/pic.jpg"),
        .init("https://example.com/articles/one", "//cdn.example.com/p.png", "https://cdn.example.com/p.png"),
        .init("https://example.com/articles/one", "/static/a.png", "https://example.com/static/a.png"),
        .init("https://example.com/articles/one", "https://cdn.example.com/x.jpg", "https://cdn.example.com/x.jpg"),
        .init("https://example.com/articles/one", "pic.jpg?w=1&h=2", "https://example.com/articles/pic.jpg?w=1&h=2"),
        .init("https://example.com/articles/one", "HTTPS://CDN.Example.com/A/../B", "HTTPS://CDN.Example.com/A/../B"),
        .init("https://example.com/articles/one", "%7Ex.png", "https://example.com/articles/%7Ex.png"),
        .init("https://example.com/articles/one", "\u{FC}ber.png", "https://example.com/articles/\u{FC}ber.png"),
        .init("https://example.com/articles/one", "a b.png", nil),
        .init("https://example.com/articles/one", "a|b.png", nil),
        .init("https://example.com/articles/one", "%zz", nil),
        .init("https://example.com/articles/one", "data:image/png;base64,AAAA", "data:image/png;base64,AAAA"),
        .init("https://example.com/articles/one", "javascript:alert(1)", "javascript:alert(1)"),
        .init("https://example.com/articles/one", "http://cdn.example.com/p.png", "http://cdn.example.com/p.png"),
        .init("https://example.com/p?q#f", "#f", "https://example.com/p?q#f"),
        .init("https://example.com/p?q#f", "#g", "https://example.com/p?q#g"),
        .init("https://example.com/p?q#f", "x", "https://example.com/x"),
        .init("https://example.com", "/img.jpg", "https://example.com/img.jpg"),
        .init("https://example.com", "?x", "https://example.com?x"),
        .init("https://example.com:0443/a/b", "c", "https://example.com:443/a/c"),
        .init("https://example.com:/a/b", "c", "https://example.com/a/c"),
        .init("https://user@example.com/a/", "c", "https://user@example.com/a/c"),
        .init("https://b\u{FC}cher.de/a/", "c", "https://b\u{FC}cher.de/a/c"),
        .init("https://1.2.3.4/a/b", "c", "https://1.2.3.4/a/c"),
        .init("mailto:a@b.c", "x", "x"),
        .init("mailto:a@b.c", "https://x.y/z", "https://x.y/z"),
        .init("a/b", "c", "a/c"),
        .init("b", "./x:y", "./x:y"),
        .init("a/b", "./x:y", "a/x:y"),
        .init("b", "./g", "g"),
        .init("./a", "b", "b"),
        .init("https://e.com/a//b/c", "../d", "https://e.com/a/d"),
        .init("https://example.com/articles/one", "//e.com", "https://e.com"),
        .init("https://exa mple.com/", "a", nil),
        .init("a", ".", ""),
        .init("", "a", "a"),
        .init("https://e.com:65536/a", "b", "https://e.com:65536/b"),
        .init("https://e.com/a", "//u@h:8/p", "https://u@h:8/p"),
        .init("https://e.com/a", "//b\u{FC}cher.de/x", "https://b\u{FC}cher.de/x"),
        .init("https://e.com/a", "//h?q", "https://h?q"),
        .init("https://e.com/a/b", "..", "https://e.com/"),
        .init("https://e.com/a:b/c", "../d:e", "https://e.com/d:e"),
        .init("https://e.com/%2E%2E/a", "b", "https://e.com/%2E%2E/b"),
        .init("https://e.com/a/b", "%2E%2E/c", "https://e.com/a/%2E%2E/c"),
        .init("https://e.com/a/b", ".../c", "https://e.com/a/.../c"),
        .init("https://e.com/a/b", "c/..", "https://e.com/a/"),
        .init("https://e.com/a/b", "c/.", "https://e.com/a/c/"),
        .init("https://e.com/./a/b", "c", "https://e.com/a/c"),
        .init("https://e.com/a/b", "c?x#y", "https://e.com/a/c?x#y"),
        .init("urn:isbn:1", "#x", "#x"),
        .init("https://e.com/a/b", "\u{1F600}.png", "https://e.com/a/\u{1F600}.png"),
        .init("https://e.com/a/b", "https:x", "https:x"),
    ]

    /// Where ART departs from OpenJDK 21 (http://b/25897693, and a base with no path), ART's answer with OpenJDK's beside it.
    static let artOnly: [Case] = [
        .init("http://a/b/c/d;p?q", "?y", art: "http://a/b/c/d;p?y", openJDK: "http://a/b/c/?y"),
        .init("http://a/b/c/d;p?q", "", art: "http://a/b/c/d;p?q", openJDK: "http://a/b/c/"),
        .init("http://a/b/c/d;p?q", "../../../g", art: "http://a/g", openJDK: "http://a/../g"),
        .init("http://a/b/c/d;p?q", "../../../../g", art: "http://a/g", openJDK: "http://a/../../g"),
        .init("http://a/b/c/d;p?q", "/./g", art: "http://a/g", openJDK: "http://a/./g"),
        .init("http://a/b/c/d;p?q", "/../g", art: "http://a/g", openJDK: "http://a/../g"),
        .init("http://a/b/c/d;p?q", "?", art: "http://a/b/c/d;p?", openJDK: "http://a/b/c/?"),
        .init("http://a/b/c/d;p?q", "/a//b/../c", art: "http://a/a/c", openJDK: "http://a/a//b/../c"),
        .init("http://a/b/c/d;p?q", "../../../g/../h", art: "http://a/h", openJDK: "http://a/../h"),
        .init("https://example.com/p?q#f", "", art: "https://example.com/p?q", openJDK: "https://example.com/"),
        .init("https://example.com", "img.jpg", art: "https://example.comimg.jpg", openJDK: "https://example.com/img.jpg"),
        .init("https://example.com", "../img.jpg", art: "https://example.comimg.jpg", openJDK: "https://example.com/../img.jpg"),
        .init("a/b", "../../c", art: "c", openJDK: "../c"),
        .init("b", "../g", art: "g", openJDK: "../g"),
        .init("https://example.com/a/", "./../../b", art: "https://example.com/b", openJDK: "https://example.com/../b"),
        .init("https://example.com/a/b", "/./c", art: "https://example.com/c", openJDK: "https://example.com/./c"),
        .init("b", "../x:y", art: "./x:y", openJDK: "../x:y"),
        .init("https://e.com/a#f", "?q#f", art: "https://e.com/a?q#f", openJDK: "https://e.com/?q#f"),
        .init("https://e.com/a/b?q#f", "", art: "https://e.com/a/b?q", openJDK: "https://e.com/a/"),
        .init("https://e.com/a/b/", "../../..", art: "https://e.com/", openJDK: "https://e.com/.."),
        .init("https://e.com/a/b", "///c//d", art: "https://e.com/c/d", openJDK: "https://e.com/c//d"),
        .init("https://e.com/a/b", "?", art: "https://e.com/a/b?", openJDK: "https://e.com/a/?"),
    ]

    @Test(arguments: agreed)
    func resolvesAsJavaResolves(sample: Case) {
        #expect(JavaURIResolution.resolve(sample.reference, against: sample.base) == sample.resolved)
    }

    @Test(arguments: artOnly)
    func resolvesAsARTWhereItDepartsFromOpenJDK(sample: Case) {
        let resolved = JavaURIResolution.resolve(sample.reference, against: sample.base)
        #expect(resolved == sample.resolved)
        #expect(resolved != sample.openJDK)
    }

    /// ``JavaURI``'s one deviation: an IPv6 literal, which both Javas resolve (`https://[::1]/x`), refuses here.
    @Test func anIPv6LiteralOnEitherSideResolvesToNothing() {
        #expect(JavaURIResolution.resolve("https://[::1]/x", against: "https://example.com/a") == nil)
        #expect(JavaURIResolution.resolve("x", against: "https://[::1]/a") == nil)
    }

    /// The parser keeps every part `resolve` and `toString` read, raw, as Java's getters `getRawAuthority`,
    /// `getPort`, `getRawPath`, `getRawQuery` and `getRawFragment` return them (ART's `URI.java`, run on 2026-11-10).
    @Test func everyPartIsKeptRaw() throws {
        let server = try #require(JavaURI("https://u@h.example:0443/p/%41?q=%42#f%43"))
        #expect(server.authority == "u@h.example:0443")
        #expect(server.userInfo == "u")
        #expect(server.host == "h.example")
        #expect(server.port == 443)
        #expect(server.path == "/p/%41")
        #expect(server.query == "q=%42")
        #expect(server.fragment == "f%43")
        #expect(server.string == "https://u@h.example:0443/p/%41?q=%42#f%43")

        // An opaque URI has no path, and keeps its fragment.
        let opaque = try #require(JavaURI("mailto:a@b.example#x"))
        #expect(opaque.path == nil)
        #expect(opaque.authority == nil)
        #expect(opaque.fragment == "x")

        // A server that fails to parse is a registry name: the authority stays, with no host, user-info or port.
        let registry = try #require(JavaURI("https://a-.com:80/"))
        #expect(registry.authority == "a-.com:80")
        #expect(registry.host == nil)
        #expect(registry.port == -1)

        // An empty authority is none, and an empty port is none.
        #expect(try #require(JavaURI("file:///a")).authority == nil)
        #expect(try #require(JavaURI("https://h.example:/")).port == -1)
        #expect(try #require(JavaURI("")).path?.isEmpty == true)
    }
}
