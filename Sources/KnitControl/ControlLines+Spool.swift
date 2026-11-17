import KnitMesh

// `status`'s `spool` key (ADR 2026-11.adrq, P4b1): relays by handle and counts alone. No relay URL, no token and no scope
// id: the status carries none to print.
extension ControlLines {
    /// The spool plane's status.
    static func describe(_ status: SpoolStatus) -> JSONValue {
        [
            "paused": .bool(status.paused),
            "scopes": .int(Int64(status.scopes)),
            "counts": counts(status.counts),
            "relays": .array(
                status.relays.map { relay in
                    [
                        "relay": .int(Int64(relay.handle)),
                        "state": .string(relay.state),
                        "failures": .int(Int64(relay.failures)),
                        "counts": counts(relay.counts),
                    ]
                }),
        ]
    }

    private static func counts(_ counts: [String: Int]) -> JSONValue {
        .object(counts.mapValues { JSONValue.int(Int64($0)) })
    }
}
