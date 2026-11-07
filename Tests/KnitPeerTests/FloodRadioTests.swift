import KnitMesh
import KnitPeer
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// `--flood`'s radio: junk frames at the rate asked, to live links only, never inside another record, held back by a full
/// queue, and everything else passed through (ADR 2026-10.f5zs, rule 6).
@Suite(.timeLimit(.minutes(1))) struct FloodRadioTests {
    let channel = ChannelID(5)
    let node = fixtureNodeId(4)

    @Test func onlyALiveLinkIsFlooded() {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        flood.tick(milliseconds: 1000)
        #expect(flood.floodedBytes == 0, "no link yet")
        flood.heardHello(from: node, on: channel)
        flood.tick(milliseconds: 1000)
        #expect(flood.floodedBytes == 0, "a HELLO alone is no link: its PROOF may still be to come")
        flood.linkUp(node, on: channel)
        flood.tick(milliseconds: 1000)
        let records = inner.records(on: channel)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.tag == .frame && $0.payload.count <= FloodRadio.recordPayloadBytes })
        #expect(records.map { $0.payload.count + LinkRecord.headerBytes }.reduce(0, +) == 10_000, "a second's worth")
        flood.close(channel)
        flood.tick(milliseconds: 1000)
        #expect(inner.records(on: channel).count == records.count, "a closed link is flooded no more")
        #expect(inner.closed == [channel])
    }

    @Test func theJunkNeverDecodes() throws {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 3)
        flood.linkUp(node, on: channel)
        flood.tick(milliseconds: 1000)
        flood.tick(milliseconds: 2000)
        let records = inner.records(on: channel)
        #expect(!records.isEmpty, "a rate below one record a second still writes, carrying its debt")
        for record in records {
            #expect(throws: WireDecodingError.self) { try WireEnvelope(decoding: record.payload) }
        }
        #expect(inner.frames(on: channel).isEmpty)
        let full = [UInt8](repeating: FloodRadio.junkByte, count: FloodRadio.recordPayloadBytes)
        #expect(throws: WireDecodingError.self) { try WireEnvelope(decoding: full) }
    }

    @Test func aRecordBeingWrittenInSlicesIsNeverCut() throws {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        flood.linkUp(node, on: channel)
        let profile = try #require(LinkRecord(.frame, payload: [UInt8](repeating: 7, count: 20_000)).encoded)
        flood.write(Array(profile[0..<8192]), to: channel)
        flood.tick(milliseconds: 100)
        flood.write(Array(profile[8192..<16_384]), to: channel)
        flood.tick(milliseconds: 100)
        #expect(flood.floodedBytes == 0, "the link manager is partway through a record")
        flood.write(Array(profile[16_384...]), to: channel)
        flood.tick(milliseconds: 100)
        #expect(flood.floodedBytes > 0)
        let records = inner.records(on: channel)
        #expect(records.first == LinkRecord(.frame, payload: [UInt8](repeating: 7, count: 20_000)), "whole, then the junk")
        #expect(records.dropFirst().allSatisfy { $0.payload.allSatisfy { $0 == FloodRadio.junkByte } })
    }

    @Test func aFullQueueHoldsTheFloodBack() {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        flood.linkUp(node, on: channel)
        inner.setQueued(FloodRadio.heldBackBytes, on: channel)
        flood.tick(milliseconds: 5000)
        #expect(flood.floodedBytes == 0)
        inner.setQueued(0, on: channel)
        flood.tick(milliseconds: 100)
        #expect(flood.floodedBytes <= 10_000 + Int64(FloodRadio.recordPayloadBytes), "what was owed meanwhile is a second's worth at most")
    }

    @Test func whatTheMeshConsumedReachesTheRadio() async {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 1)
        flood.consumed(42, on: channel)
        #expect(inner.consumed(on: channel) == 42, "a wrapper that kept it would leave the channel paused")
        inner.emit(.accepted(channel))
        flood.linkUp(node, on: channel)
        inner.emit(.closed(channel))
        var events: [RadioEvent] = []
        for await event in flood.events {
            events.append(event)
            if event == .closed(channel) {
                break
            }
        }
        #expect(events == [.accepted(channel), .closed(channel)])
        #expect(flood.floodedChannels.isEmpty, "a channel the radio reports closed is flooded no more")
    }

    @Test func everythingElsePassesThrough() {
        let inner = RecordingRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 1)
        #expect(!flood.advertisesServiceData)
        #expect(flood.dialsGattPeers)
        #expect(flood.servesDoorbell)
        #expect(flood.reportsFileWrites)
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: node, digestCue: 0, psm: 0x81)
        flood.start()
        flood.advertise(advert)
        #expect(flood.dial(RadioAddress("far"), psm: 0x81) == ChannelID(31))
        flood.writeDigest([7, 0, 0, 0, 0], to: channel)
        flood.writeFileRecord([2, 0, 0, 0, 0], to: channel)
        inner.level = OutboxLevel(queuedBytes: 12, writtenBytes: 34)
        #expect(flood.outboxLevel(on: channel) == OutboxLevel(queuedBytes: 12, writtenBytes: 34))
        flood.ring(channel)
        flood.seekPeers(true)
        flood.stop()
        let expected = ["start", "advertise \(node)", "dial far 129", "digest ch5 5", "file ch5 5", "ring ch5", "seek true", "stop"]
        #expect(inner.calls == expected)
    }

    @Test func aStopForgetsEveryLinkButKeepsTheCount() {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        flood.linkUp(node, on: channel)
        flood.tick(milliseconds: 1000)
        let flooded = flood.floodedBytes
        #expect(flooded > 0)
        flood.stop()
        #expect(inner.stopped)
        #expect(flood.floodedChannels.isEmpty, "a stopped radio holds no link")
        #expect(flood.floodedBytes == flooded, "what was written stays written")
        flood.tick(milliseconds: 1000)
        #expect(flood.floodedBytes == flooded)
    }

    @Test func aWriteShorterThanAHeaderHoldsNothingBack() {
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        flood.linkUp(node, on: channel)
        flood.write([1, 0, 0], to: channel)
        flood.tick(milliseconds: 100)
        #expect(flood.floodedBytes > 0, "it reads as a whole write, not as the start of a record still to come")
    }
}

/// An inner radio whose every flag differs from ``PeerRadio``'s, and which records each call it is handed.
private final class RecordingRadio: Radio {
    let advertisesServiceData = false
    let dialsGattPeers = true
    let servesDoorbell = true
    let reportsFileWrites = true
    let events = AsyncStream<RadioEvent> { _ in
        // Nothing to report.
    }
    private let state = Lock<(calls: [String], level: OutboxLevel)>(([], OutboxLevel()))

    var calls: [String] { state.withLock { $0.calls } }

    var level: OutboxLevel {
        get { state.withLock { $0.level } }
        set { state.withLock { $0.level = newValue } }
    }

    private func record(_ call: String) {
        state.withLock { $0.calls.append(call) }
    }

    func start() {
        record("start")
    }

    func stop() {
        record("stop")
    }

    func advertise(_ payload: AdvertPayload) {
        record("advertise \(payload.advertised)")
    }

    func dial(_ address: RadioAddress, psm: UInt16) -> ChannelID {
        record("dial \(address.rawValue) \(psm)")
        return ChannelID(31)
    }

    func write(_ bytes: [UInt8], to channel: ChannelID) {
        record("write \(channel) \(bytes.count)")
    }

    func writeDigest(_ record: [UInt8], to channel: ChannelID) {
        self.record("digest \(channel) \(record.count)")
    }

    func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
        self.record("file \(channel) \(record.count)")
    }

    func close(_ channel: ChannelID) {
        record("close \(channel)")
    }

    func outboxLevel(on _: ChannelID) -> OutboxLevel {
        level
    }

    func ring(_ channel: ChannelID) {
        record("ring \(channel)")
    }

    func seekPeers(_ seeking: Bool) {
        record("seek \(seeking)")
    }
}
