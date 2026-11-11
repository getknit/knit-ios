import KnitSync
import KnitWire

@testable import KnitAppCore

/// A transport that answers each URL from a script and keeps every request, for ``PreviewWalk``'s tests.
final class ScriptedTransport: HTTPTransport, Sendable {
    /// What a URL answers with: a response whose body is read only when the walk asks, or a failure.
    enum HTTPReplyScript: Sendable {
        case response(status: Int, headers: [String: String], body: [UInt8], remote: [UInt8]?)
        /// A response whose body never comes, read or not.
        case headOnly(status: Int, headers: [String: String])
        case failed(HTTPFailure)
    }

    /// One request as the transport saw it.
    struct Request: Sendable, Equatable {
        var url: String
        var headers: [String]
        var limit: Int
        /// Whether the walk asked for the body.
        var read: Bool
    }

    private let script: Lock<[String: HTTPReplyScript]>
    private let seen = Lock<[Request]>([])

    init(_ script: [String: HTTPReplyScript] = [:]) {
        self.script = Lock(script)
    }

    /// Every request so far, in order.
    var requests: [Request] { seen.withLock { $0 } }

    /// Sets what `url` answers.
    func answer(_ url: String, with reply: HTTPReplyScript) {
        script.withLock { $0[url] = reply }
    }

    func get(_ url: String, headers: [(name: String, value: String)], limit: Int, reads: @Sendable (HTTPHead) -> Bool) -> HTTPReply {
        let scripted = script.withLock { $0[url] } ?? .response(status: 404, headers: [:], body: [], remote: nil)
        let names = headers.map { "\($0.name): \($0.value)" }
        switch scripted {
        case .failed(let failure):
            seen.withLock { $0.append(Request(url: url, headers: names, limit: limit, read: false)) }
            return .failed(failure)
        case .headOnly(let status, let fields):
            let head = HTTPHead(status: status, headers: fields)
            seen.withLock { $0.append(Request(url: url, headers: names, limit: limit, read: reads(head))) }
            return .response(head, body: nil, remoteAddress: nil)
        case .response(let status, let fields, let body, let remote):
            let head = HTTPHead(status: status, headers: fields)
            let read = reads(head)
            seen.withLock { $0.append(Request(url: url, headers: names, limit: limit, read: read)) }
            return .response(head, body: read ? Array(body.prefix(limit)) : nil, remoteAddress: remote)
        }
    }
}

/// A resolver answering from a table, every other host with one public address.
struct TableResolver: HostResolver {
    static let publicAddress: [UInt8] = [93, 184, 216, 34]
    var table: [String: [[UInt8]]] = [:]

    func addresses(of host: String) -> [[UInt8]] {
        table[host] ?? [Self.publicAddress]
    }
}

/// A route that is up, or down, or spared, as a test sets it.
final class SwitchedGate: InternetGate, Sendable {
    private let state = Lock((online: true, restricted: false))

    func set(online: Bool, restricted: Bool = false) {
        state.withLock { $0 = (online, restricted) }
    }

    func isOnline() -> Bool {
        state.withLock { $0.online }
    }

    func isRestricted() -> Bool {
        state.withLock { $0.restricted }
    }
}

/// A fetcher answering pages and pictures from tables, counting what it was asked.
final class TableFetcher: PreviewFetcher, Sendable {
    private let pages: Lock<[String: PageFetch]>
    private let images: Lock<[String: ImageFetch]>
    private let asked = Lock<[String]>([])
    /// Whether a page fetch waits until it is cancelled, as a site that never answers does.
    private let hangs: Bool
    /// What a page fetch waits for before it answers, when a test holds it.
    private let latch: Latch?

    init(pages: [String: PageFetch] = [:], images: [String: ImageFetch] = [:], hangs: Bool = false, latch: Latch? = nil) {
        self.pages = Lock(pages)
        self.images = Lock(images)
        self.hangs = hangs
        self.latch = latch
    }

    /// Every URL asked for, pages and pictures, in order.
    var requests: [String] { asked.withLock { $0 } }

    func setPage(_ url: String, _ fetch: PageFetch) {
        pages.withLock { $0[url] = fetch }
    }

    func fetchPage(_ url: String) async -> PageFetch {
        asked.withLock { $0.append(url) }
        if hangs {
            // Until the budget cancels it.
            try? await Task.sleep(for: .seconds(3600))
            return .transient
        }
        await latch?.wait()
        return pages.withLock { $0[url] } ?? .failed("http 404")
    }

    func fetchImage(_ url: String) -> ImageFetch {
        asked.withLock { $0.append(url) }
        return images.withLock { $0[url] } ?? .failed("http 404")
    }

    /// A page of `head` HTML, fetched from `final`.
    static func html(_ head: String, final: String = "https://example.com/story") -> PageFetch {
        .html(bytes: Array("<html><head>\(head)</head></html>".utf8), contentType: "text/html", finalURL: final)
    }
}

/// A gate a test opens once: everything that waits on it goes on then.
actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once the latch is open.
    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Opens the latch for everyone waiting and everyone to come.
    func open() {
        isOpen = true
        for waiter in waiting {
            waiter.resume()
        }
        waiting.removeAll()
    }
}
