import KnitPeer
import Testing

/// `knit-peer`'s switches for device trials, which change nothing unless asked.
@Suite struct PeerTrialSwitchTests {
    private func run(_ arguments: [String]) throws -> RunOptions {
        guard case .run(let options) = try PeerCommand.parse(arguments, environment: ["HOME": "/home/tester"]) else {
            throw UsageError.missing("run")
        }
        return options
    }

    /// `--stop-reading-after`: the far end's writes stall once the peer stops reading (ADR 2026-10.f5zs).
    @Test func thePeerStopsReadingOnlyWhenATrialAsks() throws {
        #expect(try run([]).stopReadingAfterSeconds == nil, "the peer reads its channels unless a trial asks")
        #expect(try run(["--stop-reading-after", "30"]).stopReadingAfterSeconds == 30)
        #expect(try run(["--stop-reading-after", "0"]).stopReadingAfterSeconds == 0)
        #expect(throws: UsageError.invalid(flag: "--stop-reading-after", value: "90000")) {
            try run(["--stop-reading-after", "90000"])
        }
        #expect(throws: UsageError.self) { try run(["--stop-reading-after", "soon"]) }
        #expect(PeerCommand.usage.contains("--stop-reading-after is for trials"))
    }
}
