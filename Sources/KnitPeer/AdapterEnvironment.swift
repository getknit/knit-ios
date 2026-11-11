/// The adapters the environment names (`PeerCommand.adapterVariable`, `PeerCommand.reservedVariable`).
internal enum AdapterEnvironment {
    static func address(_ environment: [String: String]) -> String? {
        environment[PeerCommand.adapterVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func reserved(_ environment: [String: String]) -> [String] {
        (environment[PeerCommand.reservedVariable] ?? "").split(separator: ",").map { String($0.filter { $0 != " " }) }
            .filter { !$0.isEmpty }
    }
}
