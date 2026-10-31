import KnitWire
import Testing

/// What the intake tells its owner of a file past the limit it gave (ADR 2026-10.r88m): ``FileIntake/Event/overLimit(_:)``
/// when that limit binds, on a chunk or at a header declaring more for a limit below Android's ceiling, and
/// ``FileIntake/Event/abandoned(_:)`` when only the room, or another header, cut it short.
@Suite struct FileIntakeLimitTests {
    private let key = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let photo = FileIntake.maxAvatarBytes

    private func header(_ kind: FileHeader.Kind = .attachment, size: Int? = nil, offset: Int? = nil) -> [UInt8] {
        LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: key, mime: "image/jpeg", size: size, offset: offset))
    }

    private func parsed(_ kind: FileHeader.Kind = .attachment, size: Int? = nil, offset: Int? = nil) -> FileHeader {
        FileHeader(kind: kind, key: key, mime: "image/jpeg", size: size, offset: offset)
    }

    @Test func theAvatarCeilingIsOneMebibyte() {
        #expect(FileIntake.maxAvatarBytes == 1_048_576)
    }

    @Test func aHeaderDeclaringMoreThanALimitBelowTheCeilingIsRefusedAtOnce() throws {
        var intake = FileIntake()
        let events = intake.header(header(.avatar, size: photo + 1)) { _, _ in photo }
        #expect(events == [.overLimit(parsed(.avatar, size: photo + 1))])
        #expect(intake.arriving == nil, "nothing kept")
        let hash = try #require(BlobHash(key))
        #expect(intake.reading == FileIntake.Reading(key: hash, bytes: 0, total: photo + 1), "read past, so its sender is told")
        #expect(intake.chunk([1, 2, 3]) == nil)
        #expect(intake.end() == nil)
    }

    @Test func aHeaderDeclaringExactlyTheLimitIsKept() {
        var intake = FileIntake()
        #expect(intake.header(header(.avatar, size: photo)) { _, _ in photo } == [.begun(parsed(.avatar, size: photo))])
        #expect(intake.arriving != nil)
    }

    @Test func aHeaderPastTheCeilingOrWithANegativeSizeIsJudgedWithoutTrapping() {
        var huge = FileIntake()
        #expect(huge.header(header(size: .max)) { _, _ in photo } == [.overLimit(parsed(size: .max))])
        var negative = FileIntake()
        #expect(negative.header(header(size: -5)) { _, _ in photo } == [.begun(parsed(size: -5))], "a negative size claims nothing")
    }

    @Test func anAttachmentsHeaderIsNeverRefusedForItsSizeAsAndroidsIsNot() {
        var intake = FileIntake()
        let declared = FileIntake.maxFileBytes * 2
        #expect(intake.header(header(size: declared)) { _, _ in .max } == [.begun(parsed(size: declared))])
    }

    @Test func aResumedHeaderIsJudgedByItsOffsetAndTailTogether() {
        // Each under the limit, the two together over it: the whole blob is what the limit bounds.
        var intake = FileIntake()
        let events = intake.header(
            header(size: photo / 2 + 1, offset: photo / 2), room: .max, limit: { _, _ in photo }, prefix: { _, _ in nil }, now: 0)
        #expect(events == [.overLimit(parsed(size: photo / 2 + 1, offset: photo / 2))])
    }

    @Test func aChunkPastTheOwnersLimitIsOverItAndOnePastTheRoomIsAbandoned() {
        var limited = FileIntake()
        _ = limited.header(header(.avatar)) { _, _ in 4 }
        #expect(limited.chunk([1, 2, 3, 4]) == nil)
        #expect(limited.chunk([5]) == .overLimit(parsed(.avatar)))
        #expect(limited.chunk([6]) == nil, "read past")

        var roomy = FileIntake()
        _ = roomy.header(header(.avatar)) { _, _ in 4 }
        #expect(roomy.chunk([1, 2, 3], room: 2) == .abandoned(parsed(.avatar)), "the room bound, not the file's limit")

        var cut = FileIntake()
        _ = cut.header(header()) { _, _ in .max }
        #expect(cut.header(header()) { _, _ in .max }.first == .abandoned(parsed()), "another header cuts it short")
    }
}
