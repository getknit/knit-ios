import KnitWire
import Testing

/// A link's intake splicing a resumed stream onto a kept prefix, and handing a cut file over to be kept (knit-next ADR
/// 2026-10.wtyc and its #161 amendment, knit-ios #2): twins of `FileIntakeTest`'s resume and window cases. The keep rules
/// themselves (the longer, the epochs, the floor) are the store's, in `PartialBlobStoreTests`.
@Suite struct FileIntakeResumeTests {
    private let key = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let other = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
    private let body = (0..<1000).map { UInt8($0 % 251) }

    /// What a test keeps: each key's prefix and its epoch, and how many reads were asked of it.
    private final class Kept {
        var prefixes: [BlobHash: (bytes: [UInt8], epoch: Int)] = [:]
        var reads = 0

        func read(_ key: BlobHash, _ offset: Int) -> (bytes: [UInt8], basedOn: Int)? {
            reads += 1
            guard let kept = prefixes[key], kept.bytes.count >= offset else {
                return nil
            }
            return (Array(kept.bytes.prefix(offset)), kept.epoch)
        }
    }

    private func hash(_ string: String? = nil) throws -> BlobHash {
        try #require(BlobHash(string ?? key))
    }

    /// A header's payload as kotlinx writes one, but with any offset written, 0 and below included, which no sender writes.
    private func header(_ kind: FileHeader.Kind = .attachment, key: String? = nil, size: Int?, offset: Int?) -> [UInt8] {
        let whole = LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: key ?? self.key, mime: "image/jpeg", size: size))
        guard let offset else {
            return whole
        }
        return whole.dropLast() + Array(",\"offset\":\(offset)}".utf8)
    }

    private func keepAll(_: FileHeader, _: BlobHash) -> Int? { .max }

    /// Resumes `key` from `offset` on `intake` at `now`, with `kept` as the store.
    private func resume(
        _ intake: inout FileIntake, _ kept: Kept, offset: Int, size: Int?, key: String? = nil, room: Int = .max, now: Int64 = 0
    ) -> [FileIntake.Event] {
        intake.header(header(key: key, size: size, offset: offset), room: room, limit: keepAll, prefix: kept.read, now: now)
    }

    private func kept(_ count: Int, key: String? = nil, epoch: Int = 7) throws -> Kept {
        let kept = Kept()
        kept.prefixes[try hash(key)] = (Array(body.prefix(count)), epoch)
        return kept
    }

    @Test func aResumedStreamSplicesOntoTheKeptPrefixByteForByte() throws {
        let store = try kept(600)
        var intake = FileIntake()
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(resume(&intake, store, offset: 600, size: 400) == [.begun(resumed)])
        #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 600, total: 1000, from: 600), "the ring resumes where it was")
        #expect(intake.arriving == (try hash()))
        #expect(intake.bufferedBytes == 600, "the prefix counts against the room")
        #expect(intake.chunk(Array(body[600...])) == nil)
        #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 1000, total: 1000, from: 600))
        #expect(intake.end() == .finished(resumed, try hash(), body, resumedFrom: 600))
    }

    @Test func aPrefixThatIsAlreadyCompleteFinishesOnAnEmptyTail() throws {
        var intake = FileIntake()
        _ = resume(&intake, try kept(1000), offset: 1000, size: 0)
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 0, offset: 1000)
        #expect(intake.end() == .finished(resumed, try hash(), body, resumedFrom: 1000))
    }

    @Test func aStreamFromBeforeTheEndOfTheKeptPrefixReadsOnlyWhatItNeeds() throws {
        // A serve queued before another link got further: the stream starts at 400 though 600 are kept.
        var intake = FileIntake()
        _ = resume(&intake, try kept(600), offset: 400, size: 600)
        #expect(intake.bufferedBytes == 400)
        _ = intake.chunk(Array(body[400...]))
        guard case .finished(_, _, let bytes, 400)? = intake.end() else {
            Issue.record("not finished from 400")
            return
        }
        #expect(bytes == body)
    }

    @Test func anOffsetPastTheKeptPrefixIsRefusedAndReadOnFromItsOffset() throws {
        var intake = FileIntake()
        let refused = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 200, offset: 800)
        #expect(resume(&intake, try kept(600), offset: 800, size: 200) == [.refused(refused, .notKept)])
        #expect(intake.arriving == nil && intake.isStreaming)
        // Read on from the offset, so an Android sender's window, which takes the offset off a report, hears of the tail.
        #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 800, total: 1000, from: 800))
        #expect(intake.chunk(Array(body[800...])) == nil)
        #expect(intake.reading?.bytes == 1000)
        #expect(intake.end() == nil, "its chunks and its end come to nothing")
    }

    @Test func aResumedHeaderForAnAvatarOrAMalformedKeyOrAWildOffsetIsRefusedUnread() throws {
        let store = try kept(600)
        var intake = FileIntake()
        let avatar = FileHeader(kind: .avatar, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(
            intake.header(header(.avatar, size: 400, offset: 600), limit: keepAll, prefix: store.read, now: 0) == [
                .refused(avatar, .notKept)
            ])
        let evil = FileHeader(kind: .attachment, key: "../evil", mime: "image/jpeg", size: 400, offset: 600)
        #expect(resume(&intake, store, offset: 600, size: 400, key: "../evil") == [.skipped(evil)])
        #expect(intake.reading == nil)
        for wild in [-5, FileIntake.maxFileBytes + 1, Int.max, Int.min] {
            let refused = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: wild)
            #expect(resume(&intake, store, offset: wild, size: 400) == [.refused(refused, .notKept)], "\(wild)")
            #expect(intake.reading == nil && intake.arriving == nil, "nothing to count from: \(wild)")
            #expect(intake.chunk([1]) == nil && intake.end() == nil)
        }
        #expect(store.reads == 0, "no prefix read for any")
    }

    @Test func anExplicitZeroOffsetIsAWholeFile() throws {
        let store = try kept(600)
        var intake = FileIntake()
        let whole = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 1000, offset: 0)
        #expect(resume(&intake, store, offset: 0, size: 1000) == [.begun(whole)])
        #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 0, total: 1000))
        _ = intake.chunk(body)
        #expect(intake.end() == .finished(whole, try hash(), body, resumedFrom: 0))
        #expect(store.reads == 0)
    }

    @Test func theCeilingCountsTheKeptPrefix() throws {
        let near = FileIntake.maxFileBytes - 10
        let store = Kept()
        store.prefixes[try hash()] = ([UInt8](repeating: 1, count: near), 1)
        var intake = FileIntake()
        _ = resume(&intake, store, offset: near, size: 100)
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 100, offset: near)
        #expect(intake.chunk([UInt8](repeating: 0, count: 20)) == .abandoned(resumed))
        #expect(intake.arriving == nil)
        #expect(intake.end() == nil)
    }

    @Test func theLargestSizeBesideAnOffsetNeverTraps() throws {
        // The blocking finding of the design pass: `offset + size` is bounded part by part, so no claim overflows.
        for size in [Int.max, Int.max - 599, FileIntake.maxFileBytes, -1] {
            var intake = FileIntake()
            _ = resume(&intake, try kept(600), offset: 600, size: size)
            #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 600, total: nil, from: 600), "\(size)")
            var skipped = FileIntake()
            _ = skipped.header(header(size: size, offset: 600), limit: { _, _ in nil }, prefix: { _, _ in nil }, now: 0)
            #expect(skipped.reading?.total == nil, "\(size)")
        }
        var intake = FileIntake()
        _ = resume(&intake, try kept(600), offset: 600, size: FileIntake.maxFileBytes - 600)
        #expect(intake.reading?.total == FileIntake.maxFileBytes, "the ceiling itself is a size")
    }

    @Test func aResumedHeaderNobodyWantsIsSkippedAndReadFromItsOffset() throws {
        let store = try kept(600)
        var intake = FileIntake()
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(intake.header(header(size: 400, offset: 600), limit: { _, _ in nil }, prefix: store.read, now: 0) == [.skipped(resumed)])
        #expect(intake.reading == FileIntake.Reading(key: try hash(), bytes: 600, total: 1000, from: 600))
        #expect(store.reads == 0, "the accept gate goes before the read")
    }

    @Test func aPrefixTheRoomCannotHoldIsRefusedUnread() throws {
        // Partial files on every link share one budget (ADR 2026-10.h6zz), and a resumed stream's prefix is in it.
        let store = try kept(600)
        var intake = FileIntake()
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(resume(&intake, store, offset: 600, size: 400, room: 599) == [.refused(resumed, .noRoom)])
        #expect(store.reads == 0)
        #expect(resume(&intake, store, offset: 600, size: 400, room: 600) == [.begun(resumed)], "and not stamped, so taken")
    }

    @Test func anAttachmentCutMidStreamIsHandedOverWithTheEpochItWasSplicedOnto() throws {
        var intake = FileIntake()
        _ = intake.header(header(size: 1000, offset: nil), limit: keepAll)
        _ = intake.chunk(Array(body.prefix(300)))
        guard let first = intake.cut() else {
            Issue.record("nothing handed over")
            return
        }
        #expect(first.key == (try hash()) && first.bytes == Array(body.prefix(300)) && first.basedOn == nil, "from byte 0")
        #expect(!intake.isStreaming && intake.reading == nil, "nothing is arriving on a closed link")
        let store = Kept()
        store.prefixes[try hash()] = (first.bytes, 3)
        var next = FileIntake()
        _ = resume(&next, store, offset: 300, size: 700)
        _ = next.chunk(Array(body[300..<800]))
        guard let second = next.cut() else {
            Issue.record("nothing handed over")
            return
        }
        #expect(second.bytes == Array(body.prefix(800)) && second.basedOn == 3, "the prefix and the tail since, on epoch 3")
        #expect(next.cut() == nil, "handed over once")
    }

    @Test func anAvatarASkippedFileOrOneAbortedAtItsLimitHandsNothingOver() {
        var avatar = FileIntake()
        _ = avatar.header(header(.avatar, size: 1000, offset: nil), limit: keepAll)
        _ = avatar.chunk(Array(body.prefix(900)))
        #expect(avatar.cut() == nil, "an avatar is pushed, never asked for")
        #expect(!avatar.isStreaming)
        var skipped = FileIntake()
        _ = skipped.header(header(size: 1000, offset: nil)) { _, _ in nil }
        _ = skipped.chunk([1])
        #expect(skipped.cut() == nil)
        var aborted = FileIntake()
        _ = aborted.header(header(size: 1000, offset: nil)) { _, _ in 4 }
        _ = aborted.chunk([1, 2, 3, 4, 5])
        #expect(aborted.cut() == nil)
        var replaced = FileIntake()
        _ = replaced.header(header(size: 1000, offset: nil), limit: keepAll)
        _ = replaced.chunk(Array(body.prefix(500)))
        _ = replaced.header(header(key: other, size: 10, offset: nil), limit: keepAll)
        #expect(replaced.cut()?.bytes.isEmpty == true, "a replacing header discarded the file it interrupted, so only the new one goes")
    }

    @Test func aPrefixThatComesUpShortIsRefusedAndItsStreamSkipped() {
        var intake = FileIntake()
        let short: (BlobHash, Int) -> (bytes: [UInt8], basedOn: Int)? = { _, _ in ([1, 2, 3], 1) }
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(intake.header(header(size: 400, offset: 600), limit: keepAll, prefix: short, now: 0) == [.refused(resumed, .notKept)])
        #expect(intake.arriving == nil)
        _ = intake.chunk(Array(body[600...]))
        #expect(intake.end() == nil)
    }

    @Test func anOffsetWrittenAsAFractionIsRefusedAndOneWrittenAsAnIntegralFloatIsTakenAsItsInteger() throws {
        // kotlinx refuses `600.0` and `6e2` for a Long; Foundation's decoder reads them as 600. No build writes either, and
        // the bytes they name are the same, so the port takes them; a fraction still refuses the header (`LinkTests`).
        let store = try kept(600)
        let fields = #""kind":"ATTACHMENT","key":"\#(key)","mime":"image/jpeg","size":400"#
        for written in ["600.0", "6e2"] {
            var intake = FileIntake()
            let events = intake.header(Array("{\(fields),\"offset\":\(written)}".utf8), limit: keepAll, prefix: store.read, now: 0)
            #expect(events == [.begun(FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600))], "\(written)")
        }
        var fraction = FileIntake()
        #expect(fraction.header(Array("{\(fields),\"offset\":600.5}".utf8), limit: keepAll, prefix: store.read, now: 0) == [.skipped(nil)])
    }
}

// The window (#161), apart so the suite stays in bounds.
extension FileIntakeResumeTests {
    /// Resumes `key` from 600 on `intake` at `now` and lets it end whole, as an honest holder's tail would.
    private func resumeWhole(_ intake: inout FileIntake, _ store: Kept, key: String? = nil, now: Int64) -> [UInt8]? {
        guard
            resume(&intake, store, offset: 600, size: 400, key: key, now: now).first.map({ if case .begun = $0 { true } else { false } })
                == true
        else {
            return nil
        }
        _ = intake.chunk(Array(body[600...]))
        guard case .finished(_, _, let bytes, _)? = intake.end() else {
            return nil
        }
        return bytes
    }

    @Test func aSecondResumeOfOneKeyInsideTheWindowIsRefusedBeforeItsPrefixIsRead() throws {
        let store = try kept(600)
        var intake = FileIntake()
        #expect(resumeWhole(&intake, store, now: 1000) == body)
        let reads = store.reads
        let late = 1000 + FileIntake.resumeWindowMilliseconds - 1
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(resume(&intake, store, offset: 600, size: 400, now: late) == [.refused(resumed, .resumedRecently(milliseconds: 44_999))])
        #expect(store.reads == reads, "no read was started")
        #expect(intake.arriving == nil)
        _ = intake.chunk(Array(body[600...]))
        #expect(intake.end() == nil, "its chunks and its end come to nothing")
        #expect(FileIntake.resumeWindowMilliseconds == 45_000)
    }

    @Test func aResumeOfOneKeyPastTheWindowIsTakenAgain() throws {
        let store = try kept(600)
        var intake = FileIntake()
        _ = resumeWhole(&intake, store, now: 0)
        #expect(resumeWhole(&intake, store, now: FileIntake.resumeWindowMilliseconds) == body, "spliced byte for byte")
    }

    @Test func theWindowIsPerKey() throws {
        let store = try kept(600)
        store.prefixes[try hash(other)] = (Array(body.prefix(600)), 8)
        var intake = FileIntake()
        _ = resumeWhole(&intake, store, now: 0)
        #expect(resumeWhole(&intake, store, key: other, now: 1) == body, "another blob's resume is its own")
    }

    @Test func aWholeFileOfAGatedKeyIsStillTaken() throws {
        let store = try kept(600)
        var intake = FileIntake()
        _ = resumeWhole(&intake, store, now: 0)
        let whole = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 1000)
        #expect(intake.header(header(size: 1000, offset: nil), limit: keepAll, prefix: store.read, now: 1) == [.begun(whole)])
        _ = intake.chunk(body)
        #expect(intake.end() == .finished(whole, try hash(), body, resumedFrom: 0))
    }

    @Test func aResumeRefusedForNoKeptPrefixLeavesTheWindowOpen() throws {
        // Nothing was read, so nothing is stamped. Kotlin stamps when the prefix opens, so a copy that then fails still
        // closes the window; here the read is the open, and a store whose read fails has retired the prefix besides.
        let store = Kept()
        var intake = FileIntake()
        let resumed = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 400, offset: 600)
        #expect(resume(&intake, store, offset: 600, size: 400, now: 0) == [.refused(resumed, .notKept)])
        store.prefixes[try hash()] = (Array(body.prefix(600)), 1)
        #expect(resumeWhole(&intake, store, now: 1) == body)
    }
}
