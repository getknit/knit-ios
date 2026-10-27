import KnitStore
public import KnitWire

/// When a link's incoming file began and was last reported (`RxReports`, knit-next ADRs 2026-10.nsr7 and 2026-10.5buf),
/// on the monotonic clock: how much the last report held, and when the trailing report is due.
internal struct ArrivalClock {
    /// The neighbour streaming the file, whom the reports go to.
    let peer: NodeId
    let startedAt: Int64
    var reportedAt: Int64
    var reportedBytes: Int64 = -1
    var trailingAt: Int64?

    init(peer: NodeId, startedAt: Int64) {
        self.peer = peer
        self.startedAt = startedAt
        reportedAt = startedAt
    }
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
/// hash (``acceptFiles(_:resumable:)``), up to Android's 8 MiB and 64 KiB, and leaves a prefix kept when cut only when the
/// engine wants it of its own, and partial files on every link together stay within
/// ``Configuration/maxBufferedFileBytes``. A whole file goes to the engine, which checks its hash. How much of a file is
/// in goes to the engine too, kept or skipped, which tells the sender (knit-next ADR 2026-10.nsr7): on every chunk that
/// brings 2 KiB, at least every half second, and once more half a second after chunks no report carried, so a windowed
/// sender always has a report coming (`RxReports`, knit-next ADR 2026-10.5buf). Android keeps every file whose header
/// decodes, so its sender hears of each; a skipped one is reported here as it streams by, or the sender would hear
/// nothing and stream the rest at its base pace (ADR 2026-10.ds45's amendment of 2026-10-10).
///
/// **Out,** a file streams as Android streams one: its header, chunks, then its END, one file at a time per link. A
/// peer that reports (its HELLO carries ``Capabilities/blobHave``) clocks the file by its reports (``FeedWindow``):
/// chunks of about a quarter second of the drain, written while what no report has said landed is under the drain over
/// the round trip plus a quarter second. A silent peer, one that reports only every two seconds, or one that does not
/// report at all, gets the paced fallback: 4 KiB/s split among the links feeding at that pace (knit-next ADR
/// 2026-10.8jwn). Either way each chunk waits until the radio reports the last one out of its queue, so the queue never
/// holds more than one chunk of a file, and frames written meanwhile go out between the chunks. Android's writer
/// blocks on its socket and interleaves frames the same way (`FramedLink.drainFramesInto`). FILE records never ring a
/// doorbell, as on Android (`BluetoothMeshTransport.sendFile`).
extension LinkManager {
    /// How much of a key the log shows: enough to tell files apart.
    static let shownKeyCharacters = 12
    /// How often a file streaming in is reported back to its sender with ``Configuration/feedWindow`` off
    /// (`RxReports.EVERY_MS`, knit-next ADR 2026-10.nsr7): often enough that its sender sees a stall within 15 s, rarely
    /// enough to cost nothing beside the file.
    public static let progressEveryMilliseconds: Int64 = 2000
    /// How often it is reported with the switch on, at the least (`RxReports.WINDOWED_EVERY_MS`), and how soon after
    /// chunks no report carried the trailing report goes.
    public static let windowedProgressEveryMilliseconds: Int64 = 500
    /// And on every chunk that brings this much since the last report (`RxReports.WINDOWED_EVERY_BYTES`): a sender's
    /// smallest chunk, so under every window. A windowed sender writes nothing more until it hears, and between two
    /// dark phones only a Bluetooth packet wakes either, so the report on the chunk itself is the one that always comes.
    public static let windowedProgressEveryBytes = Int64(FeedWindow.minChunkBytes)

    // MARK: MeshTransport

    /// Streams `file` to `peer` as FILE records, behind any file already on that link, and answers whether a link took
    /// it. A file already queued or streaming there is not queued again.
    public func sendFile(_ file: OutboundFile, to peer: NodeId) -> Bool {
        guard let link = liveLinks.first(where: { $0.neighbor.nodeId == peer }) else {
            return false
        }
        let id = link.channel
        guard !(feeds[id]?.holds(file.hash) ?? false) else {
            return true
        }
        let reports = link.neighbor.capabilities.contains(.blobHave)
        let now = clock.monotonicMilliseconds()
        feeds[id, default: FileFeed(peer: peer, reports: reports, maxChunkBytes: configuration.fileChunkBytes)].waiting.append(file)
        // At once: the timers run the links before the engine, so a file waiting for the next tick would lose one.
        pump(id, now: now)
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
        // Off the `file` wording a holder's serves are counted by, as Android keeps its line (`FramedLink.kt`).
        log.log(.debug, "link \(id) blob withdrawn \(Self.shown(hash.string)) by \(peer) before it streamed")
        return true
    }

    /// The files on their way in: those streaming in on some link, then those past their END that the engine has not
    /// taken (`arrivingFiles`, read in that order so a file is never in neither; knit-next ADR 2026-09.4tx5, amended
    /// for #138). A radio read runs all its records before the engine sees any of them, so a frame ahead of a FILE_END
    /// in the same read reaches the engine after the END has cleared the intake and before the file is stored.
    public var arrivingFileKeys: Set<BlobHash> {
        Set(intakes.values.compactMap(\.arriving)).union(landingFiles.map(\.hash))
    }

    /// How far each file being kept has got, by key, for the app to draw (`arrivingFiles()`, knit-next ADR 2026-10.y9qh):
    /// the bytes in so far and the size its header declared. Only a kept file, since a skipped one never lands here, so
    /// its keys are always among ``arrivingFileKeys``, and a resumed one from its kept prefix, so the ring starts where it
    /// was. A prefix kept from a cut link is never on its way. When two links stream one key, the copy furthest along shows
    /// (`furthestByKey`), the lower channel on a tie.
    ///
    /// Android adds the files past their END (`landing.all`), because its store runs off the link's thread and a file
    /// must not vanish from the ring before its bytes are stored (#138). Here ``fileEnd(from:on:)`` and the engine's
    /// store, which takes the file at once (``MeshEngine/receiveFile(_:)``), run in one turn of the actor, so no reader
    /// outside it ever sees a file landed, and they are left out. Read afresh each time: a kept copy of an intake would
    /// share its buffer, and every chunk after would copy the whole file.
    public var arrivingFiles: [BlobHash: FileIntake.Reading] {
        var furthest: [BlobHash: FileIntake.Reading] = [:]
        for id in intakes.keys.sorted(by: Self.inOrder) {
            guard intakes[id]?.arriving != nil, let file = intakes[id]?.reading else {
                continue
            }
            if let kept = furthest[file.key], kept.bytes >= file.bytes {
                continue
            }
            furthest[file.key] = file
        }
        return furthest
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

    /// How long the file streaming in from `peer` has left at the rate it has come in since its header
    /// (`FramedLink.rxEtaMs`): the bytes its header declared that are still to come, over the bytes in since the header
    /// per millisecond. A resumed stream's kept prefix came in on another link, so its rate counts the tail alone. Kept or
    /// skipped, so the asker can weigh any stream it waits behind. `nil` with none, with no declared size, or before a byte
    /// of it.
    public func fileArrivingLeftMilliseconds(from peer: NodeId) -> Int64? {
        guard let id = liveChannel(to: peer), let file = intakes[id]?.reading, let total = file.total, let clock = arrivalClocks[id] else {
            return nil
        }
        let got = Int64(file.bytes - file.from)
        let elapsed = self.clock.monotonicMilliseconds() - clock.startedAt
        guard got > 0, elapsed > 0 else {
            return nil
        }
        return max(Int64(total - file.bytes), 0) * elapsed / got
    }

    /// How many links are streaming a file out now (`feedingLoad`): one radio, so the count is over every link.
    public var feedingLoad: Int {
        feeds.values.count { $0.streaming != nil }
    }

    /// The attachments to keep as they stream in: the blobs the engine wants. Of those, `resumable`, the engine's own
    /// wants, leave a prefix kept when their link is cut (``keepCutFile(on:now:)``, knit-ios #20).
    public func acceptFiles(_ keys: Set<BlobHash>, resumable: Set<BlobHash>) {
        acceptedFileKeys = keys
        resumableFileKeys = resumable
    }

    /// How many files wait on `peer`'s link behind the one streaming, 0 when unlinked.
    public func filesWaiting(to peer: NodeId) -> Int {
        liveChannel(to: peer).flatMap { feeds[$0] }?.waiting.count ?? 0
    }

    /// Files streaming out or waiting to, over every link.
    public var queuedFileCount: Int {
        feeds.values.reduce(0) { $0 + $1.waiting.count } + feeds.values.count { $0.streaming != nil }
    }

    // MARK: In

    /// A header on `id`. One that resumes a cut transfer is spliced onto the prefix ``partials`` kept, read only once the
    /// intake's gates pass and the room every link's partial files share holds it (knit-ios #2).
    func fileHeader(_ payload: [UInt8], from peer: NodeId, on id: ChannelID, now: Int64) {
        // Stamped at every header, kept or not, as Android's is.
        arrivalClocks[id] = ArrivalClock(peer: peer, startedAt: now)
        let accepted = acceptedFileKeys
        let avatarLimit = configuration.maxAvatarFileBytes
        let others = intakes.reduce(0) { $1.key == id ? $0 : $0 + $1.value.bufferedBytes }
        let partials = partials
        let events = intakes[id, default: FileIntake()].header(
            payload,
            room: configuration.maxBufferedFileBytes - others,
            limit: { header, key in
                switch header.kind {
                case .avatar:
                    avatarLimit
                case .attachment:
                    accepted.contains(key) ? FileIntake.maxFileBytes : nil
                }
            },
            prefix: { key, offset in partials.open(key, offset: offset).map { ($0.bytes, $0.epoch) } },
            now: now
        )
        for event in events {
            note(event, on: id)
        }
    }

    /// The link `id` was cut mid-file (`FileIntake.cut`, `FileIntake.kt:232-243`): an attachment being kept goes to
    /// ``partials`` as a prefix the next ask resumes from, which keeps it only if it is the longest held and was not
    /// spliced onto a prefix dropped since. Anything else is dropped. Which teardowns cut and which drop is the caller's.
    ///
    /// Only for a key the engine wants of its own as the link is cut (``resumableFileKeys``, knit-ios #20). Android keeps
    /// any cut attachment, so a peer that has us fetch eight hashes for it and cuts each stream past 16 KiB evicts every
    /// prefix of ours from the eight the store keeps; an echo's cut stream is dropped here instead, and its next ask starts
    /// from byte 0.
    func keepCutFile(on id: ChannelID, now: Int64) {
        guard let cut = intakes[id]?.cut(), resumableFileKeys.contains(cut.key) else {
            return
        }
        partials.keep(cut.key, bytes: cut.bytes, basedOn: cut.basedOn, now: now)
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

    /// How much of the file streaming in on `id` has been read, kept or skipped, after the chunk is in, so a stall reports
    /// nothing (`RxReports.chunk`). With the window's switch on, on a chunk that brings ``windowedProgressEveryBytes`` since the
    /// last report or once ``windowedProgressEveryMilliseconds`` have passed, else arming the trailing report; with it
    /// off, every ``progressEveryMilliseconds``. A resumed stream's report holds its kept prefix too, the blob's bytes held,
    /// as the wire means it: its sender takes the offset off (`FeedWindow.kt:210-226`).
    private func fileProgress(from peer: NodeId, on id: ChannelID, now: Int64) -> [Event] {
        guard let file = intakes[id]?.reading, var clock = arrivalClocks[id] else {
            return []
        }
        let hash = file.key
        let held = Int64(file.bytes)
        let windowed = configuration.feedWindow
        let every = windowed ? Self.windowedProgressEveryMilliseconds : Self.progressEveryMilliseconds
        let grown = windowed && held - max(clock.reportedBytes, 0) >= Self.windowedProgressEveryBytes
        guard now - clock.reportedAt >= every || grown else {
            if windowed, clock.trailingAt == nil {
                clock.trailingAt = clock.reportedAt + Self.windowedProgressEveryMilliseconds
                arrivalClocks[id] = clock
            }
            return []
        }
        clock.reportedAt = now
        clock.reportedBytes = held
        arrivalClocks[id] = clock
        return [.fileProgress(FileProgress(from: peer, hash: hash, held: held, milliseconds: now - clock.startedAt))]
    }

    /// When a trailing report is next due on any link.
    var trailingReportDue: Int64? {
        arrivalClocks.values.compactMap(\.trailingAt).min()
    }

    /// The trailing reports that are due (`RxReports.trail`): while chunks have landed that no report covered, one every
    /// ``windowedProgressEveryMilliseconds``. A clock with nothing owed, or whose file is over, stops; the next chunk
    /// that goes unreported arms it again. A suspended app fires it late, and the sender's next chunk wakes us anyway.
    func reportTrailing(now: Int64) -> [Event] {
        let due = arrivalClocks.compactMap { id, clock in clock.trailingAt.flatMap { $0 <= now ? (id, clock) : nil } }
            .sorted { Self.inOrder($0.0, $1.0) }
        var events: [Event] = []
        for (id, armed) in due {
            var clock = armed
            guard let file = intakes[id]?.reading, Int64(file.bytes) > clock.reportedBytes else {
                clock.trailingAt = nil
                arrivalClocks[id] = clock
                continue
            }
            let hash = file.key
            let left = clock.reportedAt + Self.windowedProgressEveryMilliseconds - now
            if left <= 0 {
                let held = Int64(file.bytes)
                clock.reportedAt = now
                clock.reportedBytes = held
                clock.trailingAt = now + Self.windowedProgressEveryMilliseconds
                events.append(.fileProgress(FileProgress(from: clock.peer, hash: hash, held: held, milliseconds: now - clock.startedAt)))
            } else {
                clock.trailingAt = now + left
            }
            arrivalClocks[id] = clock
        }
        return events
    }

    func fileEnd(from peer: NodeId, on id: ChannelID) -> [Event] {
        guard case .finished(let header, let key, let bytes, let resumedFrom)? = intakes[id]?.end() else {
            return []
        }
        filesReceived += 1
        landingFiles.insert(LandingFile(from: peer, hash: key))
        // The tail's bytes, and where it resumed last, as the sent line has it (`LinkManager+Feeds`).
        let resumed = resumedFrom > 0 ? " resumed at \(resumedFrom)" : ""
        log.log(
            .info, "link file \(header.kind.rawValue) \(Self.shown(key.string)) from \(peer): \(bytes.count - resumedFrom) bytes\(resumed)")
        return [.file(InboundFile(from: peer, kind: header.kind, hash: key, mime: header.mime, bytes: bytes, resumedFrom: resumedFrom))]
    }

    /// Counts and logs a file the intake dropped, and a resume it took. A file begun streams on, and a finished one
    /// reaches the engine from ``fileEnd(from:on:)``.
    private func note(_ event: FileIntake.Event, on id: ChannelID) {
        switch event {
        case .skipped(let header):
            filesRefused += 1
            log.log(.debug, "link \(id) file \(header.map { Self.shown($0.key) } ?? "unreadable") skipped")
        case .refused(let header, let why):
            filesRefused += 1
            // A refused header always resumes, under a well-formed key.
            if let offset = header.offset, let key = BlobHash(header.key) {
                log.log(.info, "link \(id) file \(Self.shown(key.string)) refused resumed at \(offset): \(reason(why, key, offset))")
            }
        case .abandoned(let header):
            filesRefused += 1
            log.log(.info, "link \(id) file \(Self.shown(header.key)) dropped before its end")
        case .begun(let header), .finished(let header, _, _, _):
            // A finished file comes through ``fileEnd(from:on:)``, never here.
            if let offset = header.offset, offset > 0 {
                // Counted as the prefix is spliced on (`FramedLink.kt:933`).
                filesResumedIn += 1
                log.log(.info, "link \(id) file \(Self.shown(header.key)) resumed at \(offset)")
            }
        }
    }

    /// A refused resume's reason, in Android's words where it has them (`FileIntake.kt:149`).
    private func reason(_ why: FileIntake.Refusal, _ key: BlobHash, _ offset: Int) -> String {
        switch why {
        case .resumedRecently(let milliseconds):
            "resumed \(milliseconds)ms ago"
        case .notKept:
            "\(partials.length(key))B kept"
        case .noRoom:
            "no room for \(offset)B"
        }
    }

    /// The first characters of a key, for the log.
    static func shown(_ key: String) -> Substring {
        key.prefix(shownKeyCharacters)
    }
}
