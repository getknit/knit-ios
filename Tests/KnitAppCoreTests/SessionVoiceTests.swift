import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// A voice note's length and waveform, read from its bytes on this phone and kept on its messages (knit-next ADR 034):
/// as it is sent, as its bytes land, when its row comes after its bytes (knit-next #132), and at launch, where a note
/// that can never be read holds up none after it. The room refuses one, and a build without voice notes reads nothing.
@MainActor
@Suite struct SessionVoiceTests {
    /// A decoder that hands back one loud run per 64 ms of an ADTS note, and counts what it was asked to decode.
    final class FakeDecoder: VoiceDecoder {
        private let decoded = Lock<[[UInt8]]>([])
        /// Bytes that decode to nothing, as a damaged note's would.
        let broken: Set<[UInt8]>

        init(broken: Set<[UInt8]> = []) {
            self.broken = broken
        }

        /// Every set of bytes it was asked to decode, in order.
        var asked: [[UInt8]] { decoded.withLock { $0 } }

        func runs(of bytes: [UInt8]) -> [VoicePeaks.Chunk]? {
            decoded.withLock { $0.append(bytes) }
            guard !broken.contains(bytes), let length = VoiceAudio.durationMs(adts: bytes) else {
                return nil
            }
            return stride(from: 0, to: length, by: 64).map { VoicePeaks.Chunk(startMicroseconds: Int64($0) * 1000, loudest: 9000) }
        }

        func containerMilliseconds(of _: [UInt8]) -> Int? {
            nil
        }
    }

    /// A 6.4 s note at 16 kHz, its payload made distinct by `tag`.
    static func note(_ tag: UInt8 = 0) -> [UInt8] {
        var bytes = VoiceAudioTests.adts(100, index: 8)
        bytes[7] = tag
        return bytes
    }

    let decoder = FakeDecoder()

    func rig(decoder: FakeDecoder? = nil) -> AppRig {
        AppRig(
            voice: VoiceNotes(
                capture: VoiceRecorderTests.FakeCapture(),
                access: VoiceRecorderTests.FakeAccess(.allowed),
                playback: VoicePlayback(output: VoicePlaybackTests.FakeOutput()),
                decoder: decoder ?? self.decoder
            ) { 0 })
    }

    /// Stores a message from Sam carrying `attachment` and hands the session its arrival, as the engine would.
    @discardableResult
    private func receive(
        _ id: String, carrying attachment: MessageAttachment, to recipient: NodeId? = nil, in rig: AppRig
    ) async -> MessageRecord {
        let sender = AppRig.sam.nodeId
        let record = MessageRecord(
            id: id,
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: rig.me),
            body: "",
            sentAt: 1000,
            arrivedAt: 1000,
            attachment: attachment
        )
        rig.stores.messages.save(record)
        await rig.session.handle(.received(record, isRequest: rig.session.threads().isRequest(record.conversationId)))
        return record
    }

    private func voice(of id: String, in rig: AppRig) -> VoiceDescription? {
        rig.stores.messages.message(id)?.attachment?.voice
    }

    @Test func aSentNoteIsDescribedAsItGoes() async throws {
        let rig = rig()
        await rig.pin(AppRig.sam, name: "Sam")
        let note = Self.note()
        let sent = try #require(
            await rig.session.send("", photo: OutgoingPhoto(bytes: note, mime: VoiceAudio.mime), in: AppRig.sam.nodeId.string))
        let voice = try #require(voice(of: sent.id, in: rig))
        #expect(voice.durationMs == 6400)
        #expect(voice.peaks?.count == VoicePeaks.count)
        #expect(decoder.asked == [note], "read from the plaintext it sent, once")
    }

    /// The room floods to everyone in range, and no model screens a note's sound (ADR 034 §4).
    @Test func theRoomRefusesAVoiceNote() async {
        let rig = rig()
        let sent = await rig.session.send(
            "listen", photo: OutgoingPhoto(bytes: Self.note(), mime: VoiceAudio.mime), in: Conversations.nearby)
        #expect(sent == nil)
        #expect(rig.mesh.calls.room.isEmpty)
        let photo = await rig.session.send(
            "", photo: OutgoingPhoto(bytes: [1, 2, 3], mime: "image/jpeg"), in: Conversations.nearby)
        #expect(photo != nil, "a photo still goes")
    }

    @Test func aNoteIsDescribedAsItsBytesLand() async {
        let rig = rig()
        await rig.pin(AppRig.sam, name: "Sam")
        let note = Self.note()
        let hash = BlobHash(of: note)
        await receive("voice", carrying: MessageAttachment(hash: hash, mime: VoiceAudio.mime), to: rig.me, in: rig)
        #expect(voice(of: "voice", in: rig) == nil, "nothing to read until the bytes are here")
        rig.stores.blobs.insert(note, hash: hash, mime: VoiceAudio.mime, storedAt: 2)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(voice(of: "voice", in: rig)?.durationMs == 6400)
    }

    /// Bytes this phone held before the row came, carried or pulled through or parked for a key, raise no
    /// `attachmentArrived`: the row's own arrival reads them, once (knit-next #132).
    @Test func aNoteHeldBeforeItsRowIsDescribedAsTheRowArrives() async {
        let rig = rig()
        let note = Self.note()
        let hash = BlobHash(of: note)
        rig.stores.blobs.insert(note, hash: hash, mime: VoiceAudio.mime, storedAt: 1)
        await receive("voice", carrying: MessageAttachment(hash: hash, mime: VoiceAudio.mime), to: rig.me, in: rig)
        #expect(voice(of: "voice", in: rig)?.durationMs == 6400)
        #expect(rig.stores.messages.undescribedVoiceNotes(named: nil).isEmpty)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(decoder.asked.count == 1, "a described note isn't read again")
    }

    /// A DM's note is read from what its key opens, never from the sealed blob.
    @Test func aSealedNoteIsDescribedFromWhatItsKeyOpens() async throws {
        let rig = rig()
        await rig.pin(AppRig.sam, name: "Sam")
        let note = Self.note()
        let sealed = try #require(AttachmentCrypto.seal(note))
        let hash = BlobHash(of: sealed.blob)
        let attachment = MessageAttachment(hash: hash, mime: VoiceAudio.mime, key: Base64.encode(sealed.key))
        await receive("sealed", carrying: attachment, to: rig.me, in: rig)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: VoiceAudio.mime, storedAt: 2)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(voice(of: "sealed", in: rig)?.durationMs == 6400)
        #expect(decoder.asked == [note])
    }

    /// Android stores a length with no waveform when its decoder fails, and so does this.
    @Test func aNoteThatDoesNotDecodeKeepsItsLength() async {
        let note = Self.note()
        let rig = rig(decoder: FakeDecoder(broken: [note]))
        let hash = BlobHash(of: note)
        rig.stores.blobs.insert(note, hash: hash, mime: VoiceAudio.mime, storedAt: 1)
        await receive("voice", carrying: MessageAttachment(hash: hash, mime: VoiceAudio.mime), to: rig.me, in: rig)
        #expect(voice(of: "voice", in: rig) == VoiceDescription(durationMs: 6400, peaks: nil))
    }

    /// A launch reads every note held with no length, each blob once, and 65 that can never be read, stored after it,
    /// don't keep the one that can from being read: the store's list is whole, and the session pages it.
    @Test func aLaunchReadsEveryHeldNoteAndNoUnreadableOneHoldsItUp() async {
        let rig = rig()
        let good = Self.note()
        let hash = BlobHash(of: good)
        rig.stores.blobs.insert(good, hash: hash, mime: VoiceAudio.mime, storedAt: 1)
        rig.stores.messages.save(record("good", hash: hash, at: 1, in: rig))
        rig.stores.messages.save(record("again", hash: hash, at: 2, in: rig))
        for index in 0..<65 {
            let junk = Array("not audio \(index)".utf8)
            let junkHash = BlobHash(of: junk)
            rig.stores.blobs.insert(junk, hash: junkHash, mime: VoiceAudio.mime, storedAt: 3)
            rig.stores.messages.save(record("junk-\(index)", hash: junkHash, at: Int64(3 + index), in: rig))
        }
        rig.mesh.finish()
        await rig.session.listen()
        #expect(voice(of: "good", in: rig)?.durationMs == 6400)
        #expect(voice(of: "again", in: rig)?.durationMs == 6400)
        #expect(decoder.asked.filter { $0 == good }.count == 1, "two rows naming one blob read it once")
        #expect(rig.stores.messages.undescribedVoiceNotes(named: nil).count == 65)
    }

    /// A build without voice notes, a release build until they're approved for the store, reads nothing.
    @Test func withoutVoiceNotesNothingIsRead() async {
        let rig = AppRig()
        let note = Self.note()
        let hash = BlobHash(of: note)
        rig.stores.blobs.insert(note, hash: hash, mime: VoiceAudio.mime, storedAt: 1)
        await receive("voice", carrying: MessageAttachment(hash: hash, mime: VoiceAudio.mime), to: rig.me, in: rig)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(voice(of: "voice", in: rig) == nil)
        #expect(rig.session.voiceNotes == nil)
    }

    /// A DM from Sam sent at `at`, naming blob `hash` as a voice note.
    private func record(_ id: String, hash: BlobHash, at: Int64, in rig: AppRig) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: AppRig.sam.nodeId,
            recipientId: rig.me,
            conversationId: Conversations.id(sender: AppRig.sam.nodeId, recipient: rig.me, me: rig.me),
            body: "",
            sentAt: at,
            arrivedAt: at,
            attachment: MessageAttachment(hash: hash, mime: VoiceAudio.mime)
        )
    }
}

extension AppRig {
    /// A rig whose session records, plays and reads voice notes with `voice`, as a debug build's does.
    init(voice: VoiceNotes) {
        stores = MeshStores.inMemory()
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores, keys: Self.me.keys)
        notifier = RecordingNotifier()
        session = AppSession(
            identity: OwnIdentity(bundle: Self.me.bundle), stores: stores, mesh: mesh, notifier: notifier, voiceNotes: voice)
    }
}
