import KnitWire

extension ControlLines {
    /// Who is typing where, as `{conversation: [node id, …]}`, the shape Android's bridge reports in `STATE.typing`
    /// (`DebugBridgeReceiver.kt:922-958`).
    static func typing(_ picture: [String: [NodeId]]) -> JSONValue {
        .object(picture.mapValues { .array($0.map { .string($0.string) }) })
    }
}
