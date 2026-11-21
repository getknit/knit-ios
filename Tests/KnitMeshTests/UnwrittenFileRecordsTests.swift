import Testing

@testable import KnitMesh

/// The FILE records a feed handed a reporting radio and has not heard reported, and how much of a link's level is theirs
/// (the `custody-carry-policy` contract, §2's "Unwritten"). Levels are what a radio's ``OutboxLevels`` would read.
@Suite struct UnwrittenFileRecordsTests {
    /// A 16 KiB chunk's record: its 3-byte header and its bytes.
    private let chunk = 16_387

    @Test func aRecordHandedOverIsAllUnwrittenUntilTheRadioWritesIt() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: 200 + chunk, writtenBytes: 1000))
        #expect(records.count == 1)
        let level = OutboxLevel(queuedBytes: 200 + chunk + 500, writtenBytes: 1000)
        #expect(records.fileBytes(of: level) == chunk)
        #expect(records.frameBytes(of: level) == 700, "the 200 ahead of it and the 500 behind it")
    }

    @Test func aRecordPartlyWrittenLeavesOnlyWhatIsLeftOut() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        let half = OutboxLevel(queuedBytes: chunk - 8192 + 500, writtenBytes: 1000 + 8192)
        #expect(records.fileBytes(of: half) == chunk - 8192)
        #expect(records.frameBytes(of: half) == 500, "the bytes already written are not taken from the frames behind it")
    }

    @Test func aRecordWrittenAndNotYetReportedLeavesNothingOut() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        let out = OutboxLevel(queuedBytes: 500, writtenBytes: 1000 + Int64(chunk))
        #expect(records.fileBytes(of: out) == 0)
        #expect(records.frameBytes(of: out) == 500)
        #expect(records.count == 1, "still waiting for its report, which brings the next chunk")
    }

    @Test func aLevelThatHasNotCountedTheRecordStillPlacesAllOfItUnwritten() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: 0, writtenBytes: 1000))
        #expect(records.fileBytes(of: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000)) == chunk)
    }

    @Test func eachRecordIsTakenFromWhereItEnds() {
        var records = UnwrittenFileRecords()
        records.handed(100, level: OutboxLevel(queuedBytes: 100, writtenBytes: 0))
        records.handed(chunk, level: OutboxLevel(queuedBytes: 100 + 50 + chunk, writtenBytes: 0))
        // The first record is out, then 50 bytes of frames, then 10 bytes of the second.
        let level = OutboxLevel(queuedBytes: chunk - 10, writtenBytes: 160)
        #expect(records.fileBytes(of: level) == chunk - 10)
        #expect(records.frameBytes(of: level) == 0)
        records.reported(level: level)
        #expect(records.count == 1, "oldest first")
        #expect(records.records.count == 1, "the first is sent, so it goes")
        #expect(records.fileBytes(of: level) == chunk - 10)
    }

    @Test func aReportWithNothingOutChangesNothing() {
        var records = UnwrittenFileRecords()
        records.reported(level: OutboxLevel())
        #expect(records.isEmpty)
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk))
        let sent = OutboxLevel(writtenBytes: Int64(chunk))
        records.reported(level: sent)
        records.reported(level: sent)
        #expect(records.isEmpty, "never below zero")
        #expect(records == UnwrittenFileRecords())
    }

    @Test func anEmptyRecordIsNotKept() {
        var records = UnwrittenFileRecords()
        records.handed(0, level: OutboxLevel())
        #expect(records.isEmpty)
    }

    @Test func neitherCountGoesBelowZeroNorPastWhatIsQueued() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 0))
        // A radio that dropped the channel's queue, or counts it closed, reads nothing queued.
        #expect(records.fileBytes(of: OutboxLevel()) == 0)
        #expect(records.frameBytes(of: OutboxLevel()) == 0)
        let fewer = OutboxLevel(queuedBytes: 300, writtenBytes: 0)
        #expect(records.fileBytes(of: fewer) == 300)
        #expect(records.frameBytes(of: fewer) == 0)
        #expect(records.frameBytes(of: OutboxLevel(queuedBytes: -5, writtenBytes: 0)) == 0)
    }

    // MARK: The buffer below the link

    @Test func aChunkTheSocketHoldsIsStillAFilesAndTheFramesBehindItCount() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        let held = OutboxLevel(queuedBytes: 500, writtenBytes: 1000 + Int64(chunk), belowBytes: chunk)
        #expect(records.fileBytes(of: held) == chunk, "written to the socket, not yet sent")
        #expect(records.frameBytes(of: held) == 500)
        let draining = OutboxLevel(queuedBytes: 500, writtenBytes: 1000 + Int64(chunk), belowBytes: chunk - 4000)
        #expect(records.fileBytes(of: draining) == chunk - 4000)
        #expect(records.frameBytes(of: draining) == 500)
        let sent = OutboxLevel(queuedBytes: 0, writtenBytes: 1000 + Int64(chunk) + 500, belowBytes: 500)
        #expect(records.fileBytes(of: sent) == 0)
        #expect(records.frameBytes(of: sent) == 500, "the frames behind it, now in the socket")
    }

    @Test func framesTheSocketHoldsAheadOfAChunkCount() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: 300 + chunk, writtenBytes: 1000))
        let held = OutboxLevel(queuedBytes: 0, writtenBytes: 1300 + Int64(chunk), belowBytes: 300 + chunk)
        #expect(records.fileBytes(of: held) == chunk)
        #expect(records.frameBytes(of: held) == 300)
    }

    @Test func aBelowReadPastWhatWasWrittenStaysInBounds() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 0))
        let odd = OutboxLevel(queuedBytes: 0, writtenBytes: 100, belowBytes: 90_000)
        #expect(records.fileBytes(of: odd) == chunk)
        #expect(records.frameBytes(of: odd) == 90_000 - chunk)
    }

    // MARK: Reported, and still in the socket

    @Test func aRecordReportedWhileTheSocketHoldsItIsStillAFiles() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        // BlueZ reports it once the socket takes its last byte: all of it is still there.
        let taken = OutboxLevel(queuedBytes: 0, writtenBytes: 1000 + Int64(chunk), belowBytes: chunk)
        records.reported(level: taken)
        #expect(records.allReported, "the feed's next record may go: the report gates it, as before")
        #expect(records.records.count == 1, "kept until it leaves the socket")
        #expect(records.fileBytes(of: taken) == chunk)
        #expect(records.frameBytes(of: taken) == 0)
        let draining = OutboxLevel(queuedBytes: 0, writtenBytes: 1000 + Int64(chunk), belowBytes: 4000)
        records.prune(draining)
        #expect(records.records.count == 1)
        #expect(records.frameBytes(of: draining) == 0)
    }

    @Test func aReportedRecordLeavesOnceWhatLeftTheSocketPassesItsEnd() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        records.reported(level: OutboxLevel(writtenBytes: 1000 + Int64(chunk), belowBytes: 1))
        #expect(records.records.count == 1, "one byte short")
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000 + Int64(chunk), belowBytes: 0))
        #expect(records.records.count == 1, "the first went at the next hand-off; the second is out")
        #expect(records.count == 1)
    }

    @Test func withNothingEverBelowAReportedRecordGoesAtOnce() {
        var records = UnwrittenFileRecords()
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: 1000))
        let written = OutboxLevel(queuedBytes: 300, writtenBytes: 1000 + Int64(chunk))
        records.reported(level: written)
        #expect(records == UnwrittenFileRecords(), "as on CoreBluetooth, where the report is the send")
        #expect(records.frameBytes(of: written) == 300)
    }

    @Test func aSocketThatNeverDrainsKeepsNoMoreThanTheCap() {
        var records = UnwrittenFileRecords()
        var written: Int64 = 0
        for _ in 0..<(UnwrittenFileRecords.maximumKept + 10) {
            records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: written, belowBytes: Int(written)))
            written += Int64(chunk)
            records.reported(level: OutboxLevel(writtenBytes: written, belowBytes: Int(written)))
        }
        #expect(records.records.count <= UnwrittenFileRecords.maximumKept)
        #expect(records.allReported)
        records.handed(chunk, level: OutboxLevel(queuedBytes: chunk, writtenBytes: written, belowBytes: Int(written)))
        #expect(records.records.count == UnwrittenFileRecords.maximumKept, "the oldest reported goes, never the one unreported")
        #expect(records.count == 1)
    }
}

extension UnwrittenFileRecords {
    /// Whether no record is out: a read of the records for the tests, kept out of `Sources` so the analyzer finds no
    /// declaration there that only tests call.
    var isEmpty: Bool { records.isEmpty }

    /// How many records are out and not reported.
    var count: Int { records.count { !$0.reported } }
}
