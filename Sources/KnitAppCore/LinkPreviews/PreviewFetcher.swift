/// The HTTP seam under ``LinkPreviewService`` (`PreviewFetcher.kt` in knit-next, ADR 2026-11.hcvg): two bounded GETs and
/// nothing else. ``PreviewWalk`` is the one that walks the redirects and keeps the caps and the address rules;
/// everything above it runs against a fake.
public protocol PreviewFetcher: Sendable {
    /// The page at `url`, already normalized by ``LinkPreviewPolicy``, as bytes the parser can decode.
    func fetchPage(_ url: String) async -> PageFetch
    /// The picture at `url`, already normalized, as raw image bytes for the shrink.
    func fetchImage(_ url: String) async -> ImageFetch
}

/// What fetching a page produced (`PageFetch`). Only ``html(bytes:contentType:finalURL:)`` carries a body.
public enum PageFetch: Sendable, Equatable {
    /// The body cut at the cap, its `Content-Type` as `type/subtype`, and where the redirects ended.
    case html(bytes: [UInt8], contentType: String?, finalURL: String)
    /// No route to the Internet when it was asked.
    case offline
    /// The answer was no HTML document.
    case notHTML
    /// More hops than the walk follows, or a hop the policy refused.
    case tooManyRedirects
    /// A definite failure: a status that is no success, a refused address, a timeout, a TLS or protocol error.
    case failed(String)
    /// Cut short, cancelled or the route gone mid-call, which says nothing about the page.
    case transient
}

/// What fetching a picture produced (`ImageFetch`).
public enum ImageFetch: Sendable, Equatable {
    /// The picture's bytes and its `Content-Type` as `type/subtype`.
    case image([UInt8], contentType: String?)
    /// No route to the Internet when it was asked.
    case offline
    /// No picture a card draws: a wrong `Content-Type`, an SVG, or bytes that sniff as something else.
    case notImage
    /// Past the cap, by its `Content-Length` or by count.
    case tooLarge
    /// A definite failure.
    case failed(String)
    /// Cut short, which says nothing about the picture.
    case transient
}

/// One GET, the redirect not followed: the app's is URLSession, a test's a script (ADR 2026-11.hcvg). It sends exactly
/// the headers it is given, and no cookie, cache or credential of its own.
public protocol HTTPTransport: Sendable {
    /// `url` fetched with `headers`. `reads` sees the status and headers first, and says whether the body is read at all;
    /// a body read is cut at `limit` bytes, counted after any content coding is undone.
    func get(_ url: String, headers: [(name: String, value: String)], limit: Int, reads: @Sendable (HTTPHead) -> Bool) async
        -> HTTPReply
}

/// A response's status line and headers, the names lower-cased.
public struct HTTPHead: Sendable, Equatable {
    /// The status code.
    public var status: Int
    /// The headers, each name lower-cased; the first of a repeated one.
    public var headers: [String: String]

    /// A head with `status` and `headers`, whose names are lower-cased here.
    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    }

    /// The `Content-Type` as `type/subtype`, lower-cased and without its parameters, as OkHttp's `MediaType` gives it.
    public var mediaType: String? {
        headers["content-type"].map { value in
            let type = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return HeaderText.trimmed(type).lowercased()
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `Content-Length`, or `nil` when it is missing or no number.
    public var contentLength: Int? {
        headers["content-length"].flatMap { Int(HeaderText.trimmed($0)) }
    }
}

/// What one GET came back with.
public enum HTTPReply: Sendable, Equatable {
    /// A response: its head, its body when ``HTTPTransport/get(_:headers:limit:reads:)``'s `reads` asked for it (up to
    /// `limit` bytes), and the address the transport connected to, when it can tell.
    case response(HTTPHead, body: [UInt8]?, remoteAddress: [UInt8]?)
    /// No response.
    case failed(HTTPFailure)
}

/// Why a GET came back with no response.
public enum HTTPFailure: Sendable, Equatable {
    /// No route to the Internet.
    case offline
    /// The host did not resolve.
    case unresolved
    /// It took too long.
    case timeout
    /// It was cancelled from outside.
    case cancelled
    /// Anything else, named for the log.
    case other(String)
}

/// What a host name resolves to, raw address bytes, before a request goes to it: the app's is `getaddrinfo`.
public protocol HostResolver: Sendable {
    /// The addresses `host` resolves to, 4 or 16 bytes each; empty when it resolves to none.
    func addresses(of host: String) async -> [[UInt8]]
}

/// A header value's trimming: spaces and tabs, the only whitespace HTTP allows around one.
internal enum HeaderText {
    /// `text` with spaces and tabs off both ends.
    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0 != " " && $0 != "\t" }),
            let last = scalars.lastIndex(where: { $0 != " " && $0 != "\t" })
        else {
            return ""
        }
        return String(scalars[first...last])
    }
}
