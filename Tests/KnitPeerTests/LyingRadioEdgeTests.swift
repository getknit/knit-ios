import Foundation
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// `--lying`'s radio at its edges: what it never touches passes to the radio under it, a channel closed under it is
/// written through untracked and never injected on, a FILE header that comes through `write` is held and read as one that
/// comes whole, a FILE record that does not read is passed on as it came, and every switch says what it set in the log
/// (`door-cap-lying-peers`).
@Suite(.timeLimit(.minutes(1))) struct LyingRadioEdgeTests: LyingRadioFixture {
    @Test func whatTheRadioNeverTouchesPassesToTheRadioUnderIt() {
        let inner = CallRadio()
        let radio = lying(inner)
        #expect(radio.advertisesServiceData && !radio.dialsGattPeers && radio.servesDoorbell && radio.reportsFileWrites)
        let advert = AdvertPayload(capabilities: 0x5F, nodeId: local, digestCue: 3, psm: 0x80, flags: 0)
        radio.advertise(advert)
        radio.seekPeers(true)
        radio.seekPeers(false)
        #expect(inner.calls == [.advertise(advert), .seek(true), .seek(false)])
    }

    /// A write or a HELLO that still comes for a channel after its close goes through as it came, and makes no entry: the
    /// channel never turns ready, and a forge or an ask set then goes out nowhere.
    @Test func aChannelClosedUnderItIsWrittenThroughAndNeverInjectedOn() {
        let inner = CallRadio()
        let radio = lying(inner)
        radio.setBlobHasLie(photo, size: 2_000_000)
        radio.close(channel)
        let lie = record(.frame, answer().encoded)
        radio.write(hello(local), to: channel)
        radio.write(lie, to: channel)
        radio.heardHello(from: peer, told: nil, announced: nil, on: channel)
        radio.linkUp(peer, on: channel)
        #expect(
            inner.calls == [
                .close(channel), .write(channel, hello(local)), .write(channel, lie), .heard(peer, channel), .up(peer, channel),
            ])
        #expect(radio.readyChannels.isEmpty && radio.counts.blobhasRewritten == 0, "nothing tracked, nothing rewritten")

        #expect(radio.setPaddedProfile(forge()) == 0)
        #expect(radio.askBlob(photo, of: peer) == nil)
        #expect(inner.calls.count == 5 && radio.counts == LyingRadio.Counts(), "nothing injected")
    }

    /// While our profile advertises another's photo, a FILE header written through `write` is held until whole: the
    /// canary counts an `AVATAR` header for that photo, and the record goes on in the slices it came in.
    @Test func aFileHeaderWrittenInSlicesIsHeldForTheCanaryAndPassedOnAsItCame() {
        let inner = CallRadio()
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        let profile = ForgingOwnProfileStore(wrapping: state.profileStore())
        let radio = lying(inner, profile: profile)
        profile.advertise(photo)
        let header = record(
            .fileHeader, LinkJSON.fileHeaderPayload(FileHeader(kind: .avatar, key: photo.string, mime: "image/jpeg", size: 30_000)))
        let parts = [Array(header[0..<5]), Array(header[5...])]
        radio.write(parts[0], to: channel)
        #expect(inner.calls.isEmpty, "held: the advertised photo's header might come")
        radio.write(parts[1], to: channel)
        #expect(inner.calls == parts.map { .write(channel, $0) })
        #expect(radio.counts.advertisedPhotoPushed == 1 && radio.counts.junkHeadersRewritten == 0)
    }

    /// A FILE record whose header says FILE_HEADER but which is not one whole record, or whose payload does not read as a
    /// header, is never rewritten, even for a junk hash.
    @Test func aFileRecordThatDoesNotReadGoesOnAsItCame() {
        let inner = CallRadio()
        let radio = lying(inner)
        radio.setJunkHeader(photo, declare: 30_000)
        let header = record(
            .fileHeader, LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg", size: 9)))
        let overlong = header + [0]
        let truncated = Array(header.dropLast())
        let unreadable = record(.fileHeader, Array("not a header".utf8))
        for bytes in [overlong, truncated, unreadable] {
            radio.writeFileRecord(bytes, to: channel)
        }
        #expect(inner.calls == [.file(channel, overlong), .file(channel, truncated), .file(channel, unreadable)])
        #expect(radio.counts.junkHeadersRewritten == 0)
    }

    @Test func everySwitchSaysWhatItSetInTheLog() {
        let inner = CallRadio()
        let log = LineLog()
        let radio = lying(inner, log: log)
        let hash = photo.string
        radio.setBlobHasLie(photo, size: 2_000_000)
        radio.clearBlobHasLie(photo)
        radio.setJunkHeader(photo, declare: 30_000)
        radio.setJunkHeader(photo, declare: nil)
        radio.clearJunkHeader(photo)
        radio.setPaddedProfile(forge())
        radio.setPaddedProfile(nil)
        #expect(radio.askBlob(photo, of: peer) == nil)
        #expect(
            log.lines == [
                "lying: blobhas answers claim \(hash) at 2000000 bytes",
                "lying: blobhas answers for \(hash) honest again",
                "lying: FILE headers for \(hash) declare 30000 bytes",
                "lying: FILE headers for \(hash) declare no size",
                "lying: FILE headers for \(hash) honest again",
                "lying: padded profile no longer injected",
                "lying: no ready link to \(peer) for a blobreq of \(hash)",
            ])

        dialed(radio, channel, peer: peer)
        radio.setJunkHeader(photo, declare: 30_000)
        radio.writeFileRecord(
            record(
                .fileHeader,
                LinkJSON.fileHeaderPayload(
                    FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg", size: 9000, offset: 4096))),
            to: channel)
        #expect(log.lines.last == "lying: FILE header for \(hash) on \(channel) declares 30000 bytes from 4096")
        #expect(radio.askBlob(photo, of: peer) != nil)
        #expect(log.lines.last == "lying: blobreq for \(hash) written to \(peer) on \(channel)")
    }
}
