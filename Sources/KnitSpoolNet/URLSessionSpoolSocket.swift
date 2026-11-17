// Every file in KnitSpoolNet compiles into a debug build alone while the spool plane does (ADR 2026-11.adrq): a store build
// reaches none of it. The socket itself is Apple's alone: Linux tests the plane through a test socket.
#if DEBUG && canImport(Darwin)
    import Foundation
    import KnitMesh
    import KnitSync
    import KnitWire

    /// The one `URLSession` a factory dials through, and the delegate that answers for its tasks (ADR 2026-11.adrq, P5).
    ///
    /// The configuration stores nothing: no cookie is stored, sent or accepted, there is no cache and no
    /// credential storage, no wait for connectivity, a redirect refused, and TLS judged by the system's default trust with no
    /// evaluation of this port's own. The requests carry `Accept-Language: *` and a `User-Agent` with no version, as link
    /// previews' do, and nothing else of the app's.
    internal final class SpoolSessionDialer: Sendable {
        /// How long the upgrade may take: the plane's own open deadline (`SpoolLink.openMilliseconds`, `ScopeSync.kt:3381`).
        static let handshakeSeconds: TimeInterval = 20
        /// How long one socket may live before the session ends it and the plane dials again. A relay session lasts while
        /// Knit is in the foreground, so a day is a bound, never a cadence.
        static let socketSeconds: TimeInterval = 86_400
        /// How late the handshake's deadline may fire, in milliseconds: the system's default leeway on a 20 s sleep was a
        /// whole second.
        static let deadlineToleranceMilliseconds = 50
        /// The `User-Agent`: the app's name and nothing that tells a relay which build or system it talks to.
        static let userAgent = "Knit"

        private let session: URLSession
        private let watch: SpoolTaskWatch

        init() {
            let delegate = SpoolTaskWatch()
            watch = delegate
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: queue)
        }

        deinit {
            session.invalidateAndCancel()
        }

        /// The session's configuration (`URLSessionTransport.configuration` in link previews is the template).
        ///
        /// - The system's proxy settings stay, as OkHttp's default proxy selector keeps Android's: a `wss` relay goes through
        ///   a proxy as a `CONNECT` tunnel, so the proxy learns the host and port alone, and a `ws` relay sits on this phone or
        ///   its network and never carries a token.
        /// - Low Data Mode and cellular are allowed: the plane carries the person's own messages, in the foreground only, under
        ///   its hourly push and pull budgets.
        static var configuration: URLSessionConfiguration {
            let made = URLSessionConfiguration.ephemeral
            made.httpCookieAcceptPolicy = .never
            made.httpShouldSetCookies = false
            made.httpCookieStorage = nil
            made.urlCredentialStorage = nil
            made.urlCache = nil
            made.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            made.waitsForConnectivity = false
            made.allowsConstrainedNetworkAccess = true
            made.allowsExpensiveNetworkAccess = true
            made.timeoutIntervalForRequest = handshakeSeconds
            made.timeoutIntervalForResource = socketSeconds
            return made
        }

        /// Opens a WebSocket to `target`, an address ``SpoolDialCheck`` took. A cancelled task ends the dial at once.
        func open(_ target: URL) async -> SpoolDial {
            var request = URLRequest(
                url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.handshakeSeconds)
            request.httpShouldHandleCookies = false
            // CFNetwork adds the phone's languages when nothing is set, which tells a relay more than Android's none.
            request.setValue("*", forHTTPHeaderField: "Accept-Language")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let task = session.webSocketTask(with: request)
            // Refused before it is buffered: a larger message fails the receive and ends the task.
            task.maximumMessageSize = SpoolRecordLayer.maxInboundRecord
            let state = SpoolTaskState()
            watch.watch(task.taskIdentifier, state)
            // The handshake's own deadline: a server that reads the upgrade and never answers it holds the task past the
            // configuration's request timeout, so the dial bounds itself, whatever the plane's clock does.
            let deadline = Task { [state, task] in
                guard
                    (try? await Task.sleep(
                        for: .seconds(Self.handshakeSeconds), tolerance: .milliseconds(Self.deadlineToleranceMilliseconds))) != nil
                else {
                    return
                }
                if state.failOpen(SpoolDialFailure(.unreachable)) {
                    task.cancel()
                }
            }
            defer { deadline.cancel() }
            let failure = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if state.awaitOpen(continuation) {
                        task.resume()
                    }
                }
            } onCancel: {
                state.failOpen(SpoolDialFailure(.cancelled))
                task.cancel()
            }
            if let failure {
                task.cancel()
                return .failed(failure)
            }
            return .opened(URLSessionSpoolSocket(task: task, state: state))
        }
    }

    /// One relay's WebSocket: ``SpoolSocket`` over a `URLSessionWebSocketTask`.
    internal final class URLSessionSpoolSocket: SpoolSocket, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        private let task: URLSessionWebSocketTask
        private let state: SpoolTaskState

        init(task: URLSessionWebSocketTask, state: SpoolTaskState) {
            self.task = task
            self.state = state
        }

        /// The next message, asked of the task only now, or the end. A cancelled task ends the receive at once, and the socket
        /// with it.
        func receive() async -> SpoolSocketMessage {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard state.awaitReceive(continuation) else {
                        return
                    }
                    task.receive { [state, task] result in
                        switch SpoolTaskWatch.message(result, closeCode: task.closeCode.rawValue) {
                        case .closed(let end):
                            if state.end(end) {
                                task.cancel()
                            }
                        case let message:
                            state.deliver(message)
                        }
                    }
                }
            } onCancel: { [state, task] in
                if state.end(SpoolSocketEnd(.cancelled)) {
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
        }

        /// Writes one binary message and waits until the task took it: nothing is queued here.
        func send(_ bytes: [UInt8]) async -> Bool {
            guard !state.ended else {
                return false
            }
            do {
                try await task.send(.data(Data(bytes)))
                return true
            } catch {
                return false
            }
        }

        /// Closes once with `code`, no reason; a later call does nothing, and every receive answers the close.
        func close(code: Int) {
            guard state.end(SpoolSocketEnd(.cancelled)) else {
                return
            }
            task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        }

        var description: String { "spool socket" }

        var debugDescription: String { description }

        /// No children: the task's mirror would hand `dump` its request and the address.
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// The session's delegate: it opens and fails each dial, refuses every redirect, and ends a socket whose task completed.
    /// A task's state is looked up by its identifier, and forgotten when the task completes.
    internal final class SpoolTaskWatch: NSObject, URLSessionWebSocketDelegate, Sendable {
        private let states = Lock<[Int: SpoolTaskState]>([:])

        func watch(_ task: Int, _ state: SpoolTaskState) {
            states.withLock { $0[task] = state }
        }

        private func state(of task: URLSessionTask) -> SpoolTaskState? {
            states.withLock { $0[task.taskIdentifier] }
        }

        func urlSession(_: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol chosen: String?) {
            // This port offers no subprotocol, and the only extension the task offers is `permessage-deflate`, so an upgrade
            // that names anything else answered another client.
            let extensions = (webSocketTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Extensions")
            guard chosen == nil, extensions.map(Self.namesOnlyTheOfferedExtension) != false else {
                state(of: webSocketTask)?.failOpen(SpoolDialFailure(.protocolError))
                webSocketTask.cancel()
                return
            }
            state(of: webSocketTask)?.opened()
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let state = states.withLock { $0.removeValue(forKey: task.taskIdentifier) }
            state?.failOpen(Self.dialFailure(error, response: task.response))
            let closeCode = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
            _ = state?.end(Self.end(error, closeCode: closeCode))
        }

        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
            // The delegate's requirement escapes it; a signature that differs is a method URLSession never calls.
            // swiftlint:disable:next unneeded_escaping
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        /// The extension `URLSessionWebSocketTask` offers on every upgrade, as seen by the stub server's suite.
        static let offeredExtension = "permessage-deflate"

        /// Whether an upgrade's `Sec-WebSocket-Extensions` names the offered extension alone, its parameters aside.
        static func namesOnlyTheOfferedExtension(_ header: String) -> Bool {
            header.split(separator: ",").allSatisfy { item in
                item.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == offeredExtension
            }
        }

        // MARK: Mapping, at the adapter's edge

        /// A received message as the plane takes it: a binary message as its bytes, a text message by its size, and a
        /// failure as the close the task heard (its code, never its reason) or a fault word.
        static func message(_ result: Result<URLSessionWebSocketTask.Message, any Error>, closeCode: Int) -> SpoolSocketMessage {
            switch result {
            case .success(.data(let data)) where data.count <= SpoolRecordLayer.maxInboundRecord:
                .binary(Array(data))
            case .success(.data):
                .closed(SpoolSocketEnd(.protocolError))
            case .success(.string(let text)):
                .text(byteCount: text.utf8.count)
            case .success:
                .closed(SpoolSocketEnd(.protocolError))
            case .failure(let error):
                .closed(end(error, closeCode: closeCode))
            }
        }

        /// How a task ended: the close code the relay sent, held to the codes' range, or a fault word.
        static func end(_ error: (any Error)?, closeCode: Int) -> SpoolSocketEnd {
            closeCode == URLSessionWebSocketTask.CloseCode.invalid.rawValue
                ? SpoolSocketEnd(fault(error)) : SpoolSocketEnd(.closed, code: closeCode)
        }

        /// Why an upgrade failed: an HTTP status with the first bytes of its `Retry-After`, or a fault word.
        static func dialFailure(_ error: (any Error)?, response: URLResponse?) -> SpoolDialFailure {
            guard let http = response as? HTTPURLResponse, http.statusCode != switchingProtocols else {
                return SpoolDialFailure(fault(error))
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").map { SpoolRetryAfter(header: Array($0.utf8)) }
            return SpoolDialFailure(.http, status: http.statusCode, retryAfter: retryAfter)
        }

        private static let switchingProtocols = 101

        /// The fault word for `error`, from its code alone: nothing of its text, user info or URL goes further.
        static func fault(_ error: (any Error)?) -> SpoolSocketFault {
            guard let error else {
                return .closed
            }
            guard let code = (error as? URLError)?.code else {
                let posix = error as NSError
                return posix.domain == NSPOSIXErrorDomain && posix.code == Int(EMSGSIZE) ? .protocolError : .unreachable
            }
            switch code {
            case .cancelled:
                return .cancelled
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                return .tls
            case .badServerResponse:
                return .http
            default:
                return .unreachable
            }
        }
    }

    /// One task's state, shared by its dial, its socket and the delegate: the dial's outcome, decided once; the socket's end,
    /// set once; and the receive waiting, at most one.
    internal final class SpoolTaskState: Sendable {
        private struct State {
            var opening: CheckedContinuation<SpoolDialFailure?, Never>?
            /// The dial's outcome once decided: `nil` inside when it opened.
            var outcome: SpoolDialFailure??
            var end: SpoolSocketEnd?
            var receiving: CheckedContinuation<SpoolSocketMessage, Never>?
        }

        private let state = Lock(State())

        /// Waits for the dial's outcome. Answers `false`, having resumed `continuation`, when it is already decided.
        func awaitOpen(_ continuation: CheckedContinuation<SpoolDialFailure?, Never>) -> Bool {
            let decided = state.withLock { state -> SpoolDialFailure?? in
                if state.outcome == nil {
                    state.opening = continuation
                }
                return state.outcome
            }
            if let decided {
                continuation.resume(returning: decided)
                return false
            }
            return true
        }

        func opened() {
            decide(.some(nil))
        }

        /// Fails the dial, unless it is decided already. Answers whether this call decided it.
        @discardableResult
        func failOpen(_ failure: SpoolDialFailure) -> Bool {
            decide(.some(failure))
        }

        @discardableResult
        private func decide(_ outcome: SpoolDialFailure??) -> Bool {
            let (decided, waiting) = state.withLock { state -> (Bool, CheckedContinuation<SpoolDialFailure?, Never>?) in
                guard state.outcome == nil else {
                    return (false, nil)
                }
                state.outcome = outcome
                defer { state.opening = nil }
                return (true, state.opening)
            }
            if let waiting, let outcome {
                waiting.resume(returning: outcome)
            }
            return decided
        }

        var ended: Bool { state.withLock { $0.end != nil } }

        /// Waits for the next message. Answers `false`, having resumed `continuation` with the end, once the socket ended.
        func awaitReceive(_ continuation: CheckedContinuation<SpoolSocketMessage, Never>) -> Bool {
            let end = state.withLock { state -> SpoolSocketEnd? in
                if state.end == nil {
                    state.receiving = continuation
                }
                return state.end
            }
            if let end {
                continuation.resume(returning: .closed(end))
                return false
            }
            return true
        }

        /// Hands the waiting receive its message; a message after the end is dropped.
        func deliver(_ message: SpoolSocketMessage) {
            let waiting = state.withLock { state in
                defer { state.receiving = nil }
                return state.end == nil ? state.receiving : nil
            }
            waiting?.resume(returning: message)
        }

        /// Ends the socket with `end`, answering the waiting receive. Answers whether this call ended it.
        @discardableResult
        func end(_ end: SpoolSocketEnd) -> Bool {
            let (first, waiting) = state.withLock { state -> (Bool, CheckedContinuation<SpoolSocketMessage, Never>?) in
                guard state.end == nil else {
                    return (false, nil)
                }
                state.end = end
                defer { state.receiving = nil }
                return (true, state.receiving)
            }
            waiting?.resume(returning: .closed(end))
            return first
        }
    }
#endif
