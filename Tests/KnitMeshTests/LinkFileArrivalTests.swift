import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// How far each kept file streaming in has got, for the app's ring (`arrivingFiles()`, knit-next ADR 2026-10.y9qh):
/// a kept file only, the copy furthest along when two links stream one, and never a file past its END, which the engine
/// stores in the same turn of the actor. Its keys stay among ``LinkManager/arrivingFileKeys`` at every step.
@Suite struct LinkFileArrivalTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func header(_ file: [UInt8], kind: FileHeader.Kind = .attachment, size: Int?? = .none) -> [UInt8] {
        let declared = size ?? file.count
        let header = FileHeader(kind: kind, key: BlobHash(of: file).string, mime: "image/jpeg", size: declared)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    private func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        LinkRecord(.fileChunk, payload: Array(bytes)).encoded ?? []
    }

    private var end: [UInt8] { LinkRecord(.fileEnd).encoded ?? [] }

    private func reading(_ file: [UInt8], _ bytes: Int, of total: Int?) -> FileIntake.Reading {
        FileIntake.Reading(key: BlobHash(of: file), bytes: bytes, total: total)
    }

    /// The map's keys are among the files on their way in, whatever just happened.
    private func expectWithinArriving(_ rig: LinkRig, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Set(rig.links.arrivingFiles.keys).isSubset(of: rig.links.arrivingFileKeys), "\(step)", sourceLocation: sourceLocation)
    }

    @Test func aKeptFileReadsFromNothingOfItsDeclaredSizeAndEachChunkCounts() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(4096)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash])
        #expect(rig.links.arrivingFiles.isEmpty)
        _ = rig.handle(.received(channel, header(file)))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 0, of: 4096)])
        expectWithinArriving(rig, "header")
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 1024, of: 4096)])
        expectWithinArriving(rig, "chunk")
        _ = rig.handle(.received(channel, chunk(file[1024...])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 4096, of: 4096)])
        _ = rig.handle(.received(channel, end))
        #expect(rig.links.arrivingFiles.isEmpty, "landed, the engine's to store in this turn")
        #expect(rig.links.arrivingFileKeys == [hash], "still on its way until the engine takes it")
        expectWithinArriving(rig, "end")
        rig.links.fileTaken(from: LinkRig.low, hash: hash)
        #expect(rig.links.arrivingFiles.isEmpty && rig.links.arrivingFileKeys.isEmpty)
        expectWithinArriving(rig, "taken")
    }

    @Test func aSkippedFileNeverShows() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let unasked = bytes(4096, seed: 2)
        _ = rig.handle(.received(channel, header(unasked)))
        let reports = rig.handle(.received(channel, chunk(unasked[0..<2048])))
        #expect(!reports.isEmpty, "its sender still hears of it")
        #expect(rig.links.isFileArriving(from: LinkRig.low))
        #expect(rig.links.arrivingFiles.isEmpty)
        expectWithinArriving(rig, "skipped")
    }

    @Test func aFileThatDeclaresNoSizeOrOnePastTheCeilingReadsWithNoTotal() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(2048)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash])
        _ = rig.handle(.received(channel, header(file, size: .some(nil))))
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 1024, of: nil)], "no size declared")
        _ = rig.handle(.received(channel, header(file, size: FileIntake.maxFileBytes + 1)))
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 1024, of: nil)], "a size past the ceiling is none")
        expectWithinArriving(rig, "undeclared")
    }

    @Test func aCutLinkDropsItsFile() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(4096)
        rig.links.acceptFiles([BlobHash(of: file)])
        _ = rig.handle(.received(channel, header(file) + chunk(file[0..<1024])))
        #expect(rig.links.arrivingFiles.count == 1)
        _ = rig.handle(.closed(channel))
        #expect(rig.links.arrivingFiles.isEmpty)
        expectWithinArriving(rig, "cut")
    }

    @Test func aFileAbandonedPastItsLimitLeavesWhileItsSenderIsStillTold() {
        var configuration = LinkManager.Configuration()
        configuration.maxAvatarFileBytes = 1024
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let avatar = bytes(4096, seed: 5)
        let hash = BlobHash(of: avatar)
        _ = rig.handle(.received(channel, header(avatar, kind: .avatar)))
        #expect(rig.links.arrivingFiles == [hash: reading(avatar, 0, of: 4096)], "a peer's own photo is kept unasked")
        let reports = rig.handle(.received(channel, chunk(avatar[0..<2048])))
        #expect(reports == [.fileProgress(FileProgress(from: LinkRig.low, hash: hash, held: 2048, milliseconds: 0))])
        #expect(rig.links.arrivingFiles.isEmpty, "past its limit, no longer kept")
        #expect(rig.links.filesRefused == 1)
        expectWithinArriving(rig, "abandoned")
    }

    @Test func aReplacingHeaderDropsTheFileItCutsAndShowsItsOwnFromNothing() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let first = bytes(4096)
        let second = bytes(2048, seed: 3)
        let unasked = bytes(1024, seed: 4)
        rig.links.acceptFiles([BlobHash(of: first), BlobHash(of: second)])
        _ = rig.handle(.received(channel, header(first) + chunk(first[0..<1024])))
        _ = rig.handle(.received(channel, header(second)))
        #expect(rig.links.arrivingFiles == [BlobHash(of: second): reading(second, 0, of: 2048)])
        expectWithinArriving(rig, "replaced by a kept file")
        _ = rig.handle(.received(channel, header(unasked)))
        #expect(rig.links.arrivingFiles.isEmpty, "replaced by a skipped one")
        expectWithinArriving(rig, "replaced by a skipped file")
    }

    @Test func twoLinksStreamingOneBlobShowTheCopyFurthestAlong() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let file = bytes(8192)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash])
        _ = rig.handle(.received(channel, header(file)))
        _ = rig.handle(.received(other, header(file) + chunk(file[0..<2048])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 2048, of: 8192)], "the later channel, further along")
        _ = rig.handle(.received(channel, chunk(file[0..<3072])))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 3072, of: 8192)], "then the earlier one")
        expectWithinArriving(rig, "two links")
        _ = rig.handle(.closed(channel))
        #expect(rig.links.arrivingFiles == [hash: reading(file, 2048, of: 8192)], "the copy left")
        expectWithinArriving(rig, "one cut")
    }
}
