import KnitWire

/// The two bounded GETs a card takes, walked hop by hop over an ``HTTPTransport`` (`OkHttpPreviewFetcher.kt` in knit-next,
/// ADR 2026-11.hcvg): every guard that makes a request toward an address somebody else typed safe is kept here, rather
/// than trusted from above.
///
/// - **No address that is not public, on any hop.** Each hop's host is resolved and refused whole when any address
///   fails ``PublicAddressPolicy``, before a request goes to it, and the address the transport connected to is judged
///   again after: one that is not public throws the response away. Android binds the resolver to the connection and
///   needs only the first check; URLSession resolves on its own, so a name that answers differently the second time
///   can draw one request to a LAN address, whose answer never reaches a card.
/// - **Redirects are walked by hand**, at most ``maxPageHops`` and ``maxImageHops``, and each `Location` is resolved
///   against the hop it came from and run through ``LinkPreviewPolicy/normalize(_:)``, which refuses a port, a literal
///   or a scheme other than https.
/// - **Bodies are read to a cap**, counted after the content coding is undone, so a compressed bomb costs at most the
///   cap. A page past ``maxPageBytes`` is cut (its tags are in the head); a picture past ``maxImageBytes`` is refused,
///   by its `Content-Length` before a byte is read, and by count.
/// - **Nothing identifying goes out:** ``userAgent``, the one Signal and Android send, so sites serve their Open Graph
///   tags to it, an `Accept`, and nothing else. The transport adds no cookie, cache or credential.
public struct PreviewWalk: PreviewFetcher {
    /// What every request says it is (`USER_AGENT`): fixed and versionless, one less thing to tell a phone apart by.
    public static let userAgent = "WhatsApp/2"
    /// The most of a page read (`MAX_HTML_BYTES`).
    public static let maxPageBytes = 524_288
    /// The most of a picture read before it is refused (`MAX_IMAGE_BYTES`).
    public static let maxImageBytes = 2_097_152
    /// The most redirects a page follows (`MAX_PAGE_HOPS`).
    public static let maxPageHops = 5
    /// The most redirects a picture follows (`MAX_IMAGE_HOPS`).
    public static let maxImageHops = 3
    /// The `Accept` a page asks with (`ACCEPT_PAGE`).
    public static let acceptPage = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"
    /// The `Accept` a picture asks with (`ACCEPT_IMAGE`).
    public static let acceptImage = "image/webp,image/jpeg,image/png,image/gif;q=0.8,*/*;q=0.1"

    /// How one walk ended.
    private enum Walk {
        case done(bytes: [UInt8], contentType: String?, url: String)
        case failed(String)
        case tooManyHops
        case wrongType
        case tooLarge
        case transient
        case offline
    }

    /// What one walk asks for: how it says what it accepts, how far it goes, and what it keeps.
    private struct Rules: Sendable {
        var accept: String
        var maxHops: Int
        var cap: Int
        /// Whether a body past the cap is refused rather than cut.
        var refusesPastCap: Bool
        var accepts: @Sendable (String?) -> Bool
    }

    private let transport: any HTTPTransport
    private let resolver: any HostResolver

    /// Walks over `transport`, resolving each hop's host with `resolver` first.
    public init(transport: any HTTPTransport, resolver: any HostResolver) {
        self.transport = transport
        self.resolver = resolver
    }

    public func fetchPage(_ url: String) async -> PageFetch {
        let rules = Rules(accept: Self.acceptPage, maxHops: Self.maxPageHops, cap: Self.maxPageBytes, refusesPastCap: false) { type in
            type.map(Self.pageTypes.contains) ?? false
        }
        switch await walk(from: url, rules, hops: 0) {
        case .done(let bytes, let contentType, let final):
            return .html(bytes: bytes, contentType: contentType, finalURL: final)
        case .failed(let reason):
            return .failed(reason)
        case .tooManyHops:
            return .tooManyRedirects
        case .wrongType, .tooLarge:
            return .notHTML
        case .transient:
            return .transient
        case .offline:
            return .offline
        }
    }

    public func fetchImage(_ url: String) async -> ImageFetch {
        let rules = Rules(accept: Self.acceptImage, maxHops: Self.maxImageHops, cap: Self.maxImageBytes, refusesPastCap: true) { type in
            type.map { $0.hasPrefix("image/") && $0 != Self.svg } ?? false
        }
        switch await walk(from: url, rules, hops: 0) {
        case .done(let bytes, let contentType, _):
            return Self.renderedType(of: bytes) == nil ? .notImage : .image(bytes, contentType: contentType)
        case .failed(let reason):
            return .failed(reason)
        case .tooManyHops:
            return .failed("redirects")
        case .wrongType:
            return .notImage
        case .tooLarge:
            return .tooLarge
        case .transient:
            return .transient
        case .offline:
            return .offline
        }
    }

    /// Fetches `url` under `rules`, following a redirect as the hop after `hops` before it, and reads the last body to
    /// its cap. Never throws.
    private func walk(from url: String, _ rules: Rules, hops: Int) async -> Walk {
        guard let host = Self.host(of: url), PublicAddressPolicy.allPublic(await resolver.addresses(of: host)) else {
            return .failed("dns")
        }
        let reply = await transport.get(
            url, headers: [(name: "User-Agent", value: Self.userAgent), (name: "Accept", value: rules.accept)], limit: rules.cap + 1
        ) { head in Self.reads(head, rules) }
        switch reply {
        case .failed(let failure):
            return Self.walk(failing: failure)
        case .response(let head, let body, let remote):
            if let remote, !PublicAddressPolicy.isPublic(remote) {
                return .failed("address")
            }
            guard Self.redirects.contains(head.status) else {
                return Self.ended(head, body: body, at: url, rules)
            }
            guard hops < rules.maxHops else {
                return .tooManyHops
            }
            guard let location = head.headers["location"] else {
                return .failed("redirect without location")
            }
            guard let resolved = JavaURIResolution.resolve(location, against: url) else {
                return .failed("bad redirect")
            }
            guard let next = LinkPreviewPolicy.normalize(resolved) else {
                return .tooManyHops
            }
            return await walk(from: next, rules, hops: hops + 1)
        }
    }

    /// How a walk ends at a response that is no redirect.
    private static func ended(_ head: HTTPHead, body: [UInt8]?, at url: String, _ rules: Rules) -> Walk {
        guard successes.contains(head.status) else {
            return .failed("http \(head.status)")
        }
        let type = head.mediaType
        guard rules.accepts(type) else {
            return .wrongType
        }
        if rules.refusesPastCap, (head.contentLength ?? 0) > rules.cap {
            return .tooLarge
        }
        guard let body else {
            return .failed("read")
        }
        guard body.count > rules.cap else {
            return .done(bytes: body, contentType: type, url: url)
        }
        return rules.refusesPastCap ? .tooLarge : .done(bytes: Array(body.prefix(rules.cap)), contentType: type, url: url)
    }

    /// Whether a response's body is worth reading: a success of a type the walk accepts and, for a picture, a declared
    /// length within the cap. A redirect's or a refusal's body is never read.
    private static func reads(_ head: HTTPHead, _ rules: Rules) -> Bool {
        successes.contains(head.status) && rules.accepts(head.mediaType)
            && !(rules.refusesPastCap && (head.contentLength ?? 0) > rules.cap)
    }

    private static func walk(failing failure: HTTPFailure) -> Walk {
        switch failure {
        case .offline:
            .offline
        case .unresolved:
            .failed("dns")
        case .timeout:
            .failed("timeout")
        case .cancelled:
            .transient
        case .other(let reason):
            .failed(reason)
        }
    }

    /// The host of `url`, a link ``LinkPreviewPolicy/normalize(_:)`` wrote: what follows `https://` up to the path or the
    /// query.
    private static func host(of url: String) -> String? {
        guard url.hasPrefix(httpsPrefix) else {
            return nil
        }
        let rest = url.dropFirst(httpsPrefix.count)
        let host = rest.prefix { $0 != "/" && $0 != "?" }
        return host.isEmpty ? nil : String(host)
    }

    /// The type a card's picture sniffs as, of the four a card draws, or `nil` (`FileTypes.imageMimeOf` against
    /// `RENDERED_IMAGE_MIMES`): JPEG, PNG, GIF or WebP by their first bytes.
    public static func renderedType(of bytes: [UInt8]) -> String? {
        guard bytes.count >= minSignature else {
            return nil
        }
        if bytes.starts(with: jpeg) {
            return "image/jpeg"
        }
        if bytes.starts(with: png) {
            return "image/png"
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if bytes.starts(with: Array("RIFF".utf8)), bytes.dropFirst(webpOffset).starts(with: Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }

    private static let httpsPrefix = "https://"
    private static let svg = "image/svg+xml"
    private static let pageTypes: Set<String> = ["text/html", "application/xhtml+xml"]
    /// The redirects a walk follows by hand (`REDIRECT_CODES`): 301, 302, 303, 307 and 308.
    private static let movedPermanently = 301
    private static let found = 302
    private static let seeOther = 303
    private static let temporaryRedirect = 307
    private static let permanentRedirect = 308
    private static let redirects: Set = [movedPermanently, found, seeOther, temporaryRedirect, permanentRedirect]
    private static let successes = 200..<300
    /// The fewest bytes a signature is read from (`MIN_SIGNATURE`).
    private static let minSignature = 4
    /// A JPEG's marker byte, and its start of image.
    private static let marker: UInt8 = 0xFF
    private static let startOfImage: UInt8 = 0xD8
    private static let jpeg = [marker, startOfImage, marker]
    private static let png = latin1("\u{89}PNG\r\n\u{1A}\n")
    /// Where `WEBP` sits in a RIFF file, after `RIFF` and the length.
    private static let webpOffset = 8

    /// `text`'s code points, each one byte.
    private static func latin1(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }
}
