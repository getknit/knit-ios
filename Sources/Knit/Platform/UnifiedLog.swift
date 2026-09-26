#if os(iOS)
    import Foundation
    import KnitMesh
    import os

    /// Where the mesh's log goes: the unified log, one JSON line per entry, so an interop run reads the iPhone with
    /// `idevicesyslog` the way it reads Android through its debug bridge. Release builds keep warnings only.
    internal struct UnifiedLog: KnitLog {
        private static let logger = Logger(subsystem: "app.getknit.knit", category: "mesh")

        private let threshold: LogLevel
        private let clock: any MeshClock

        init(clock: any MeshClock) {
            self.clock = clock
            #if DEBUG
                threshold = .debug
            #else
                threshold = .warning
            #endif
        }

        func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
            guard level >= threshold else {
                return
            }
            let fields: [String: Any] = ["log": "\(level)", "ms": clock.wallMilliseconds(), "message": message()]
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                let line = String(data: data, encoding: .utf8)
            else {
                return
            }
            switch level {
            case .debug:
                Self.logger.debug("\(line, privacy: .public)")
            case .info:
                Self.logger.info("\(line, privacy: .public)")
            case .warning:
                Self.logger.warning("\(line, privacy: .public)")
            }
        }
    }
#endif
