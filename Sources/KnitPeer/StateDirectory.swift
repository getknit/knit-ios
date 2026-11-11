/// Where a peer keeps its state: `--state`, or `--instance` under `$XDG_STATE_HOME/knit-peer`
/// (`~/.local/state/knit-peer` by default), so that two peers on one machine keep two identities.
internal enum StateDirectory {
    static func resolve(flags: inout Flags, environment: [String: String]) throws(UsageError) -> String {
        let explicit = flags.take("--state")
        let instance = flags.take("--instance")
        if let explicit {
            guard instance == nil else {
                throw .invalid(flag: "--instance", value: "cannot go with --state")
            }
            return explicit
        }
        let name = instance ?? "default"
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw .invalid(flag: "--instance", value: name)
        }
        if let state = environment["XDG_STATE_HOME"], state.hasPrefix("/") {
            return state + "/knit-peer/" + name
        }
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            throw .missing("HOME, or --state")
        }
        return home + "/.local/state/knit-peer/" + name
    }
}
