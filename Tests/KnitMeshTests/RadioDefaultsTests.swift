import KnitMesh
import KnitSync
import KnitWire
import Testing

/// What the `Radio` protocol's extension gives a radio that overrides none of it: one that takes each write at once and
/// hands every event over at once, as the demo's does (ADR 2026-10.f5zs).
@Suite struct RadioDefaultsTests {
    /// A radio that implements only what the protocol requires, and keeps what it is handed.
    private final class BareRadio: Radio {
        let advertisesServiceData = true
        let dialsGattPeers = false
        let servesDoorbell = false
        let events = AsyncStream<RadioEvent> { _ in
            // Nothing to report.
        }
        private let writes = Lock<[[UInt8]]>([])

        var written: [[UInt8]] { writes.withLock { $0 } }

        func start() {
            // Nothing to power.
        }

        func stop() {
            // Nothing to power down.
        }

        func advertise(_: AdvertPayload) {
            // Nobody listens.
        }

        func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
            ChannelID(1)
        }

        func write(_ bytes: [UInt8], to _: ChannelID) {
            writes.withLock { $0.append(bytes) }
        }

        func close(_: ChannelID) {
            // Nothing open.
        }
    }

    @Test func aRadioWithNoQueueReadsEmptyAndNeverStalls() {
        let bare = BareRadio()
        let radio: any Radio = bare
        radio.write([1, 2, 3], to: ChannelID(4))
        #expect(radio.outboxLevel(on: ChannelID(4)) == OutboxLevel(), "nothing queued and nothing written, whatever it took")
        #expect(bare.written == [[1, 2, 3]])
    }

    @Test func aRadioThatKeepsNoCountTakesAConsumedReportQuietly() {
        let bare = BareRadio()
        let radio: any Radio = bare
        radio.consumed(1 << 20, on: ChannelID(4))
        #expect(bare.written.isEmpty, "a report writes nothing")
        #expect(radio.outboxLevel(on: ChannelID(4)) == OutboxLevel())
    }
}
