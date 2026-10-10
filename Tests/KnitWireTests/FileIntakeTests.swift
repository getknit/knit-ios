import KnitWire
import Testing

/// The receiving end of a link's file stream, against Android's receiver rules (`FramedLink.kt:402-520`) and
/// `FramedLinkTest`'s cases: `attachmentFileStreamsReassemblesAndFinalizes` and
/// `malformedBlobKeyRejectsFileWithoutCallback`, plus the rules no Kotlin test pins: the 8 MiB and 64 KiB ceiling, a
/// second header mid-file, and a chunk or END with no header.
@Suite struct FileIntakeTests {
    private let key = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let other = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"

    private func header(_ kind: FileHeader.Kind = .attachment, key: String? = nil, mime: String = "image/jpeg") -> [UInt8] {
        LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: key ?? self.key, mime: mime))
    }

    private func keepAll(_: FileHeader, _: BlobHash) -> Int? { .max }

    @Test func aWholeFileArrivesAsItsChunksInOrder() throws {
        var intake = FileIntake()
        #expect(intake.header(header(), limit: keepAll) == [.begun(FileHeader(kind: .attachment, key: key, mime: "image/jpeg"))])
        #expect(intake.arriving == BlobHash(key))
        #expect(intake.chunk([1, 2, 3]) == nil)
        #expect(intake.chunk([4]) == nil)
        #expect(intake.bufferedBytes == 4)
        let hash = try #require(BlobHash(key))
        #expect(intake.end() == .finished(FileHeader(kind: .attachment, key: key, mime: "image/jpeg"), hash, [1, 2, 3, 4]))
        #expect(intake.arriving == nil)
        #expect(intake.bufferedBytes == 0)
    }

    @Test func aFileIsStreamingFromItsHeaderToItsEndWhetherKeptOrSkipped() {
        // A skipped file holds the link as a kept one does (knit-next ADR 2026-10.nxfb), so both count.
        var kept = FileIntake()
        #expect(!kept.isStreaming)
        _ = kept.header(header(), limit: keepAll)
        #expect(kept.isStreaming)
        _ = kept.end()
        #expect(!kept.isStreaming)
        var skipped = FileIntake()
        _ = skipped.header(header()) { _, _ in nil }
        #expect(skipped.isStreaming && skipped.arriving == nil)
        _ = skipped.chunk([1])
        #expect(skipped.isStreaming)
        _ = skipped.end()
        #expect(!skipped.isStreaming)
        var unreadable = FileIntake()
        _ = unreadable.header([0x7B], limit: keepAll)
        #expect(unreadable.isStreaming)
        unreadable.reset()
        #expect(!unreadable.isStreaming)
    }

    @Test func anEmptyFileIsAHeaderAndAnEnd() throws {
        var intake = FileIntake()
        _ = intake.header(header(.avatar), limit: keepAll)
        let hash = try #require(BlobHash(key))
        #expect(intake.end() == .finished(FileHeader(kind: .avatar, key: key, mime: "image/jpeg"), hash, []))
    }

    @Test func aChunkOrAnEndWithNoHeaderIsIgnored() {
        var intake = FileIntake()
        #expect(intake.chunk([1, 2]) == nil)
        #expect(intake.end() == nil)
        #expect(intake.arriving == nil)
    }

    @Test func aSecondHeaderDropsThePartialFileAndStartsAgain() throws {
        var intake = FileIntake()
        _ = intake.header(header(), limit: keepAll)
        _ = intake.chunk([9, 9])
        let events = intake.header(header(key: other), limit: keepAll)
        #expect(
            events == [
                .abandoned(FileHeader(kind: .attachment, key: key, mime: "image/jpeg")),
                .begun(FileHeader(kind: .attachment, key: other, mime: "image/jpeg")),
            ])
        _ = intake.chunk([5])
        let hash = try #require(BlobHash(other))
        #expect(intake.end() == .finished(FileHeader(kind: .attachment, key: other, mime: "image/jpeg"), hash, [5]))
    }

    @Test func aFilePastItsLimitIsDroppedAndItsRestIgnored() throws {
        var intake = FileIntake()
        _ = intake.header(header()) { _, _ in 4 }
        #expect(intake.chunk([1, 2, 3, 4]) == nil)
        #expect(intake.chunk([5]) == .abandoned(FileHeader(kind: .attachment, key: key, mime: "image/jpeg")))
        #expect(intake.arriving == nil)
        #expect(intake.chunk([6]) == nil)
        #expect(intake.reading == FileIntake.Reading(key: try #require(BlobHash(key)), bytes: 6, total: nil), "read on, not kept")
        #expect(intake.end() == nil, "abortRx: the END of a dropped file yields nothing")
        #expect(intake.reading == nil)
    }

    @Test func noFileGrowsPastAndroidsCeiling() {
        var intake = FileIntake()
        _ = intake.header(header(), limit: keepAll)
        #expect(intake.chunk([UInt8](repeating: 0, count: FileIntake.maxFileBytes)) == nil)
        #expect(intake.chunk([0]) == .abandoned(FileHeader(kind: .attachment, key: key, mime: "image/jpeg")))
        #expect(intake.reading == nil, "Android aborts it there, and reports nothing more")
        #expect(intake.isStreaming, "the link is still held to its END")
        #expect(FileIntake.maxFileBytes == 8_454_144)
    }

    @Test func aSkippedFileIsReadUpToAndroidsCeilingAndNoFurther() throws {
        var intake = FileIntake()
        let sized = FileHeader(kind: .attachment, key: key, mime: "image/jpeg", size: 6)
        _ = intake.header(LinkJSON.fileHeaderPayload(sized)) { _, _ in nil }
        let hash = try #require(BlobHash(key))
        #expect(intake.reading == FileIntake.Reading(key: hash, bytes: 0, total: 6))
        #expect(intake.chunk([1, 2]) == nil)
        #expect(intake.reading == FileIntake.Reading(key: hash, bytes: 2, total: 6))
        #expect(intake.arriving == nil && intake.bufferedBytes == 0, "nothing kept")
        _ = intake.chunk([UInt8](repeating: 0, count: FileIntake.maxFileBytes - 2))
        #expect(intake.reading?.bytes == FileIntake.maxFileBytes)
        _ = intake.chunk([0])
        #expect(intake.reading == nil)
    }

    @Test func theOwnersRoomCanStopAFileShortOfItsLimit() {
        var intake = FileIntake()
        _ = intake.header(header(), limit: keepAll)
        #expect(intake.chunk([1, 2], room: 3) == nil)
        #expect(intake.chunk([3, 4], room: 3) == .abandoned(FileHeader(kind: .attachment, key: key, mime: "image/jpeg")))
    }

    @Test func aMalformedKeyOrHeaderIsSkippedWithoutAskingTheOwner() {
        var asked = 0
        var intake = FileIntake()
        let malformed = [String(key.dropLast()), key.uppercased(), key + "0", "g" + String(key.dropFirst())]
        for bad in malformed {
            let events = intake.header(header(key: bad)) { _, _ in
                asked += 1
                return .max
            }
            #expect(events == [.skipped(FileHeader(kind: .attachment, key: bad, mime: "image/jpeg"))])
            #expect(intake.chunk([1]) == nil)
            #expect(intake.end() == nil)
        }
        #expect(intake.header(Array("not json".utf8), limit: keepAll) == [.skipped(nil)])
        #expect(asked == 0)
    }

    @Test func aRefusedFileIsSkippedToItsEnd() {
        var intake = FileIntake()
        let refused = intake.header(header()) { _, _ in nil }
        #expect(refused == [.skipped(FileHeader(kind: .attachment, key: key, mime: "image/jpeg"))])
        #expect(intake.arriving == nil)
        #expect(intake.chunk([1, 2]) == nil)
        #expect(intake.end() == nil)
        #expect(intake.header(header(), limit: keepAll) == [.begun(FileHeader(kind: .attachment, key: key, mime: "image/jpeg"))])
    }

    @Test func aResetDropsThePartialFile() {
        var intake = FileIntake()
        _ = intake.header(header(), limit: keepAll)
        _ = intake.chunk([1])
        intake.reset()
        #expect(intake.arriving == nil)
        #expect(intake.end() == nil)
    }

    @Test func blobHashesAreSixtyFourLowercaseHexCharacters() throws {
        #expect(BlobHash(key)?.string == key)
        #expect(BlobHash(key.uppercased()) == nil)
        #expect(BlobHash(String(key.dropLast())) == nil)
        #expect(BlobHash("") == nil)
        #expect(BlobHash(digest: [UInt8](repeating: 0xAB, count: 32))?.string == String(repeating: "ab", count: 32))
        #expect(BlobHash(digest: [1, 2]) == nil)
        let low = try #require(BlobHash(String(repeating: "0", count: 64)))
        let high = try #require(BlobHash(String(repeating: "f", count: 64)))
        #expect(low < high)
        #expect("\(low)" == low.string)
    }
}
