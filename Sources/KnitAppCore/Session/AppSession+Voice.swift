import KnitMesh
import KnitStore
import KnitWire

// A session's voice notes: what each note's bytes say about it, read on this phone and kept on its messages, never
// carried (knit-next ADR 034). Only a build that hands the session ``VoiceNotes`` reads them.
extension AppSession {
    /// How many notes are read before their descriptions are stored and the threads redraw, as photos' sizes are read.
    private static let notesPerRead = 64

    /// What a launch reads beside the mesh: the size of every photo held without one, since the first launch of a build
    /// that keeps sizes reads them all, and every voice note held without a length, Android's among them from before
    /// this build read any.
    func readHeldAttachments() async {
        async let sized: Void = measure(stores.messages.unsizedAttachments(named: nil))
        async let described: Void = describeVoice(stores.messages.undescribedVoiceNotes(named: nil))
        await sized
        await described
    }

    /// What blob `hash` landing is read for: a photo's size, or a voice note's length and waveform.
    func readArrival(_ hash: BlobHash) async {
        await measure(stores.messages.unsizedAttachments(named: hash))
        await describeVoice(stores.messages.undescribedVoiceNotes(named: hash))
    }

    /// Reads the voice note `message` carries if its bytes are here already. A note whose bytes came first raises no
    /// `attachmentArrived`: it was carried, pulled through for someone else, or its frame waited for a key (knit-next
    /// #132, `pullOrDescribe`). By `received` its row is stored, a ratchet DM's unit committed, so it is read then.
    func describeVoice(carriedBy message: MessageRecord) async {
        if let note = message.attachment, VoiceAudio.isVoice(note.mime) {
            await describeVoice(stores.messages.undescribedVoiceNotes(named: note.hash))
        }
    }

    /// Reads each voice note in `notes` whose bytes are here, off the main actor, and stores what they say on every
    /// message that carries the note (`InboundPipeline.deriveVoiceMeta`). Notes are read once each, the latest stored
    /// first. Bytes that are missing, that don't open, or that say nothing leave the note unread, to be read again at the
    /// next arrival or launch: the list the store gives is unbounded, so a note that can never be read never holds up the
    /// ones after it.
    func describeVoice(_ notes: [MessageAttachment]) async {
        guard let decoder = voiceNotes?.decoder else {
            return
        }
        var seen = Set<BlobHash>()
        let unique = notes.filter { seen.insert($0.hash).inserted }
        for start in stride(from: 0, to: unique.count, by: Self.notesPerRead) {
            let read = Array(unique[start..<min(start + Self.notesPerRead, unique.count)])
            var stored = false
            for note in await Self.descriptions(of: read, in: self, decoder: decoder)
            where stores.messages.setVoiceDescription(note.description, named: note.hash) {
                stored = true
            }
            if stored {
                revision += 1
            }
        }
    }

    /// Stores what the note we just sent says, read from its plaintext: a sealed note's row names its ciphertext, which
    /// this phone needn't open again.
    func describeSent(_ record: MessageRecord?, plaintext: [UInt8]) async {
        guard let decoder = voiceNotes?.decoder, let attachment = record?.attachment, VoiceAudio.isVoice(attachment.mime) else {
            return
        }
        let description = await Self.description(of: plaintext, decoder: decoder)
        if !description.isEmpty, stores.messages.setVoiceDescription(description, named: attachment.hash) {
            revision += 1
        }
    }

    @concurrent
    nonisolated private static func descriptions(
        of notes: [MessageAttachment], in session: AppSession, decoder: any VoiceDecoder
    ) async -> [(hash: BlobHash, description: VoiceDescription)] {
        notes.compactMap { note in
            session.attachment(note.hash, key: note.key).map { (note.hash, decoder.describe($0)) }.flatMap { $0.1.isEmpty ? nil : $0 }
        }
    }

    @concurrent
    nonisolated private static func description(of bytes: [UInt8], decoder: any VoiceDecoder) async -> VoiceDescription {
        decoder.describe(bytes)
    }
}
