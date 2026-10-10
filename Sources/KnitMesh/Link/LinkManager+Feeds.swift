public import KnitWire

/// A link's outgoing files (`FramedLink.streamFile` and its `stash`, `FramedLink.kt:107-108` and `:321-359`): one
/// streams at a time, and the rest wait their turn in order. Kept from the link's first file until the link goes.
internal struct FileFeed {
    /// The file streaming now.
    struct Streaming {
        var file: OutboundFile
        /// The neighbour it goes to, for the log.
        let peer: NodeId
        /// When its header went out, for the log.
        let startedAt: Int64
        /// Whether its receiver's reports clock it (``FeedWindow``): the switch is on and the peer's HELLO carries
        /// ``Capabilities/blobHave`` (`BleFeedPolicy.windowed`, with Android's iPhone exclusion lifted here).
        let windowed: Bool
        /// How many of the file's bytes are written.
        var offset = 0
        /// FILE records handed to a radio that reports writes, whose last byte it has not reported out yet.
        var unreported = 0
        /// Whether the END is written.
        var ended = false
        /// When the next record may go while paced: the last chunk's share of a second at the pace.
        var nextAt: Int64
        /// Whether the window clocks it now, rather than its paced fallback (`FramedLink.txWindowed`).
        var windowedNow = false
        /// While the window is full, when to look again if no report comes first: the silence is judged then.
        var waitAt: Int64?
        /// What its `link file window` line last said: `back`, or why it is paced.
        var says = "back"
        /// The rate its `link file window rate=` line last showed, moved only past a quarter (`FramedLink.windowedPace`).
        var rateShown: Int64 = 0
        /// The pace its last paced chunk went at, for the line at its end.
        var paceShown: Int64 = 0
        /// The pace its last chunk was noted at for the meter, and how many chunks were (`txPace`, `txPaced`).
        var notedPace: Int64 = 0
        var notedChunks = 0
        /// When its last chunk was written, or its header (`txWroteAt`).
        var wroteAt: Int64
    }

    var streaming: Streaming?
    var waiting: [OutboundFile] = []
    /// The window, kept across the link's streams: the round trip is the link's (`FramedLink.inFlight`).
    var window: FeedWindow
    /// How many links fed at the pace when this one's `link file pace` line was last logged.
    var feedingShown: Int?
    /// What the receiver's reports say of the stream going now, and what the link's last stream drained
    /// (`FramedLink.meter`, knit-next ADR 2026-10.nsr7).
    var meter = FeedMeter()

    /// The neighbour the link feeds.
    let peer: NodeId
    /// Whether that neighbour reports a file's progress: its HELLO carries ``Capabilities/blobHave``.
    let reports: Bool

    init(peer: NodeId, reports: Bool, maxChunkBytes: Int) {
        self.peer = peer
        self.reports = reports
        window = FeedWindow(maxChunkBytes: maxChunkBytes)
    }

    /// When this feed next has work on the clock alone: a record waiting out the pace, or a full window's look for
    /// silence. A feed waiting for the radio's report has none, since the report itself brings the next record.
    var due: Int64? {
        guard let streaming, streaming.unreported == 0 else {
            return nil
        }
        return streaming.windowedNow ? streaming.waitAt : streaming.nextAt
    }

    /// Whether `hash` is streaming or waiting here.
    func holds(_ hash: BlobHash) -> Bool {
        streaming?.file.hash == hash || waiting.contains { $0.hash == hash }
    }
}

/// What a feed may write now: up to `bytes`, and the pace it goes at when paced, or `nil` while its window clocks it.
internal struct Allowance {
    let bytes: Int
    let pace: FilePace?
}

/// FILE records out (ADR 2026-10.h6zz, ADR 2026-10.xwjc): the window that clocks a file by its receiver's reports, the
/// paced fallback, and the gate on the radio's report. The extension in `LinkManager+Files.swift` describes both ways.
extension LinkManager {
    /// How far a windowed feed's rate must move, as a share of the rate its log last showed, to show again
    /// (`FramedLink.PACE_MOVE_DEN`): a quarter.
    static let rateMoveShare: Int64 = 4
    /// How many chunks a feed's pace takes to settle (`FramedLink.SETTLE_CHUNKS`): until then its reading takes the
    /// faster of its measured rate and its pace. Android's longer settle for a link earning the boost never comes up:
    /// this port asks for no boost (ADR 2026-10.xwjc).
    static let settleChunks = 2

    /// `peer` holds `held` bytes of `hash`, `milliseconds` after its header reached it (its `blobprog`,
    /// `BluetoothMeshTransport.onFileProgress`): the window of the file streaming to it takes the report, if it is that
    /// file (`FeedMeter.report`'s key check, `FramedLink.onProgress`), and the feed writes what the report freed. Any
    /// report pumps the feed, as Android's wakes its writer.
    public func fileProgressReported(from peer: NodeId, hash: BlobHash, held: Int64, milliseconds: Int64) {
        guard let id = liveChannel(to: peer), var feed = feeds[id] else {
            return
        }
        let now = clock.monotonicMilliseconds()
        let before = feed.meter.measured
        let ours = feed.meter.report(hash, held: held, milliseconds: milliseconds, now: now)
        if ours, let streaming = feed.streaming, streaming.windowed {
            feed.window.report(held: held, milliseconds: milliseconds, now: now)
        }
        feeds[id] = feed
        if ours, !before, feed.meter.measured {
            // Its first rate: the feed's ETA is the drain's from now.
            noteFeedsChanged()
        }
        pump(id, now: now)
    }

    /// The radio reported a FILE record's last byte out on `id`: the next one may go once its window or pace allows.
    func fileRecordWritten(on id: ChannelID, now: Int64) -> [Event] {
        if let unreported = feeds[id]?.streaming?.unreported, unreported > 0 {
            feeds[id]?.streaming?.unreported = unreported - 1
        }
        pump(id, now: now)
        return []
    }

    /// Writes the next record of every feed whose wait has run out, and hands over the files that finished. A windowed
    /// feed's wait that ran late, as a suspended app's timer does, tells its window how late (`FramedLink.awaitReport`):
    /// with nothing owed, that time is not the receiver's silence.
    func feedDueFiles(now: Int64) -> [Event] {
        let due = feeds.compactMap { id, feed in feed.due.flatMap { $0 <= now ? (id, $0) : nil } }.sorted { Self.inOrder($0.0, $1.0) }
        for (id, at) in due {
            if feeds[id]?.streaming?.windowed == true {
                feeds[id]?.window.slept(now - at, now: now)
            }
            if feeds[id]?.streaming?.windowedNow == false {
                // A pace wait: what it ran past is the app asleep, which the meter does not count (`FramedLink.pauseFor`).
                feeds[id]?.meter.resumed(now: now)
            }
            pump(id, now: now)
        }
        return takeFinishedFiles()
    }

    /// The files that finished streaming since the last call.
    func takeFinishedFiles() -> [Event] {
        defer { finishedFiles.removeAll() }
        return finishedFiles
    }

    /// Writes what `id`'s feed may write now: a waiting file's header, then a chunk or the END each time the radio has
    /// reported the last record out and the window or the pace allows (`FramedLink.feedChunks`).
    func pump(_ id: ChannelID, now: Int64) {
        while var feed = feeds[id] {
            guard let streaming = feed.streaming else {
                guard startNextFile(&feed, on: id, now: now) else {
                    // Kept idle until the link goes: its window's round trip is the link's.
                    feeds[id] = feed
                    return
                }
                feeds[id] = feed
                continue
            }
            guard streaming.unreported == 0 else {
                return
            }
            if streaming.ended {
                feed.streaming = nil
                feed.meter.end()
                feeds[id] = feed
                noteSent(streaming, window: feed.window, on: id, now: now)
                noteFeedsChanged()
                continue
            }
            var current = streaming
            let allowed = admit(&current, window: &feed.window, feedingShown: &feed.feedingShown, on: id, now: now)
            if let allowed {
                if allowed.pace != nil {
                    // Out of its pace wait on time, by the timer or the radio's report (`FramedLink.pauseFor`).
                    feed.meter.resumed(now: current.nextAt)
                }
                writeNextRecord(&current, feed: &feed, allowed: allowed, on: id, now: now)
            }
            feed.streaming = current
            feeds[id] = feed
            if allowed == nil {
                return
            }
        }
    }

    /// Starts the next waiting file with its header, or answers `false` when none waits. A peer that reports is
    /// windowed, and its window starts before the header, which it does not count (`FramedLink.kt:790-797`).
    private func startNextFile(_ feed: inout FileFeed, on id: ChannelID, now: Int64) -> Bool {
        guard !feed.waiting.isEmpty else {
            return false
        }
        let file = feed.waiting.removeFirst()
        let windowed = configuration.feedWindow && feed.reports
        if windowed {
            feed.window.start(now: now)
        }
        feed.meter.start(file.hash, now: now)
        feed.meter.sized(offset: 0, length: Int64(file.size))
        if let header = LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(file.header)).encoded {
            write(header, on: id)
        }
        feed.streaming = FileFeed.Streaming(file: file, peer: feed.peer, startedAt: now, windowed: windowed, nextAt: now, wroteAt: now)
        return true
    }

    /// How many bytes the streaming file on `id` may write now, and the pace it goes at when paced; nil while it waits
    /// for a report to free its window, or out its pace. A windowed feed whose receiver is silent, or taken for a
    /// two-second reporter, is paced until the window takes it back (`FeedWindow.pacing`), and its paced chunks are
    /// small enough for a receiver awake again to answer each on time (`FeedWindow.chunkFor`).
    private func admit(
        _ streaming: inout FileFeed.Streaming, window: inout FeedWindow, feedingShown: inout Int?, on id: ChannelID, now: Int64
    ) -> Allowance? {
        let windowedNow = streaming.windowed && !window.pacing(now: now)
        if streaming.windowed {
            let says = windowedNow ? "back" : window.pacedWhy
            if says != streaming.says {
                streaming.says = says
                log.log(.info, "link file window \(says) → \(streaming.peer)")
            }
            if streaming.windowedNow, !windowedNow {
                // The pace starts over from here (`PaceWindow.restart`).
                streaming.nextAt = now
            }
        }
        streaming.windowedNow = windowedNow
        if windowedNow {
            let wait = window.waitMilliseconds
            guard wait == 0 else {
                streaming.waitAt = now + wait
                return nil
            }
            streaming.waitAt = nil
            return Allowance(bytes: window.chunkBytes, pace: nil)
        }
        streaming.waitAt = nil
        guard now >= streaming.nextAt else {
            return nil
        }
        let pace = filePace(for: id, to: streaming.peer, shown: &feedingShown)
        let bytes = streaming.windowed ? window.pacedChunkBytes(pace) : pace.chunkBytes
        return Allowance(bytes: bytes, pace: pace)
    }

    /// The pace of a link feeding without its window (knit-next ADR 2026-10.8jwn, `BluetoothMeshTransport.paceFor`):
    /// its share of the one budget among the links feeding at the pace, itself included. A windowed feed takes none of
    /// it: counted, it halved a paced link beside it (`pacedFeedingLinks`). Read before every chunk, so a link that
    /// starts or stops feeding moves the others' share at their next.
    private func filePace(for id: ChannelID, to peer: NodeId, shown: inout Int?) -> FilePace {
        let others = feeds.count { $0.key != id && $0.value.streaming.map { !$0.windowedNow } ?? false }
        let budget = configuration.filePaceBudgetBytesPerSecond
        let pace = FilePace(budget: budget, feeding: others + 1, maxChunkBytes: configuration.fileChunkBytes)
        if budget > 0, shown != others + 1 {
            shown = others + 1
            let share = "share=\(pace.bytesPerSecond) chunk=\(pace.chunkBytes)"
            log.log(.info, "link file pace budget=\(budget) feeding=\(others + 1) \(share) → \(peer)")
        }
        return pace
    }

    /// Writes a file's next chunk of up to `bytes`, or its END once its bytes run out. A file whose bytes cannot be
    /// read ends early, which fails the receiver's hash check, so it drops the file and keeps the link. A windowed chunk
    /// is counted out to its window at hand-off; a paced one holds the next back by its share of a second at `pace`.
    private func writeNextRecord(
        _ streaming: inout FileFeed.Streaming, feed: inout FileFeed, allowed: Allowance, on id: ChannelID, now: Int64
    ) {
        let remaining = streaming.file.size - streaming.offset
        let count = min(max(allowed.bytes, 1), configuration.fileChunkBytes, remaining)
        let chunk = remaining > 0 ? streaming.file.read(streaming.offset, count) : nil
        let record: [UInt8]?
        if let chunk, !chunk.isEmpty {
            record = LinkRecord(.fileChunk, payload: chunk).encoded
            notePaced(&streaming, meter: &feed.meter, allowed.pace?.bytesPerSecond ?? windowedPace(streaming, window: feed.window, on: id))
            streaming.offset += chunk.count
            streaming.wroteAt = now
            if streaming.windowed {
                feed.window.wrote(chunk.count, now: now)
            }
            if let pace = allowed.pace {
                let spacing = pace.spacing(for: chunk.count)
                streaming.nextAt = now + spacing
                streaming.paceShown = pace.bytesPerSecond
                feed.meter.pausing(spacing, now: now)
            } else {
                noteWindowRate(&streaming, window: feed.window)
            }
        } else {
            if remaining > 0 {
                log.log(.warning, "link \(id) file \(Self.shown(streaming.file.hash.string)) unreadable at \(streaming.offset); ending it")
            }
            record = LinkRecord(.fileEnd).encoded
            streaming.ended = true
        }
        if let record {
            radio.writeFileRecord(record, to: id)
            if radio.reportsFileWrites {
                streaming.unreported += 1
            }
        }
    }

    /// The next chunk is fed at `pace` (`FramedLink.notePaced`): what the meter's reading takes, and what a measured
    /// rate is held against. The reading changes when the settle ends or the pace moves, so the holder is told then.
    private func notePaced(_ streaming: inout FileFeed.Streaming, meter: inout FeedMeter, _ pace: Int64) {
        let moved = streaming.notedChunks > 0 && pace != streaming.notedPace
        streaming.notedPace = pace
        streaming.notedChunks += 1
        meter.paced(pace)
        if moved || streaming.notedChunks == Self.settleChunks {
            noteFeedsChanged()
        }
    }

    /// The pace a windowed chunk is noted at for the meter (`FramedLink.windowedPace`): the window's rate, or the paced
    /// share before one. It moves only past a quarter of the last, since a pace move resets the meter's measured rate.
    private func windowedPace(_ streaming: FileFeed.Streaming, window: FeedWindow, on id: ChannelID) -> Int64 {
        let paced = feeds.count { $0.key != id && $0.value.streaming.map { !$0.windowedNow } ?? false }
        let fallback = FilePace(
            budget: configuration.filePaceBudgetBytesPerSecond, feeding: paced + 1, maxChunkBytes: configuration.fileChunkBytes)
        let rate = window.rate > 0 ? window.rate : fallback.bytesPerSecond
        let last = streaming.notedPace
        return last > 0 && abs(rate - last) * Self.rateMoveShare < last ? last : rate
    }

    /// Logs a windowed feed's rate when it moves by a quarter or more (`FramedLink.windowedPace` and `logWindow`), so the
    /// log follows the drain without a line per chunk.
    private func noteWindowRate(_ streaming: inout FileFeed.Streaming, window: FeedWindow) {
        let rate = window.rate
        let moved = abs(rate - streaming.rateShown) * Self.rateMoveShare >= streaming.rateShown
        guard rate > 0, streaming.rateShown == 0 || moved else {
            return
        }
        streaming.rateShown = rate
        let estimates = "target=\(window.target) queued=\(window.queued) rtt=\(window.roundTripMilliseconds)"
        log.log(.info, "link file window rate=\(rate) \(estimates) → \(streaming.peer)")
    }

    /// A file's END is out: it counts as sent, the log says so as it says a file arrived, with the rate it went at, and
    /// the engine hears so.
    private func noteSent(_ streaming: FileFeed.Streaming, window: FeedWindow, on id: ChannelID, now: Int64) {
        filesSent += 1
        if let peer = liveLinks.first(where: { $0.channel == id })?.neighbor.nodeId {
            let file = streaming.file
            let took = now - streaming.startedAt
            let rate = streaming.windowedNow ? " @\(window.rate) window" : streaming.paceShown > 0 ? " @\(streaming.paceShown)" : ""
            log.log(
                .info,
                "link file \(file.kind.rawValue) \(Self.shown(file.hash.string)) to \(peer): \(streaming.offset) bytes in \(took) ms\(rate)"
            )
            finishedFiles.append(.fileSent(file.hash, to: peer))
        }
    }
}
