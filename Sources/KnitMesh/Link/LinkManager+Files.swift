public import KnitWire

/// A link's outgoing files (`FramedLink.streamFile` and its `stash`, `FramedLink.kt:107-108` and `:321-359`): one
/// streams at a time, and the rest wait their turn in order.
internal struct FileFeed {
    /// The file streaming now.
    struct Streaming {
        var file: OutboundFile
        /// When its header went out, for the log.
        let startedAt: Int64
        /// How many of the file's bytes are written.
        var offset = 0
        /// FILE records handed to a radio that reports writes, whose last byte it has not reported out yet.
        var unreported = 0
        /// Whether the END is written.
        var ended = false
        /// When the next record may go: the last chunk's share of a second at the pace.
        var nextAt: Int64
    }

    var streaming: Streaming?
    var waiting: [OutboundFile] = []

    /// When this feed next has work on the clock alone: a record waiting out the pace. A feed waiting for the radio's
    /// report has none, since the report itself brings the next record.
    var due: Int64? {
        guard let streaming, streaming.unreported == 0 else {
            return nil
        }
        return streaming.nextAt
    }

    /// Whether `hash` is streaming or waiting here.
    func holds(_ hash: BlobHash) -> Bool {
        streaming?.file.hash == hash || waiting.contains { $0.hash == hash }
    }
}

/// When a link's incoming file began and was last reported (`FramedLink.rxStartedAt` and `rxReportedAt`, knit-next ADR
/// 2026-10.nsr7), on the monotonic clock.
internal struct ArrivalClock {
    let startedAt: Int64
    var reportedAt: Int64
}

/// A whole file past its END that the engine has not taken yet, by the neighbour whose link carried it.
internal struct LandingFile: Hashable {
    var from: NodeId
    var hash: BlobHash
}

/// FILE records both ways (ADR 2026-10.h6zz).
///
/// **In,** each link's file passes through a ``FileIntake``, which applies Android's receiver rules. A peer's own AVATAR
/// push is kept up to ``Configuration/maxAvatarFileBytes``. An ATTACHMENT is kept only when the engine asked for its
/// hash (``acceptFiles(_:)``), up to Android's 8 MiB and 64 KiB, and partial files on every link together stay within
/// ``Configuration/maxBufferedFileBytes``. A whole file goes to the engine, which checks its hash. Every
/// ``progressEveryMilliseconds`` of a kept file's chunks, how much of it is in goes to the engine too, which tells the
/// sender (knit-next ADR 2026-10.nsr7).
///
/// **Out,** a file streams as Android streams one: its header, chunks of 16 KiB, then its END, one file at a time per
/// link, paced at 28 KiB/s. Each chunk waits until the radio reports the last one out of its queue, so the queue never
/// holds more than one chunk of a file, and frames written meanwhile go out between the chunks. Android's writer
/// blocks on its socket and interleaves frames the same way (`FramedLink.drainFramesInto`). FILE records never ring a
/// doorbell, as on Android (`BluetoothMeshTransport.sendFile`).
extension LinkManager {
    /// How much of a key the log shows: enough to tell files apart.
    static let shownKeyCharacters = 12
    /// For the pace's arithmetic.
    static let millisecondsPerSecond: Int64 = 1000
    /// How often a file streaming in is reported back to its sender (`FramedLink.PROGRESS_EVERY_MS`, knit-next ADR
    /// 2026-10.nsr7): often enough that its sender sees a stall within 15 s, rarely enough to cost nothing beside the file.
    public static let progressEveryMilliseconds: Int64 = 2000

    // MARK: MeshTransport

    /// Streams `file` to `peer` as FILE records, behind any file already on that link, and answers whether a link took
    /// it. A file already queued or streaming there is not queued again.
    public func sendFile(_ file: OutboundFile, to peer: NodeId) -> Bool {
        guard let id = liveChannel(to: peer) else {
            return false
        }
        guard !(feeds[id]?.holds(file.hash) ?? false) else {
            return true
        }
        feeds[id, default: FileFeed()].waiting.append(file)
        // At once: the timers run the links before the engine, so a file waiting for the next tick would lose one.
        pump(id, now: clock.monotonicMilliseconds())
        return true
    }

    /// Whether `hash` is queued or streaming to `peer`.
    public func isFileInFlight(_ hash: BlobHash, to peer: NodeId) -> Bool {
        liveChannel(to: peer).flatMap { feeds[$0] }?.holds(hash) ?? false
    }

    /// `peer` withdrew its ask for `hash` (`FramedLink.cancelQueued`, knit-next ADR 2026-10.nsr7): a copy waiting on its
    /// link is dropped before its header goes. Answers whether one was. A copy already streaming goes on, since cutting
    /// it short would need a record no build reads.
    public func cancelQueuedFile(_ hash: BlobHash, to peer: NodeId) -> Bool {
        guard let id = liveChannel(to: peer), let index = feeds[id]?.waiting.firstIndex(where: { $0.hash == hash }) else {
            return false
        }
        feeds[id]?.waiting.remove(at: index)
        log.log(.debug, "link \(id) file \(Self.shown(hash.string)) withdrawn by \(peer) before it streamed")
        return true
    }

    /// The files on their way in: those streaming in on some link, then those past their END that the engine has not
    /// taken (`arrivingFiles`, read in that order so a file is never in neither; knit-next ADR 2026-09.4tx5, amended
    /// for #138). A radio read runs all its records before the engine sees any of them, so a frame ahead of a FILE_END
    /// in the same read reaches the engine after the END has cleared the intake and before the file is stored.
    public var arrivingFileKeys: Set<BlobHash> {
        Set(intakes.values.compactMap(\.arriving)).union(landingFiles.map(\.hash))
    }

    /// The engine has taken a file `peer` sent us, stored or refused, so it is no longer on its way
    /// (`MeshTransport.fileTaken`).
    public func fileTaken(from peer: NodeId, hash: BlobHash) {
        landingFiles.remove(LandingFile(from: peer, hash: hash))
    }

    /// Whether a file from `peer` is streaming in now, kept or skipped (`fileArrivingFrom`, knit-next ADR 2026-10.nxfb).
    /// A file that has landed is not streaming.
    public func isFileArriving(from peer: NodeId) -> Bool {
        liveChannel(to: peer).flatMap { intakes[$0] }?.isStreaming ?? false
    }

    /// How many links are streaming a file out now (`feedingLoad`): one radio, so the count is over every link.
    public var feedingLoad: Int {
        feeds.values.count { $0.streaming != nil }
    }

    /// The attachments to keep as they stream in: the blobs the engine wants.
    public func acceptFiles(_ keys: Set<BlobHash>) {
        acceptedFileKeys = keys
    }

    /// Files streaming out or waiting to, over every link.
    public var queuedFileCount: Int {
        feeds.values.reduce(0) { $0 + $1.waiting.count } + feeds.values.count { $0.streaming != nil }
    }

    // MARK: In

    func fileHeader(_ payload: [UInt8], on id: ChannelID, now: Int64) {
        // Stamped at every header, kept or not, as Android's is; only a kept file is ever reported.
        arrivalClocks[id] = ArrivalClock(startedAt: now, reportedAt: now)
        let accepted = acceptedFileKeys
        let avatarLimit = configuration.maxAvatarFileBytes
        let events = intakes[id, default: FileIntake()].header(payload) { header, key in
            switch header.kind {
            case .avatar:
                avatarLimit
            case .attachment:
                accepted.contains(key) ? FileIntake.maxFileBytes : nil
            }
        }
        for event in events {
            note(event, on: id)
        }
    }

    func fileChunk(_ payload: [UInt8], from peer: NodeId, on id: ChannelID, now: Int64) -> [Event] {
        guard intakes[id] != nil else {
            return []
        }
        let others = intakes.reduce(0) { $1.key == id ? $0 : $0 + $1.value.bufferedBytes }
        if let event = intakes[id]?.chunk(payload, room: configuration.maxBufferedFileBytes - others) {
            note(event, on: id)
        }
        return fileProgress(from: peer, on: id, now: now)
    }

    /// How much of the kept file streaming in on `id` is held, once ``progressEveryMilliseconds`` have passed since its
    /// header or its last report (`FramedLink.reportRx`): after the chunk is in, so a stall reports nothing. A resumed
    /// stream would count its kept prefix too; this port never asks for one (knit-ios #2).
    private func fileProgress(from peer: NodeId, on id: ChannelID, now: Int64) -> [Event] {
        guard let intake = intakes[id], let hash = intake.arriving, var clock = arrivalClocks[id],
            now - clock.reportedAt >= Self.progressEveryMilliseconds
        else {
            return []
        }
        clock.reportedAt = now
        arrivalClocks[id] = clock
        let held = Int64(intake.bufferedBytes)
        return [.fileProgress(FileProgress(from: peer, hash: hash, held: held, milliseconds: now - clock.startedAt))]
    }

    func fileEnd(from peer: NodeId, on id: ChannelID) -> [Event] {
        guard case .finished(let header, let key, let bytes)? = intakes[id]?.end() else {
            return []
        }
        filesReceived += 1
        landingFiles.insert(LandingFile(from: peer, hash: key))
        log.log(.info, "link file \(header.kind.rawValue) \(Self.shown(key.string)) from \(peer): \(bytes.count) bytes")
        return [.file(InboundFile(from: peer, kind: header.kind, hash: key, mime: header.mime, bytes: bytes))]
    }

    /// Counts and logs a file the intake dropped. A file begun streams on, and a finished one reaches the engine from
    /// ``fileEnd(from:on:)``.
    private func note(_ event: FileIntake.Event, on id: ChannelID) {
        switch event {
        case .skipped(let header):
            filesRefused += 1
            log.log(.debug, "link \(id) file \(header.map { Self.shown($0.key) } ?? "unreadable") skipped")
        case .abandoned(let header):
            filesRefused += 1
            log.log(.info, "link \(id) file \(Self.shown(header.key)) dropped before its end")
        case .begun, .finished:
            break
        }
    }

    /// The first characters of a key, for the log.
    static func shown(_ key: String) -> Substring {
        key.prefix(shownKeyCharacters)
    }

    // MARK: Out

    /// The radio reported a FILE record's last byte out on `id`: the next one may go once its pace allows.
    func fileRecordWritten(on id: ChannelID, now: Int64) -> [Event] {
        if let unreported = feeds[id]?.streaming?.unreported, unreported > 0 {
            feeds[id]?.streaming?.unreported = unreported - 1
        }
        pump(id, now: now)
        return []
    }

    /// Writes the next record of every feed whose pace has run out, and hands over the files that finished.
    func feedDueFiles(now: Int64) -> [Event] {
        let due = feeds.filter { $0.value.due.map { $0 <= now } ?? false }.keys.sorted(by: Self.inOrder)
        for id in due {
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
    /// reported the last record out and its pace has run.
    private func pump(_ id: ChannelID, now: Int64) {
        while var feed = feeds[id] {
            guard let streaming = feed.streaming else {
                guard startNextFile(&feed, on: id, now: now) else {
                    feeds[id] = nil
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
                feeds[id] = feed
                noteSent(streaming, on: id, now: now)
                continue
            }
            guard now >= streaming.nextAt else {
                return
            }
            feed.streaming = writeNextRecord(of: streaming, on: id, now: now)
            feeds[id] = feed
        }
    }

    /// Starts the next waiting file with its header, or answers `false` when none waits.
    private func startNextFile(_ feed: inout FileFeed, on id: ChannelID, now: Int64) -> Bool {
        guard !feed.waiting.isEmpty else {
            return false
        }
        let file = feed.waiting.removeFirst()
        if let header = LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(file.header)).encoded {
            write(header, on: id)
        }
        feed.streaming = FileFeed.Streaming(file: file, startedAt: now, nextAt: now)
        return true
    }

    /// Writes a file's next chunk, or its END once its bytes run out. A file whose bytes cannot be read ends early,
    /// which fails the receiver's hash check, so it drops the file and keeps the link.
    private func writeNextRecord(of streaming: FileFeed.Streaming, on id: ChannelID, now: Int64) -> FileFeed.Streaming {
        var streaming = streaming
        let remaining = streaming.file.size - streaming.offset
        let chunk = remaining > 0 ? streaming.file.read(streaming.offset, min(configuration.fileChunkBytes, remaining)) : nil
        let record: [UInt8]?
        if let chunk, !chunk.isEmpty {
            record = LinkRecord(.fileChunk, payload: chunk).encoded
            streaming.offset += chunk.count
            streaming.nextAt = now + paceMilliseconds(for: chunk.count)
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
        return streaming
    }

    /// A file's END is out: it counts as sent, the log says so as it says a file arrived, and the engine hears so.
    private func noteSent(_ streaming: FileFeed.Streaming, on id: ChannelID, now: Int64) {
        filesSent += 1
        if let peer = liveLinks.first(where: { $0.channel == id })?.neighbor.nodeId {
            let file = streaming.file
            let took = now - streaming.startedAt
            log.log(
                .info, "link file \(file.kind.rawValue) \(Self.shown(file.hash.string)) to \(peer): \(streaming.offset) bytes in \(took) ms"
            )
            finishedFiles.append(.fileSent(file.hash, to: peer))
        }
    }

    /// One chunk's share of a second at the pace: 16 KiB at 28 KiB/s is 571 ms.
    private func paceMilliseconds(for count: Int) -> Int64 {
        let pace = configuration.filePaceBytesPerSecond
        return pace > 0 ? Int64(count) * Self.millisecondsPerSecond / Int64(pace) : 0
    }
}
