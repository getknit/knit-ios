import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A receiving link keeping a cut attachment's bytes and splicing a resumed tail onto them (knit-next ADR 2026-10.wtyc,
/// knit-ios #2): what it keeps, what it counts and logs, and the readings a resumed stream gives its sender, the ring and
/// the asker's wait, each from the prefix as the wire means it.
@Suite struct LinkFileSpliceTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)
    private let photo = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) }
    private var hash: BlobHash { BlobHash(of: photo) }

    private func header(offset: Int?, size: Int, kind: FileHeader.Kind = .attachment, key: BlobHash? = nil) -> [UInt8] {
        let header = FileHeader(kind: kind, key: (key ?? hash).string, mime: "image/jpeg", size: size, offset: offset)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    private func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        LinkRecord(.fileChunk, payload: Array(bytes)).encoded ?? []
    }

    private var end: [UInt8] { LinkRecord(.fileEnd).encoded ?? [] }

    @Test func aCutKeepsTheAttachmentItWasStreamingAndNothingElse() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: [hash])
        _ = rig.handle(.received(channel, header(offset: nil, size: photo.count) + chunk(photo[..<20_000])))
        rig.links.keepCutFile(on: channel, now: 2000)
        #expect(rig.links.partials.length(hash) == 20_000)
        #expect(rig.links.arrivingFiles.isEmpty && !rig.links.isFileArriving(from: LinkRig.low), "a kept prefix is never on its way")
        _ = rig.handle(.received(channel, header(offset: nil, size: photo.count, kind: .avatar) + chunk(photo[..<20_000])))
        rig.links.keepCutFile(on: channel, now: 2000)
        #expect(rig.links.partials.length(hash) == 20_000, "an avatar keeps nothing, and costs the prefix nothing")
    }

    /// The splice reads the accepted keys alone (knit-ios #20): an echo whose ask named the prefix we kept, from a want of
    /// ours since gone, is resumed onto it, though a cut of it now would keep nothing.
    @Test func aResumedHeaderForAnAcceptedKeyNotResumableStillSplices() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: [])
        rig.links.partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        let events = rig.handle(.received(channel, header(offset: 20_000, size: 20_000) + chunk(photo[20_000...]) + end))
        #expect(rig.links.filesResumedIn == 1)
        let file = try #require(events.compactMap { if case .file(let file) = $0 { file } else { nil } }.first)
        #expect(file.bytes == photo && file.resumedFrom == 20_000)
    }

    /// A resumed stream for a photo-only want whose whole blob passes the photo's ceiling is refused at its header and
    /// names its sender, as Kotlin's `overCeiling` does for a resume under a marking ceiling (knit-next `FileIntake.kt:372-386`
    /// at `a0b52f865`), and the line says where it resumed.
    @Test func aResumedPhotoOnlyStreamPastTheCeilingNamesItsSenderAndWhereItResumed() {
        var configuration = LinkManager.Configuration()
        configuration.maxAvatarFileBytes = 30_000
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: [hash], photoOnly: [hash])
        rig.links.partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        let events = rig.handle(.received(channel, header(offset: 20_000, size: 20_000)))
        #expect(events.contains(.fileOverLimit(hash, from: LinkRig.low)))
        #expect(rig.links.filesRefused == 1)
        #expect(rig.log.all.contains { $0.contains("over its limit of 30000B, ATTACHMENT 20000B from 20000 from \(LinkRig.low)") })
    }

    @Test func aResumedStreamReadsReportsAndTimesFromItsPrefix() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: [hash])
        rig.links.partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        _ = rig.handle(.received(channel, header(offset: 20_000, size: 20_000)))
        #expect(rig.links.filesResumedIn == 1)
        #expect(rig.log.all.contains("info link \(channel) file \(hash.string.prefix(12)) resumed at 20000"))
        #expect(
            rig.links.arrivingFiles[hash] == FileIntake.Reading(key: hash, bytes: 20_000, total: 40_000, from: 20_000), "the ring resumes")
        #expect(rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low) == nil, "no byte of this stream yet")
        rig.clock.advance(1000)
        let events = rig.handle(.received(channel, chunk(photo[20_000..<24_096])))
        // What it holds of the blob, its prefix included: its sender takes the offset off (`FeedWindow.kt:210-226`).
        #expect(events == [.fileProgress(FileProgress(from: LinkRig.low, hash: hash, held: 24_096, milliseconds: 1000))])
        // 4096 bytes in the second since the header, 15904 to come: the prefix crossed another link, at another rate.
        let left = rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low)
        #expect(left == Int64(15_904 * 1000 / 4096))
        let landed = rig.handle(.received(channel, chunk(photo[24_096...]) + end))
        let file = try #require(landed.compactMap { if case .file(let file) = $0 { file } else { nil } }.first)
        #expect(file.bytes == photo && file.resumedFrom == 20_000)
        #expect(
            rig.log.all.contains("info link file ATTACHMENT \(hash.string.prefix(12)) from \(LinkRig.low): 20000 bytes resumed at 20000"))
        #expect(rig.links.fileCounts(rejected: 0) == FileCounts(received: 1, resumedIn: 1))
    }

    @Test func aResumeTheSharedRoomCannotHoldIsRefusedUnread() {
        var configuration = LinkManager.Configuration()
        configuration.maxBufferedFileBytes = 30_000
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let elsewhere = (0..<15_000).map { UInt8(truncatingIfNeeded: $0) }
        rig.links.acceptFiles([hash, BlobHash(of: elsewhere)], resumable: [hash, BlobHash(of: elsewhere)])
        _ = rig.handle(.received(other, header(offset: nil, size: 15_000, key: BlobHash(of: elsewhere)) + chunk(elsewhere[...])))
        rig.links.partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        _ = rig.handle(.received(channel, header(offset: 20_000, size: 20_000)))
        #expect(rig.links.filesResumedIn == 0)
        #expect(rig.links.filesRefused == 1)
        #expect(rig.log.all.contains("info link \(channel) file \(hash.string.prefix(12)) refused resumed at 20000: no room for 20000B"))
        #expect(rig.links.partials.length(hash) == 20_000, "kept for the next ask")
    }

    @Test func aSkippedResumeIsStillReportedFromItsOffset() {
        // ADR 2026-10.ds45's amendment (AND-7): a skipped file is reported, so an Android sender's window hears of it; one
        // that resumes is counted from its offset, which that window takes off. Nobody asked for this one, so the accept
        // gate skips it before any prefix is looked for.
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: 0x2FFF)
        _ = rig.handle(.received(channel, header(offset: 20_000, size: 20_000)))
        rig.clock.advance(500)
        let events = rig.handle(.received(channel, chunk(photo[20_000..<24_096])))
        #expect(events == [.fileProgress(FileProgress(from: LinkRig.low, hash: hash, held: 24_096, milliseconds: 500))])
        #expect(rig.log.all.contains("debug link \(channel) file \(hash.string.prefix(12)) skipped"))
        rig.links.acceptFiles([hash], resumable: [hash])
        _ = rig.handle(.received(channel, end + header(offset: 20_000, size: 20_000)))
        #expect(
            rig.log.all.contains("info link \(channel) file \(hash.string.prefix(12)) refused resumed at 20000: 0B kept"),
            "wanted, none kept")
    }

    @Test func aSecondResumeOnOneLinkInsideTheWindowIsRefusedAndSaysWhen() {
        // knit-next #161: one read of a kept prefix per key per link per 45 s.
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: [hash])
        rig.links.partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        _ = rig.handle(.received(channel, header(offset: 20_000, size: 20_000) + end))
        rig.clock.advance(1000)
        _ = rig.handle(.received(channel, header(offset: 20_000, size: 20_000)))
        #expect(rig.log.all.contains("info link \(channel) file \(hash.string.prefix(12)) refused resumed at 20000: resumed 1000ms ago"))
        #expect(rig.links.filesResumedIn == 1)
    }
}
