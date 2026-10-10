import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Repros for the interop audit of 2026-10-09 (`interop-audit`, knit-next 8dc60836 against knit-ios 9ac4cdf). Each one
/// asserts what Android does. They were known issues until `ios-blob-parity` ported the Kotlin (ADR 2026-10.ds45's
/// amendment of 2026-10-10).
@Suite struct InteropAuditMeshTests {
    private let author = TestPeer(seed: 2).nodeId
    private let holder = TestPeer(seed: 3).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let wait = BlobExchange.queryWaitMilliseconds

    /// Sends the queries the steps so far owe at `now`, each under an id of its own, as the engine's flush does.
    private func send(_ exchange: inout BlobExchange, at now: Int64) {
        for query in exchange.takeQueries() {
            exchange.noteQuerySent("\(query.peer)@\(now)", to: query.peer, hashes: query.hashes, now: now)
        }
    }

    /// `peer` answers the latest query sent it, at `now`, that it is in `state` for the photo.
    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, at now: Int64) {
        let latest = exchange.sentQueries.values.filter { $0.peer == peer }.max { $0.at < $1.at }
        let item = BlobHasItem(hash: photo.string, state: state, size: state.isHeld ? 1000 : nil)
        let re = latest.map { "\($0.peer)@\($0.at)" }
        _ = exchange.recordAnswers(BlobHasContent(items: [item], load: 0, re: re), from: peer, now: now)
    }

    /// IOS-1: knit-next 79f38d3d's `streamWait` (`BlobExchange.kt:481-511`). An ask whose neighbour answered, after it,
    /// that it lacks the blob is dropped at once while that neighbour streams us another file: nothing of ours is
    /// queued behind the stream, and a neighbour that holds the blob is asked. This port polled the streaming neighbour
    /// every 2 s for the whole stream. Its other half, `idleHolderPast`, has a test of its own below.
    @Test func anAskTheStreamingNeighbourSaidItLacksIsDroppedForAHolder() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: nil, asker: nil)
        let quiet = [author, holder].map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
        _ = exchange.decide(photo, among: quiet, now: 0)
        send(&exchange, at: 0)
        #expect(exchange.decide(photo, among: quiet, now: wait).asks == [BlobExchange.Ask(to: author, line: .first)], "both silent")
        answer(&exchange, author, .notHeld, at: wait + 1000)
        answer(&exchange, holder, .have, at: wait + 1000)
        let streaming = [
            BlobExchange.Candidate(id: author, streaming: true, capable: true),
            BlobExchange.Candidate(id: holder, streaming: false, capable: true),
        ]
        let plan = exchange.decide(photo, among: streaming, now: wait + 1500)
        #expect(plan.asks.map(\.to) == [holder])
        #expect(plan.notes.contains { $0.hasPrefix("blob drop ") && $0.hasSuffix("it lacked the blob, nothing of ours is queued") })
        #expect(exchange.counts.fallbacks == 0, "a drop, not a fallback")
    }

    /// IOS-1's other half: knit-next 79f38d3d's `idleHolderPast` (`BlobExchange.kt:518-528`). A holder that streams us
    /// another file with more than `STREAM_SWITCH_MS` left is left, failed, for a holder that said HAVE with load 0 and
    /// streams us nothing; 30 s left or less is waited out.
    @Test func anIdleHolderIsAskedPastAStreamWithMoreThanThirtySecondsLeft() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: nil, asker: nil)
        let quiet = [author, holder].map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
        _ = exchange.decide(photo, among: quiet, now: 0)
        send(&exchange, at: 0)
        answer(&exchange, author, .have, at: 100)
        #expect(exchange.decide(photo, among: quiet, now: 100).asks == [BlobExchange.Ask(to: author, line: .fetch)], "the author's HAVE")
        answer(&exchange, holder, .have, at: 200)
        func streaming(left: Int64) -> [BlobExchange.Candidate] {
            [
                BlobExchange.Candidate(id: author, streaming: true, capable: true, streamLeftMilliseconds: left),
                BlobExchange.Candidate(id: holder, streaming: false, capable: true),
            ]
        }
        let waiting = exchange.decide(photo, among: streaming(left: BlobExchange.streamSwitchMilliseconds), now: 1000)
        #expect(waiting.asks.isEmpty && waiting.wake == BlobExchange.streamPollMilliseconds, "30 s left is waited out")
        let left = exchange.decide(photo, among: streaming(left: BlobExchange.streamSwitchMilliseconds + 1), now: 3000)
        #expect(left.asks == [BlobExchange.Ask(to: holder, line: .fetch)])
        #expect(left.notes.contains { $0.contains("(streaming another file ~30001 ms, \(holder) idle) → next") })
        #expect(exchange.counts.fallbacks == 1)
    }

    // MARK: The receiver's reports

    private let channel = ChannelID(100)

    private func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
    }

    /// IOS-3 (AND-7): Android's receiver keeps every file whose header decodes and reports it (`FileIntake.kt:124-131`,
    /// `RxReports.kt:48-70`), so a windowed Android sender is clocked to the end. This port skips an attachment it no
    /// longer wants, and reported nothing, so the sender heard nothing, fell back to its base pace after 3 s
    /// (`FeedWindow.kt:367`, `:474`) and streamed the whole file at it. It now reports the bytes it reads.
    @Test func aSkippedAttachmentIsStillReportedToItsSender() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(8192)
        rig.links.acceptFiles([])
        let header = FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "image/jpeg", size: file.count)
        _ = rig.handle(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        rig.clock.advance(100)
        let events = rig.handle(.received(channel, LinkRecord(.fileChunk, payload: Array(file[0..<4096])).encoded ?? []))
        #expect(events == [.fileProgress(FileProgress(from: LinkRig.low, hash: BlobHash(of: file), held: 4096, milliseconds: 100))])
    }
}
