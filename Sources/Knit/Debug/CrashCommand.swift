#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl

    /// The saved reports' trial (ADR 2026-10.qhsv): `{"cmd":"crash-now"}` traps on the main thread half a second after it
    /// replies, `{"cmd":"hang-now","seconds":3}` blocks the main thread that long after it replies, and
    /// `{"cmd":"crash-reports"}` lists what the store holds, newest first, as `reports` of `kind`, `at`, `summary` and
    /// `fingerprint`. MetricKit delivers a crash or hang to the next launch, and never to a process a debugger is attached
    /// to, so a trial launches Knit with `devicectl`, sends the first, relaunches, and reads the third.
    internal struct CrashCommand: Decodable {
        private static let names: Set = ["crash-now", "hang-now", "crash-reports"]
        /// How long after its reply a command traps or blocks, so the reply leaves first.
        private static let replyDelaySeconds = 0.5
        private static let defaultHangSeconds = 3.0

        let cmd: String
        let seconds: Double?
        let tag: String?

        /// The command on `line`, when it is one of these.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), names.contains(command.cmd) else {
                return nil
            }
            return command
        }

        /// The reply, with the trap or the block it asked for scheduled after it.
        @MainActor
        func answer(_ crashes: CrashStore) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(cmd), "ok": true]
            if let tag {
                reply["tag"] = .string(tag)
            }
            switch cmd {
            case "crash-now":
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDelaySeconds) {
                    fatalError("the bridge's crash-now")
                }
            case "hang-now":
                let blocked = seconds ?? Self.defaultHangSeconds
                reply["seconds"] = .string("\(blocked)")
                // Blocks the main thread itself: a hang is the main thread not answering.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDelaySeconds) {
                    Thread.sleep(forTimeInterval: blocked)
                }
            default:
                let reports = await Task.detached {
                    CrashDiagnostic.Kind.allCases.flatMap(crashes.list).sorted { $0.at > $1.at }
                }.value
                reply["reports"] = .array(
                    reports.map { report in
                        .object([
                            "kind": .string(report.kind.name),
                            "at": .int(report.at),
                            "summary": .string(report.summary),
                            "fingerprint": .string(report.fingerprint),
                        ])
                    })
            }
            return JSONValue.object(reply).line
        }
    }
#endif
