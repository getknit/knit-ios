import KnitMesh
import KnitSync
import KnitWire
import Testing

@testable import KnitSpoolNet

/// The factory on every platform (ADR 2026-11.adrq, P5): it says it exists in one line, and an address its check refuses
/// fails before any socket opens. Elsewhere than on Apple platforms it opens nothing at all.
@Suite struct URLSessionSpoolSocketFactoryTests {
    @Test func theFactoryLogsItsMarkerOnceAsItIsMade() {
        let log = LineLog()
        _ = URLSessionSpoolSocketFactory(log: log)
        #expect(log.lines == ["info \(URLSessionSpoolSocketFactory.marker)"])
        #expect(URLSessionSpoolSocketFactory.marker == "spool sockets are on in this debug build", "the line check.sh release greps for")
        #expect(URLSessionSpoolSocketFactory.dialsCleartext, "a debug build dials ws://")
    }

    /// A refusal fails as unreachable and logs one constant line: no address, host or query of the dial in it.
    @Test func anAddressTheCheckRefusesFailsAsUnreachableAndLogsOneConstantLine() async throws {
        let marker = "zq9spoolmarker"
        let url = try #require(AcceptedSpoolURL("wss://relay.example.org:0443/spool/v1?x=\(marker)", allowCleartext: false))
        let log = LineLog()
        let factory = URLSessionSpoolSocketFactory(log: log)
        for _ in 0..<2 {
            guard case .failed(let failure) = await factory.open(url) else {
                Issue.record("the dial opened")
                return
            }
            #expect(failure == SpoolDialFailure(.unreachable))
        }
        let refused = "warning \(URLSessionSpoolSocketFactory.refusedLine)"
        #expect(log.lines == ["info \(URLSessionSpoolSocketFactory.marker)", refused, refused], "one line per refused dial")
        #expect(URLSessionSpoolSocketFactory.refusedLine == "spool dial refused by the address check")
        for line in log.lines {
            #expect(!line.contains(marker) && !line.contains("relay.example.org") && !line.contains("0443"), "\(line)")
        }
    }

    #if !canImport(Darwin)
        /// FoundationNetworking's WebSocket rides the system libcurl, so the factory dials nothing here, however good the
        /// address.
        @Test func noSocketOpensAwayFromApplePlatforms() async throws {
            let url = try #require(AcceptedSpoolURL("ws://127.0.0.1:9/spool/v1", allowCleartext: true))
            let log = LineLog()
            let dial = await URLSessionSpoolSocketFactory(log: log).open(url)
            guard case .failed(let failure) = dial else {
                Issue.record("the dial opened")
                return
            }
            #expect(failure == SpoolDialFailure(.unreachable))
            #expect(log.lines == ["info \(URLSessionSpoolSocketFactory.marker)"], "the check took the address: no refusal line")
        }
    #endif
}

/// A log that keeps its lines, level first.
final class LineLog: KnitLog {
    private let kept = Lock<[String]>([])

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let line = "\(level) \(message())"
        kept.withLock { $0.append(line) }
    }

    var lines: [String] { kept.withLock { $0 } }
}
