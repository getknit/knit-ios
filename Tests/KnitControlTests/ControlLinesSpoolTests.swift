import Testing

@testable import KnitControl
@testable import KnitMesh

/// `status`'s `spool` key (ADR 2026-11.adrq, P4b1): handles, states and counts, and nothing else.
@Suite struct ControlLinesSpoolTests {
    @Test func aRelayIsItsHandleItsStateAndItsCounts() {
        let relay = SpoolStatus.Relay(handle: 1, state: "open", failures: 0, counts: ["sessions": 1])
        let status = SpoolStatus(paused: false, scopes: 2, counts: ["delivered": 3], relays: [relay])
        let described = ControlLines.describe(status)
        let expected: JSONValue = [
            "paused": .bool(false),
            "scopes": .int(2),
            "counts": .object(["delivered": .int(3)]),
            "relays": .array([["relay": .int(1), "state": .string("open"), "failures": .int(0), "counts": .object(["sessions": .int(1)])]]),
        ]
        #expect(described == expected)
    }
}
