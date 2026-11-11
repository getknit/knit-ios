// Every file in LinkPreviews/ compiles into a debug build alone while link previews are (`AppEnvironment.linkPreviews`): a
// store build reaches none of it.
#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitSync

    /// The app's ``HTTPTransport``: one GET over an ephemeral URLSession (ADR 2026-11.hcvg). Nothing is kept: no cookie,
    /// cache or credential, no proxy, so the address it reports is the site's, and no request on a route the user asked
    /// to spare. A redirect comes back as it is, for ``PreviewWalk`` to judge. No session exists until the first fetch,
    /// so a phone with the setting off makes no connection over IP at all.
    internal final class URLSessionTransport: HTTPTransport {
        /// How long a hop may go quiet, connecting or reading (`CONNECT_TIMEOUT_S`, `READ_TIMEOUT_S`).
        private static let idleSeconds: TimeInterval = 10
        /// How long one hop may take in all (`CALL_TIMEOUT_S`).
        private static let hopSeconds: TimeInterval = 15
        /// How long the address a hop connected to is waited for once its body is read, in milliseconds.
        private static let metricsWaitMilliseconds = 2000

        private let session = Lock<URLSession?>(nil)

        func get(
            _ url: String, headers: [(name: String, value: String)], limit: Int, reads: @Sendable (HTTPHead) -> Bool
        ) async -> HTTPReply {
            guard let target = URL(string: url) else {
                return .failed(.other("url"))
            }
            var request = URLRequest(url: target)
            request.httpShouldHandleCookies = false
            for header in headers {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
            // CFNetwork adds the phone's languages when nothing is set, which tells a site more than Android's none.
            request.setValue("*", forHTTPHeaderField: "Accept-Language")
            let watch = HopWatch()
            do {
                let (bytes, response) = try await opened().bytes(for: request, delegate: watch)
                guard let http = response as? HTTPURLResponse else {
                    bytes.task.cancel()
                    return .failed(.other("response"))
                }
                let fields = http.allHeaderFields.compactMap { key, value in (key as? String).map { ($0, "\(value)") } }
                let head = HTTPHead(status: http.statusCode, headers: Dictionary(fields) { first, _ in first })
                var body: [UInt8]?
                if reads(head) {
                    var read: [UInt8] = []
                    for try await byte in bytes {
                        read.append(byte)
                        if read.count >= limit {
                            break
                        }
                    }
                    body = read
                }
                bytes.task.cancel()
                let remote = await watch.remoteAddress(within: .milliseconds(Self.metricsWaitMilliseconds))
                return .response(head, body: body, remoteAddress: remote)
            } catch {
                return .failed(Self.failure(error))
            }
        }

        /// The one session, made on the first fetch.
        private func opened() -> URLSession {
            session.withLock { held in
                if let held {
                    return held
                }
                let made = URLSession(configuration: Self.configuration)
                held = made
                return made
            }
        }

        private static var configuration: URLSessionConfiguration {
            let made = URLSessionConfiguration.ephemeral
            made.httpCookieAcceptPolicy = .never
            made.httpShouldSetCookies = false
            made.httpCookieStorage = nil
            made.urlCredentialStorage = nil
            made.urlCache = nil
            made.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            made.waitsForConnectivity = false
            made.allowsConstrainedNetworkAccess = false
            made.connectionProxyDictionary = [:]
            made.timeoutIntervalForRequest = idleSeconds
            made.timeoutIntervalForResource = hopSeconds
            return made
        }

        private static func failure(_ error: any Error) -> HTTPFailure {
            guard let code = (error as? URLError)?.code else {
                return error is CancellationError ? .cancelled : .other("\(type(of: error))")
            }
            switch code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .cannotFindHost, .dnsLookupFailed:
                return .unresolved
            case .timedOut:
                return .timeout
            case .cancelled, .networkConnectionLost:
                return .cancelled
            default:
                return .other("URLError \(code.rawValue)")
            }
        }
    }

    /// One hop's task delegate: it refuses the redirect, so the walk sees it, and keeps the address the hop connected to.
    private final class HopWatch: NSObject, URLSessionTaskDelegate, Sendable {
        private let address = Lock<(known: Bool, bytes: [UInt8]?)>((false, nil))

        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
            // The delegate's requirement escapes it; a signature that differs is a method URLSession never calls.
            // swiftlint:disable:next unneeded_escaping
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let remote = metrics.transactionMetrics.last { $0.remoteAddress != nil }?.remoteAddress
            address.withLock { $0 = (true, remote.map(Self.bytes(of:))) }
        }

        /// The address the hop connected to, once the task has said, waiting at most `wait`; `nil` when it said none in
        /// time. An address that does not parse reads as unspecified, which is no public address.
        func remoteAddress(within wait: Duration) async -> [UInt8]? {
            let deadline = ContinuousClock.now + wait
            while ContinuousClock.now < deadline {
                let seen = address.withLock { $0 }
                if seen.known {
                    return seen.bytes
                }
                try? await Task.sleep(for: .milliseconds(Self.pollMilliseconds))
            }
            return nil
        }

        private static let pollMilliseconds = 20
        private static let unspecified: [UInt8] = [0, 0, 0, 0]

        /// `text`, an IPv4 or IPv6 address as metrics write it, as its bytes.
        private static func bytes(of text: String) -> [UInt8] {
            var v4 = in_addr()
            if inet_pton(AF_INET, text, &v4) == 1 {
                return withUnsafeBytes(of: &v4) { Array($0) }
            }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, text, &v6) == 1 {
                return withUnsafeBytes(of: &v6) { Array($0) }
            }
            return unspecified
        }
    }
#endif
