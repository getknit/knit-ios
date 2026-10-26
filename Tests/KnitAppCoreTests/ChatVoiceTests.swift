import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A thread's voice notes (knit-next ADR 034): where the composer offers its mic, what a held note does to Send, the
/// ring a note on its way shows, a named audio file played as a note, and a build without voice notes, which offers
/// none of it.
@MainActor
@Suite struct ChatVoiceTests {
    let voiced = SessionVoiceTests()

    /// A DM with Sam over `rig`, Sam pinned.
    func thread(_ rig: AppRig) async -> ChatModel {
        await rig.pin(AppRig.sam, name: "Sam")
        return ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
    }

    /// Holds a 6.4 s note in `model`'s composer, as a recording the recorder kept would (``VoiceRecorderTests`` drives the
    /// recording itself).
    func record(in model: ChatModel) throws -> StagedVoice {
        let voice = try #require(model.voice)
        voice.staged = StagedVoice(bytes: SessionVoiceTests.note(), durationMilliseconds: 6400)
        return try #require(voice.staged)
    }

    @Test func aDirectMessageOffersTheMicWhileThereIsNothingToSend() async {
        let model = await thread(voiced.rig())
        #expect(model.offersVoice)
        model.draft = "on my way"
        #expect(!model.offersVoice, "words to send take the mic's place")
        model.draft = ""
        #expect(model.offersVoice)
    }

    /// The room floods to everyone in range, and no model screens a note's sound (ADR 034 §4).
    @Test func theRoomNeverOffersTheMic() {
        let model = ChatModel(conversationId: Conversations.nearby, session: voiced.rig().session)
        #expect(!model.offersVoice)
    }

    /// The mic stays while the finger holds it, since the gesture ends with its view, and gives way to Stop once locked.
    @Test func aHeldRecordingKeepsTheMicAndALockedOneGivesItUp() async throws {
        let model = await thread(voiced.rig())
        let voice = try #require(model.voice)
        voice.press()
        #expect(model.offersVoice)
        voice.lock()
        #expect(!model.offersVoice)
    }

    @Test func aHeldNoteIsSentWithItsCaptionAndLeavesTheComposer() async throws {
        let rig = voiced.rig()
        let model = await thread(rig)
        let note = try record(in: model)
        #expect(model.canSend)
        #expect(!model.offersPhoto, "the trailing button sends once a note is held")
        #expect(!model.offersVoice)
        model.draft = "the trailhead"
        #expect(await model.send())
        #expect(model.voice?.staged == nil)
        let sent = try #require(rig.stores.messages.messages(in: AppRig.sam.nodeId.string).last)
        #expect(sent.body == "the trailhead")
        #expect(sent.attachment?.mime == VoiceAudio.mime)
        #expect(sent.attachment?.hash == BlobHash(of: note.bytes))
        #expect(sent.attachment?.voice?.durationMs == 6400, "described as it went")
        let shown = try #require(model.state.messages.last?.attachment)
        #expect(shown.kind == .voice && shown.playsAsVoice)
        #expect(shown.voice?.durationMs == 6400)
    }

    /// A held photo goes before a held note, and the note waits for the next Send.
    @Test func aHeldPhotoGoesFirst() async throws {
        let rig = voiced.rig()
        let model = await thread(rig)
        _ = try record(in: model)
        model.staged = StagedPhoto(photo: OutgoingPhoto(bytes: [1, 2, 3], mime: "image/jpeg"), hash: BlobHash(of: [1, 2, 3]))
        #expect(await model.send())
        #expect(rig.stores.messages.messages(in: AppRig.sam.nodeId.string).last?.attachment?.mime == "image/jpeg")
        #expect(model.voice?.staged != nil)
    }

    /// A note on its way shows how far it has got where notes play, and nowhere they don't.
    @Test func aNoteOnItsWayRingsWhereNotesPlay() async {
        let note = MessageAttachment(hash: BlobHash(of: SessionVoiceTests.note()), mime: VoiceAudio.mime)
        let rig = voiced.rig()
        let model = await thread(rig)
        rig.stores.messages.save(dm(carrying: note, in: rig))
        #expect(model.awaitsPhotos)

        let plain = AppRig()
        let silent = await thread(plain)
        plain.stores.messages.save(dm(carrying: note, in: plain))
        #expect(!silent.awaitsPhotos, "a build without voice notes shows its tile, not a ring")
    }

    /// A named audio file is listed by its name and plays as a note, as Android does.
    @Test func aNamedAudioFilePlaysAsANote() throws {
        let file = MessageAttachment(hash: BlobHash(of: [9]), mime: "audio/mpeg", name: "song.mp3")
        let shown = try #require(ChatAttachment(file, isHeld: true))
        #expect(shown.kind == .file)
        #expect(shown.playsAsVoice)
        #expect(AttachmentKind.preview(of: file) == Copy.Attachments.filePreview("song.mp3"))
        let photo = try #require(ChatAttachment(MessageAttachment(hash: BlobHash(of: [8]), mime: "image/jpeg"), isHeld: true))
        #expect(!photo.playsAsVoice)
    }

    /// A build without voice notes, a release build until they're approved for the store, has no recorder and no mic.
    @Test func withoutVoiceNotesThereIsNoMic() async {
        let model = await thread(AppRig())
        #expect(model.voice == nil)
        #expect(!model.offersVoice)
        #expect(model.offersPhoto)
    }

    /// A DM's or a group's note shows its player; the room's shows its tile, and a build without voice notes the old one.
    @Test func eachThreadShowsANoteItsOwnWay() async throws {
        let note = MessageAttachment(hash: BlobHash(of: SessionVoiceTests.note()), mime: VoiceAudio.mime)
        let rig = voiced.rig()
        let model = await thread(rig)
        rig.stores.messages.save(dm(carrying: note, in: rig))
        #expect(model.state.messages.last?.attachment?.voiceShowing == .player)

        let room = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        var post = dm(carrying: note, in: rig)
        post.id = "room-voice"
        post.recipientId = nil
        post.conversationId = Conversations.nearby
        rig.stores.messages.save(post)
        #expect(room.state.messages.last?.attachment?.voiceShowing == .notInNearby)
        #expect(!room.awaitsPhotos, "the room's tile shows no ring")

        let plain = AppRig()
        let silent = await thread(plain)
        plain.stores.messages.save(dm(carrying: note, in: plain))
        #expect(silent.state.messages.last?.attachment?.voiceShowing == .unsupported)
        let photo = try #require(ChatAttachment(MessageAttachment(hash: BlobHash(of: [8]), mime: "image/jpeg"), isHeld: true))
        #expect(photo.voiceShowing == nil)
    }

    /// A tap plays a held note through the session, its sealed bytes opened in memory; a tap on the waveform moves it.
    @Test func aNoteOnScreenPlaysAndSeeksThroughTheSession() async throws {
        let output = VoicePlaybackTests.FakeOutput()
        let rig = voiced.rig(output: output)
        let model = await thread(rig)
        let note = SessionVoiceTests.note()
        let sealed = try #require(AttachmentCrypto.seal(note))
        let hash = BlobHash(of: sealed.blob)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: VoiceAudio.mime, storedAt: 1)
        rig.stores.messages.save(
            dm(carrying: MessageAttachment(hash: hash, mime: VoiceAudio.mime, key: Base64.encode(sealed.key)), in: rig))
        await rig.session.handle(.attachmentArrived(hash))
        let shown = try #require(model.state.messages.last?.attachment)
        let playback = try #require(rig.session.voiceNotes?.playback)
        await rig.session.toggleVoice(shown)
        #expect(playback.nowPlaying?.hash == hash)
        #expect(output.played == [note], "the plaintext plays, never the sealed blob")
        rig.session.seekVoice(shown, to: 0.5)
        #expect(playback.nowPlaying?.position == 3200)
        rig.session.seekVoice(shown, to: 7)
        #expect(playback.nowPlaying?.position == 6400, "a tap past the end holds at the end")
        var unread = shown
        unread.voice = nil
        rig.session.seekVoice(unread, to: 0.25)
        #expect(playback.nowPlaying?.position == 6400, "a note with no length doesn't move")
    }

    /// The held note plays from its plaintext before anything is stored, and its waveform moves it.
    @Test func theHeldNotePlaysBeforeItIsSent() async throws {
        let rig = voiced.rig()
        let model = await thread(rig)
        let voice = try #require(model.voice)
        let note = try record(in: model)
        await rig.session.toggleVoice(note)
        #expect(rig.session.voiceNotes?.playback.nowPlaying?.hash == BlobHash(of: note.bytes))
        rig.session.seekVoice(note, to: 0.25)
        #expect(rig.session.voiceNotes?.playback.nowPlaying?.position == 1600)
        #expect(voice.staged?.hash == BlobHash(of: note.bytes))
    }

    /// A press stops what plays, so the recording hears the room; leaving keeps the recording and pauses the note, and
    /// closing the thread stops it.
    @Test func recordingAndLeavingTakeThePlayerAlong() async throws {
        let rig = voiced.rig()
        let model = await thread(rig)
        let note = try record(in: model)
        let playback = try #require(rig.session.voiceNotes?.playback)
        await rig.session.toggleVoice(note)
        model.leave()
        #expect(playback.nowPlaying?.playing == false)
        await rig.session.toggleVoice(note)
        model.voice?.removeStaged()
        model.startRecording()
        #expect(playback.nowPlaying == nil)
        #expect(model.voice?.isRecording == true)
        await rig.session.toggleVoice(note)
        model.disappear()
        #expect(playback.nowPlaying == nil)
        #expect(model.voice?.isRecording == false)
    }

    /// The composer's Remove drops the held note, and stops it when it is the note playing.
    @Test func removingTheHeldNoteStopsItWhenItPlays() async throws {
        let rig = voiced.rig()
        let model = await thread(rig)
        let note = try record(in: model)
        let playback = try #require(rig.session.voiceNotes?.playback)
        await rig.session.toggleVoice(note)
        #expect(playback.nowPlaying?.hash == note.hash)
        model.removeVoice()
        #expect(model.voice?.staged == nil)
        #expect(playback.nowPlaying == nil)
        _ = try record(in: model)
        model.removeVoice()
        #expect(model.voice?.staged == nil, "a note that doesn't play leaves all the same")
    }

    /// The voice scene's DM with Sam: two notes that play from the clip it is handed, one streaming in under its ring and
    /// one owed, as the walk and the shots draw them.
    @Test func theVoiceSceneShowsEachKindOfNote() throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        let clip = SessionVoiceTests.note()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .voice, voice: clip)
        let sam = try #require(DemoSeed.nodeId(.sam))
        let notes = stores.messages.messages(in: sam.string).compactMap(\.attachment)
        #expect(notes.count == 4)
        #expect(notes.allSatisfy { $0.mime == VoiceAudio.mime })
        #expect(stores.blobs.held(among: Set(notes.map(\.hash))) == [BlobHash(of: clip)], "the two played notes are the clip")
        #expect(DemoSeed.staging(in: .voice).arriving.count == 1)
    }

    /// A DM from Sam carrying `attachment`.
    private func dm(carrying attachment: MessageAttachment, in rig: AppRig) -> MessageRecord {
        MessageRecord(
            id: "voice-\(attachment.hash.string.prefix(8))",
            senderId: AppRig.sam.nodeId,
            recipientId: rig.me,
            conversationId: AppRig.sam.nodeId.string,
            body: "",
            sentAt: 1000,
            arrivedAt: 1000,
            attachment: attachment
        )
    }
}
