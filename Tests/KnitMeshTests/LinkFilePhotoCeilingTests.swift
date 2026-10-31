import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// What a link keeps of a profile photo (ADR 2026-10.r88m): an ATTACHMENT wanted only as a photo, and a peer's own AVATAR
/// push, to ``FileIntake/maxAvatarBytes``. Only the ATTACHMENT kept under that ceiling at its header is reported past
/// it, once, with the neighbour that sent it; a pushed AVATAR past it is dropped and counted and names nobody (contract
/// `ios-avatar-push-mark`, `ceilingOf` and `refuseOver` in knit-next's `FileIntake.kt:344-363` and `:388-398` at
/// `a0b52f865`). A file the room every link shares cut short is no such report.
@Suite struct LinkFilePhotoCeilingTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)
    private let ceiling = FileIntake.maxAvatarBytes

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    /// `file`'s header, declaring `size`, its chunks and its END, as one read.
    private func records(_ kind: FileHeader.Kind, _ file: [UInt8], size: Int? = nil, chunk: Int = 16 * 1024) -> [UInt8] {
        let header = LinkRecord(
            .fileHeader,
            payload: LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: BlobHash(of: file).string, mime: "image/jpeg", size: size)))
        let chunks = stride(from: 0, to: file.count, by: chunk).map { start in
            LinkRecord(.fileChunk, payload: Array(file[start..<min(start + chunk, file.count)]))
        }
        return ([header] + chunks + [LinkRecord(.fileEnd)]).compactMap(\.encoded).flatMap(\.self)
    }

    private func overLimits(_ events: [LinkManager.Event]) -> [LinkManager.Event] {
        events.filter { if case .fileOverLimit = $0 { true } else { false } }
    }

    private func files(_ events: [LinkManager.Event]) -> [InboundFile] {
        events.compactMap { if case .file(let file) = $0 { file } else { nil } }
    }

    @Test func aPhotoOnlyFetchPastTheCeilingIsReportedOnceAndNothingLands() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(ceiling + 1)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash], resumable: [hash], photoOnly: [hash])
        let events = rig.handle(.received(channel, records(.attachment, file)))
        #expect(overLimits(events) == [.fileOverLimit(hash, from: LinkRig.low)])
        #expect(files(events).isEmpty && rig.links.filesReceived == 0)
        #expect(rig.links.filesRefused == 1)
    }

    @Test func aPhotoAtTheCeilingLandsAndAnAttachmentPastItToo() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let photo = bytes(ceiling)
        let attachment = bytes(ceiling + 1, seed: 2)
        rig.links.acceptFiles([BlobHash(of: photo), BlobHash(of: attachment)], resumable: [], photoOnly: [BlobHash(of: photo)])
        let first = rig.handle(.received(channel, records(.attachment, photo)))
        let second = rig.handle(.received(channel, records(.attachment, attachment)))
        #expect(files(first).map(\.hash) == [BlobHash(of: photo)])
        #expect(files(second).map(\.hash) == [BlobHash(of: attachment)], "an attachment keeps Android's ceiling")
        #expect(overLimits(first + second).isEmpty)
    }

    @Test func aPushDeclaringMoreThanTheCeilingIsRefusedAtItsHeader() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(ceiling + 1)
        let hash = BlobHash(of: file)
        let header = LinkRecord(
            .fileHeader,
            payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .avatar, key: hash.string, mime: "image/jpeg", size: file.count)))
        let atHeader = rig.handle(.received(channel, header.encoded ?? []))
        #expect(overLimits(atHeader).isEmpty, "a push answers no want, so it names nobody")
        #expect(rig.links.filesRefused == 1, "refused before a byte of it is kept")
        #expect(rig.links.arrivingFiles.isEmpty)
        let rest = rig.handle(.received(channel, Array(records(.avatar, file).dropFirst(header.encoded?.count ?? 0))))
        #expect(files(rest).isEmpty && overLimits(rest).isEmpty, "read past, never kept")
        // Android's facts after the frozen words: the ceiling, the kind, the declared size, the peer.
        let line = "dropped before its end: over its limit of \(ceiling)B, AVATAR \(file.count)B from \(LinkRig.low)"
        #expect(rig.log.all.contains { $0.contains(line) })
    }

    /// `aPushedAvatarOneByteOverThePhotoCeilingKeepsNothingAndOneAtItIsKept` (knit-next `FileIntakeTest.kt:194-210` at
    /// `a0b52f865`): with no size declared, a push one byte past the ceiling keeps nothing and marks nobody, and one at
    /// it lands. The hash is accepted and wanted only as a photo too, so the push meets a standing photo-only want of its
    /// own hash and still names nobody (trial run 20261031-021140).
    @Test func aPushedAvatarOneByteOverThePhotoCeilingKeepsNothingAndOneAtItIsKept() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let over = bytes(ceiling + 1)
        let at = bytes(ceiling, seed: 2)
        let keys: Set = [BlobHash(of: over), BlobHash(of: at)]
        rig.links.acceptFiles(keys, resumable: keys, photoOnly: keys)
        let past = rig.handle(.received(channel, records(.avatar, over)))
        #expect(files(past).isEmpty, "past the ceiling the file is gone")
        #expect(overLimits(past).isEmpty, "a pushed avatar marks nobody")
        #expect(rig.links.filesRefused == 1)
        #expect(rig.links.arrivingFiles.isEmpty)
        #expect(rig.log.all.contains { $0.contains("over its limit of \(ceiling)B, AVATAR ?B from \(LinkRig.low)") })
        let kept = rig.handle(.received(channel, records(.avatar, at, size: at.count)))
        #expect(files(kept).map(\.hash) == [BlobHash(of: at)] && files(kept).first?.bytes.count == ceiling)
        #expect(overLimits(kept).isEmpty)
    }

    /// `anAvatarHeaderDeclaringMoreThanThePhotoCeilingIsSkipped` (knit-next `FileIntakeTest.kt:212-221` at `a0b52f865`):
    /// nothing is arriving, and its chunks and END come to nothing, under a standing photo-only want of the same hash.
    @Test func anAvatarHeaderDeclaringMoreThanThePhotoCeilingIsSkipped() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(ceiling + 1)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash], resumable: [hash], photoOnly: [hash])
        let events = rig.handle(.received(channel, records(.avatar, file, size: ceiling + 1)))
        #expect(rig.links.arrivingFiles.isEmpty && rig.links.arrivingFileKeys.isEmpty, "nothing is arriving")
        #expect(files(events).isEmpty, "its chunks and its end come to nothing")
        #expect(overLimits(events).isEmpty)
        #expect(rig.links.filesRefused == 1)
    }

    /// A header and no END, then chunks of up to 256 KiB, for a stream whose bytes need not hash to its key.
    private func header(_ hash: BlobHash) -> [UInt8] {
        LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: hash.string, mime: "image/jpeg")))
            .encoded ?? []
    }

    private func chunks(_ count: Int) -> [UInt8] {
        stride(from: 0, to: count, by: 256 * 1024).compactMap { start in
            LinkRecord(.fileChunk, payload: [UInt8](repeating: 0, count: min(256 * 1024, count - start))).encoded
        }.flatMap(\.self)
    }

    /// Whether a stream marks is read at its header (`ceilingOf`, knit-next `FileIntake.kt:344-363` at `a0b52f865`): an
    /// attachment begun under Android's ceiling and made photo-only mid-stream keeps the ceiling it began under, and
    /// passing it names nobody.
    @Test func anAttachmentMadePhotoOnlyMidStreamNamesNobodyPastItsCeiling() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let hash = BlobHash(of: bytes(1))
        rig.links.acceptFiles([hash], resumable: [hash])
        let begun = rig.handle(.received(channel, header(hash) + chunks(1024)))
        rig.links.acceptFiles([hash], resumable: [hash], photoOnly: [hash])
        let rest = rig.handle(.received(channel, chunks(FileIntake.maxFileBytes + 1 - 1024)))
        #expect(rig.links.filesRefused == 1, "past Android's ceiling")
        #expect(overLimits(begun + rest).isEmpty, "begun under a ceiling that marks nobody")
    }

    /// And the reverse: one begun under a photo-only want's ceiling and widened mid-stream is cut at the ceiling it began
    /// under, and names its sender.
    @Test func anAttachmentWidenedMidStreamStillNamesItsSenderPastThePhotoCeiling() {
        var configuration = LinkManager.Configuration()
        configuration.maxAvatarFileBytes = 1024
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let hash = BlobHash(of: bytes(1))
        rig.links.acceptFiles([hash], resumable: [hash], photoOnly: [hash])
        let begun = rig.handle(.received(channel, header(hash) + chunks(512)))
        rig.links.acceptFiles([hash], resumable: [hash])
        let rest = rig.handle(.received(channel, chunks(1024)))
        #expect(overLimits(begun).isEmpty)
        #expect(overLimits(rest) == [.fileOverLimit(hash, from: LinkRig.low)])
        #expect(rig.links.filesRefused == 1)
    }

    @Test func aFileTheSharedRoomCutShortIsNoOverLimit() {
        var configuration = LinkManager.Configuration()
        configuration.maxBufferedFileBytes = 10
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let first = bytes(12)
        let second = bytes(12, seed: 2)
        let keys: Set = [BlobHash(of: first), BlobHash(of: second)]
        rig.links.acceptFiles(keys, resumable: keys, photoOnly: keys)
        let partial = { (file: [UInt8]) in
            [
                LinkRecord(
                    .fileHeader,
                    payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "x"))),
                LinkRecord(.fileChunk, payload: Array(file.prefix(6))),
            ].compactMap(\.encoded).flatMap(\.self)
        }
        let events = rig.handle(.received(channel, partial(first))) + rig.handle(.received(other, partial(second)))
        #expect(rig.links.filesRefused == 1, "the second link ran out of room")
        #expect(overLimits(events).isEmpty, "the room is no holder's fault: nobody is passed over")
    }
}
