import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// `--lying`'s radio: honest byte for byte and slice for slice until a switch is set, and a `blobhas` answer and a junk
/// hash's FILE header rewritten whole however they were sliced (`door-cap-lying-peers`).
@Suite(.timeLimit(.minutes(1))) struct LyingRadioTests: LyingRadioFixture {
    // MARK: Honest

    @Test func withNothingSetEverySliceGoesThroughAsItCame() {
        let inner = CallRadio()
        let radio = lying(inner)
        let big = record(.frame, answer(extra: 250).encoded)
        #expect(big.count > 16_384, "three slices")
        let header = record(
            .fileHeader, LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg", size: 9)))
        var expected: [CallRadio.Call] = []
        dialed(radio, channel, peer: peer)
        expected += [.write(channel, hello(local)), .heard(peer, channel), .up(peer, channel)]
        for slice in slices(big) {
            radio.write(slice, to: channel)
            expected.append(.write(channel, slice))
        }
        radio.writeDigest(record(.digest, LinkJSON.digestPayload(ids: ["a"])), to: channel)
        radio.writeFileRecord(header, to: channel)
        radio.writeFileRecord(record(.fileChunk, [1, 2, 3]), to: channel)
        radio.write([1, 0], to: channel)
        expected += [
            .digest(channel, record(.digest, LinkJSON.digestPayload(ids: ["a"]))), .file(channel, header),
            .file(channel, record(.fileChunk, [1, 2, 3])), .write(channel, [1, 0]),
        ]
        #expect(inner.calls == expected)
        #expect(radio.counts == LyingRadio.Counts())
    }

    @Test func aSwitchForAnotherRecordLeavesThisOneAlone() {
        let inner = CallRadio()
        let radio = lying(inner)
        radio.setBlobHasLie(photo, size: 2_000_000)
        let chat = record(
            .frame,
            WireEnvelope(sig: [1], signed: RelayEnvelope(type: .chat, id: "c", senderId: local.string, payload: [0xA0]).encoded).encoded)
        let parts = [Array(chat[0..<7]), Array(chat[7...])]
        for part in parts {
            radio.write(part, to: channel)
        }
        #expect(inner.calls == parts.map { .write(channel, $0) }, "held until whole, then written in the slices it came in")
        #expect(radio.counts.blobhasRewritten == 0)
    }

    @Test func everyEventPassesThroughAndAClosedChannelIsForgotten() async {
        let inner = CallRadio()
        let radio = lying(inner)
        dialed(radio, channel, peer: peer)
        #expect(radio.readyChannels == [channel: peer])
        inner.emit(.wroteFileRecord(channel))
        inner.emit(.rung)
        inner.emit(.closed(channel))
        var events: [RadioEvent] = []
        for await event in radio.events {
            events.append(event)
            if event == .closed(channel) {
                break
            }
        }
        #expect(events == [.wroteFileRecord(channel), .rung, .closed(channel)])
        #expect(radio.readyChannels.isEmpty)
        #expect(radio.askBlob(photo, of: peer) == nil, "no ready link to the peer")
    }

    // MARK: blobhas

    @Test func aBlobHasAnswerIsRewrittenWholeAcrossItsSlices() throws {
        let inner = CallRadio()
        let radio = lying(inner)
        radio.setBlobHasLie(photo, size: 2_000_000)
        let sliced = slices(record(.frame, answer(extra: 120).encoded))
        #expect(sliced.count == 2)
        radio.write(sliced[0], to: channel)
        #expect(inner.calls.isEmpty, "held until the record is whole")
        radio.write(sliced[1], to: channel)
        #expect(inner.writes(on: channel).allSatisfy { $0.count <= sliced[0].count })
        let records = inner.records(on: channel)
        #expect(records.count == 1)
        let wire = try WireEnvelope(decoding: try #require(records.first).payload)
        let envelope = try RelayEnvelope(decoding: wire.signed)
        let content = try BlobHasContent(decoding: envelope.payload)
        #expect(content.items.first == BlobHasItem(hash: photo.string, state: .have, size: 2_000_000))
        #expect(content.items.count == 121 && content.re == "q-1" && content.load == 2 && envelope.id == "answer-1")
        #expect(!wire.relay && wire.sig.isEmpty)
        #expect(radio.counts.blobhasRewritten == 1)

        radio.clearBlobHasLie(photo)
        let honest = record(.frame, answer().encoded)
        radio.write(honest, to: channel)
        #expect(inner.writes(on: channel).last == honest, "honest again once cleared")
    }

    // MARK: FILE header

    private func headerRecord(_ kind: FileHeader.Kind, _ hash: BlobHash, size: Int?, offset: Int? = nil) -> [UInt8] {
        record(
            .fileHeader,
            LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: hash.string, mime: "image/jpeg", size: size, offset: offset)))
    }

    private func lastHeader(_ inner: CallRadio) throws -> FileHeader {
        let record = try #require(inner.records(on: channel).last)
        #expect(record.tag == .fileHeader)
        return try #require(LinkJSON.fileHeader(from: record.payload))
    }

    @Test func aJunkHeaderDeclaresWhatIsSetAndNothingElseMoves() throws {
        let inner = CallRadio()
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        let profile = ForgingOwnProfileStore(wrapping: state.profileStore())
        let radio = lying(inner, profile: profile)
        let junkBytes = 1_114_112
        let advertised = BlobHash(of: fixtureBytes(500, seed: 3))

        radio.setJunkHeader(photo, declare: nil)
        radio.writeFileRecord(headerRecord(.attachment, photo, size: junkBytes), to: channel)
        #expect(try lastHeader(inner) == FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg"), "no size")

        radio.setJunkHeader(photo, declare: 30_000)
        radio.writeFileRecord(headerRecord(.attachment, photo, size: junkBytes), to: channel)
        #expect(try lastHeader(inner).size == 30_000, "a plausible size")

        radio.writeFileRecord(headerRecord(.attachment, photo, size: junkBytes - 4096, offset: 4096), to: channel)
        #expect(try lastHeader(inner) == FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg", size: 30_000, offset: 4096))
        #expect(radio.counts.junkHeadersRewritten == 3)

        let avatar = headerRecord(.avatar, photo, size: junkBytes)
        radio.writeFileRecord(avatar, to: channel)
        let otherHash = headerRecord(.attachment, advertised, size: 500)
        radio.writeFileRecord(otherHash, to: channel)
        #expect(inner.calls.suffix(2) == [.file(channel, avatar), .file(channel, otherHash)], "an AVATAR and another hash untouched")
        #expect(radio.counts.junkHeadersRewritten == 3)

        profile.advertise(advertised)
        let canary = headerRecord(.avatar, advertised, size: 500)
        radio.writeFileRecord(canary, to: channel)
        #expect(inner.calls.last == .file(channel, canary), "counted, never rewritten")
        #expect(radio.counts.advertisedPhotoPushed == 1)

        radio.clearJunkHeader(photo)
        let honest = headerRecord(.attachment, photo, size: junkBytes)
        radio.writeFileRecord(honest, to: channel)
        #expect(inner.calls.last == .file(channel, honest))
    }
}
