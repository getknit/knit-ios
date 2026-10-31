import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// What a link keeps of a profile photo (ADR 2026-10.r88m): an ATTACHMENT wanted only as a photo, and a peer's own AVATAR
/// push, to ``FileIntake/maxAvatarBytes``, and a file past it reported once with the neighbour that sent it. A file the
/// room every link shares cut short is no such report.
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
        #expect(overLimits(atHeader) == [.fileOverLimit(hash, from: LinkRig.low)], "before a byte of it is kept")
        #expect(rig.links.arrivingFiles.isEmpty)
        let rest = rig.handle(.received(channel, Array(records(.avatar, file).dropFirst(header.encoded?.count ?? 0))))
        #expect(files(rest).isEmpty && overLimits(rest).isEmpty, "read past, never kept, reported once")
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
