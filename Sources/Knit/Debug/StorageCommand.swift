#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl
    import KnitMesh
    import KnitStoreSQL
    import KnitWire

    /// `{"cmd":"storage"}`: where this launch found the identity and the database, for MVP item 1's reboot check
    /// (`interop.py iphone-reboot`) and the protection class P5 left to the iPhone. Only the app keeps its identity in
    /// the Keychain and its database under Data Protection, so the bridge answers it rather than ``MeshControl``.
    internal struct StorageCommand: Decodable {
        static let name = "storage"

        let cmd: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Answers with what `report` reads now.
        @MainActor
        func answer(_ report: StorageReport?) -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let report else {
                reply["ok"] = false
                reply["error"] = "a demo keeps no identity or database"
                return JSONValue.object(reply).line
            }
            reply.merge(report.fields()) { _, fact in fact }
            reply["ok"] = true
            return JSONValue.object(reply).line
        }
    }

    /// What ``StorageCommand`` reports, read afresh at each ask: the identity and whether the Keychain gives it up,
    /// whether onboarding is remembered, the database's protection class and backup flag, and how the launch went.
    @MainActor
    internal final class StorageReport {
        private static let millisecondsPerSecond: Int64 = 1000
        private static let microsecondsPerMillisecond: Int64 = 1000

        private let nodeId: NodeId
        private let keyStore: KeychainSecretStore
        private let directory: URL
        private let preferences: any AppPreferences
        private let launch: Launch.History

        /// A report on `nodeId`'s keys in `keyStore`, the database in `directory`, and a launch that went as `launch`
        /// says, with onboarding remembered in `preferences`.
        init(nodeId: NodeId, keyStore: KeychainSecretStore, directory: URL, preferences: any AppPreferences, launch: Launch.History) {
            self.nodeId = nodeId
            self.keyStore = keyStore
            self.directory = directory
            self.preferences = preferences
            self.launch = launch
        }

        func fields() -> [String: JSONValue] {
            [
                "nodeId": .string(nodeId.string),
                "onboarded": .bool(preferences.hasOnboarded),
                "bootedAt": Self.bootedAt().map(JSONValue.int) ?? .null,
                "now": .int(SystemClock().wallMilliseconds()),
                "launch": [
                    "startedAt": .int(launch.startedAt),
                    "waited": .text(launch.waited),
                    "readyBy": .text(launch.readyBy?.rawValue),
                    "readyAt": launch.readyAt.map(JSONValue.int) ?? .null,
                ],
                "keychain": keychain(),
                "database": database(),
            ]
        }

        /// Whether the keys read, and the class their item is kept under.
        private func keychain() -> JSONValue {
            do {
                let readable = try keyStore.read() != nil
                guard let accessibility = try keyStore.accessibility() else {
                    return ["readable": .bool(readable), "accessible": .null]
                }
                return [
                    "readable": .bool(readable),
                    "accessible": .string(accessibility.value),
                    "afterFirstUnlockThisDeviceOnly": .bool(accessibility.isAfterFirstUnlockThisDeviceOnly),
                ]
            } catch {
                return ["readable": false, "error": .string("\(error)")]
            }
        }

        /// The protection class of the directory and of each database file in it, and the directory's backup flag.
        private func database() -> JSONValue {
            let files = [KnitDatabase.fileName, "\(KnitDatabase.fileName)-wal", "\(KnitDatabase.fileName)-shm"]
            var protection: [String: JSONValue] = [:]
            for (name, item) in [("directory", directory)] + files.map({ ($0, directory.appending(path: $0)) }) {
                let path = item.path(percentEncoded: false)
                guard FileManager.default.fileExists(atPath: path) else {
                    continue
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                protection[name] = .text((attributes?[.protectionKey] as? FileProtectionType)?.rawValue)
            }
            let excluded = try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            return ["protection": .object(protection), "excludedFromBackup": excluded.map(JSONValue.bool) ?? .null]
        }

        /// When the phone last started, in wall milliseconds (`kern.boottime`). A reboot moves it.
        private static func bootedAt() -> Int64? {
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else {
                return nil
            }
            return Int64(boot.tv_sec) * millisecondsPerSecond + Int64(boot.tv_usec) / microsecondsPerMillisecond
        }
    }
#endif
