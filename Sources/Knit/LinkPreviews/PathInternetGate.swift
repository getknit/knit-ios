#if os(iOS) && DEBUG
    import KnitAppCore
    import KnitSync
    import Network

    /// The app's ``InternetGate``: the system's own view of the route, from `NWPathMonitor` (ADR 2026-11.hcvg). Online
    /// means a satisfied path; restricted means Low Data Mode, which a card's fetch spares as Android's spares Data Saver.
    /// It watches only: it opens no connection.
    internal final class PathInternetGate: InternetGate {
        private let monitor = NWPathMonitor()
        /// The last path the monitor said, or `nil` before its first word, which counts as offline.
        private let path = Lock<(online: Bool, restricted: Bool)?>(nil)

        init() {
            monitor.pathUpdateHandler = { [path] update in
                path.withLock { $0 = (update.status == .satisfied, update.isConstrained) }
            }
            monitor.start(queue: DispatchQueue(label: "app.getknit.knit.linkpreviews.path"))
        }

        deinit {
            monitor.cancel()
        }

        func isOnline() -> Bool {
            path.withLock { $0?.online ?? false }
        }

        func isRestricted() -> Bool {
            path.withLock { $0?.restricted ?? false }
        }
    }
#endif
