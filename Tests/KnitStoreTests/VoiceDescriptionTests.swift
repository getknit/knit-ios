import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A voice note's length and waveform, read on this phone and kept on every message that carries the note, by every
/// message store (schema v20 for the SQL one, knit-next ADR 034). It never crosses the wire.
@Suite struct VoiceDescriptionTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)
    private let waveform = (0..<64).map { UInt8($0 * 4) }

    /// A hash of `seed`, as 64 hex digits.
    private func hash(_ seed: Int) -> BlobHash {
        let digits = String(seed, radix: 16)
        return BlobHash(String(repeating: "0", count: 64 - digits.count) + digits) ?? .empty
    }

    private func message(_ id: String, carrying hash: BlobHash?, mime: String? = "audio/aac", key: String? = nil) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: bob,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: id,
            sentAt: 1,
            attachment: hash.map { MessageAttachment(hash: $0, mime: mime, key: key) }
        )
    }

    @Test(arguments: kinds)
    func aDescriptionLandsOnEveryMessageThatCarriesTheNote(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        for record in [message("a", carrying: hash(1)), message("b", carrying: hash(2)), message("c", carrying: hash(1))] {
            store.save(record)
        }
        store.save(message("d", carrying: nil))
        let description = VoiceDescription(durationMs: 10_031, peaks: waveform)
        #expect(store.setVoiceDescription(description, named: hash(1)))
        #expect(store.messages(in: Conversations.nearby).map(\.attachment?.voice) == [description, nil, description, nil])
        #expect(!store.setVoiceDescription(description, named: hash(1)), "the same description changes nothing")
        #expect(!store.setVoiceDescription(description, named: hash(9)), "no message carries that blob")
        let longer = VoiceDescription(durationMs: 10_032, peaks: waveform)
        #expect(store.setVoiceDescription(longer, named: hash(1)))
        #expect(store.message("c")?.attachment?.voice == longer)
        #expect(store.message("b")?.attachment?.voice == nil, "another note is untouched")
    }

    @Test(arguments: kinds)
    func eitherHalfIsStoredAsItIsAndNeitherIsNothing(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", carrying: hash(1)))
        store.save(message("b", carrying: hash(2)))
        #expect(!store.setVoiceDescription(VoiceDescription(), named: hash(1)), "an empty description writes nothing")
        #expect(!store.setVoiceDescription(VoiceDescription(peaks: []), named: hash(1)), "an empty waveform is none")
        #expect(store.message("a")?.attachment?.voice == nil)
        let timed = VoiceDescription(durationMs: 4643)
        #expect(store.setVoiceDescription(timed, named: hash(1)))
        #expect(store.message("a")?.attachment?.voice == timed)
        let drawn = VoiceDescription(peaks: waveform)
        #expect(store.setVoiceDescription(drawn, named: hash(2)))
        #expect(store.message("b")?.attachment?.voice == drawn)
        // Both halves as given, as `setVoiceMeta` writes them: a duration alone clears a waveform.
        #expect(store.setVoiceDescription(VoiceDescription(durationMs: 1, peaks: waveform), named: hash(1)))
        #expect(store.setVoiceDescription(timed, named: hash(1)))
        #expect(store.message("a")?.attachment?.voice == timed)
    }

    @Test(arguments: kinds)
    func theUndescribedAreEveryVoiceNoteWithoutALengthTheLatestStoredFirst(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", carrying: hash(1)))
        store.save(message("b", carrying: hash(2), key: "a key"))
        store.save(message("c", carrying: hash(1)))
        store.save(message("d", carrying: nil))
        // One per message, never folded by blob: the caller does that.
        #expect(store.undescribedVoiceNotes(named: nil).map(\.hash) == [hash(1), hash(2), hash(1)])
        #expect(
            store.undescribedVoiceNotes(named: hash(2)) == [MessageAttachment(hash: hash(2), mime: "audio/aac", key: "a key")],
            "a blob no store has seen is still listed: whether it is held is the caller's to ask"
        )
        #expect(store.setVoiceDescription(VoiceDescription(peaks: waveform), named: hash(1)))
        #expect(store.undescribedVoiceNotes(named: hash(1)).count == 2, "peaks without a length are read again")
        #expect(store.setVoiceDescription(VoiceDescription(durationMs: 2321), named: hash(1)))
        #expect(store.undescribedVoiceNotes(named: nil).map(\.hash) == [hash(2)])
        #expect(store.undescribedVoiceNotes(named: hash(1)).isEmpty)
    }

    @Test(arguments: kinds)
    func onlyAnAudioTypeIsAVoiceNoteItsBytesComparedExactly(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let refused: [String?] = ["image/jpeg", "application/pdf", nil, "Audio/aac", "AUDIO/AAC", "audio", "audio-aac", "", " audio/aac"]
        for (index, mime) in refused.enumerated() {
            store.save(message("not \(index)", carrying: hash(100 + index), mime: mime))
        }
        #expect(store.undescribedVoiceNotes(named: nil).isEmpty)
        // A combining mark after the slash fails `hasPrefix`, which compares graphemes, but not Kotlin's `startsWith`.
        let listed = ["audio/aac", "audio/", "audio/ogg; codecs=opus", "audio/\u{301}x"]
        for (index, mime) in listed.enumerated() {
            store.save(message("voice \(index)", carrying: hash(200 + index), mime: mime))
        }
        #expect(store.undescribedVoiceNotes(named: nil).compactMap(\.mime) == listed.reversed())
    }

    @Test(arguments: kinds)
    func anUndescribableNoteNeverHidesADescribableOne(kind: RepositoryKind) throws {
        // The strand the design pass found: a limited read whose newest rows never get described would never reach an
        // older one that would. With no limit, a caller paging in memory reaches it.
        let store = try kind.make().messages
        store.save(message("describable", carrying: hash(1)))
        for index in 0..<65 {
            store.save(message("stuck \(index)", carrying: hash(1000 + index)))
        }
        let undescribed = store.undescribedVoiceNotes(named: nil)
        #expect(undescribed.count == 66)
        #expect(undescribed.last?.hash == hash(1))
        #expect(store.setVoiceDescription(VoiceDescription(durationMs: 371), named: hash(1)))
        #expect(store.undescribedVoiceNotes(named: nil).count == 65)
    }

    @Test(arguments: kinds)
    func aSaveOfTheSameNoteKeepsEachHalfAndAnotherNoteClearsBoth(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", carrying: hash(1)))
        store.save(message("b", carrying: hash(2)))
        #expect(store.setVoiceDescription(VoiceDescription(durationMs: 417, peaks: waveform), named: hash(1)))
        #expect(store.setVoiceDescription(VoiceDescription(durationMs: 417, peaks: waveform), named: hash(2)))
        // A save that knows nothing of the description keeps both halves.
        var edited = message("a", carrying: hash(1))
        edited.body = "a caption added"
        store.save(edited)
        #expect(store.message("a")?.attachment?.voice == VoiceDescription(durationMs: 417, peaks: waveform))
        // A save that knows one half keeps the other.
        edited.attachment?.voice = VoiceDescription(durationMs: 500)
        store.save(edited)
        #expect(store.message("a")?.attachment?.voice == VoiceDescription(durationMs: 500, peaks: waveform))
        edited.attachment?.voice = VoiceDescription(peaks: [9])
        store.save(edited)
        #expect(store.message("a")?.attachment?.voice == VoiceDescription(durationMs: 500, peaks: [9]))
        // A save that names another blob clears both.
        store.save(message("b", carrying: hash(3)))
        #expect(store.message("b")?.attachment?.voice == nil)
        #expect(store.undescribedVoiceNotes(named: hash(3)).count == 1)
        // Every other write keeps it.
        store.markDelivered("a")
        store.clearPendingKey("a")
        #expect(store.message("a")?.attachment?.voice == VoiceDescription(durationMs: 500, peaks: [9]))
    }

    @Test(arguments: kinds)
    func aDescriptionTheMessageCarriesIsKept(kind: RepositoryKind) throws {
        // The sender's row, written before the session describes it.
        let store = try kind.make().messages
        var record = message("a", carrying: hash(1))
        record.attachment?.voice = VoiceDescription(durationMs: 10_031, peaks: waveform)
        store.save(record)
        #expect(store.message("a") == record)
        #expect(store.undescribedVoiceNotes(named: nil).isEmpty)
        var partial = message("b", carrying: hash(2))
        partial.attachment?.voice = VoiceDescription(peaks: waveform)
        #expect(store.insertIfAbsent(partial))
        #expect(store.message("b") == partial)
        var empty = message("c", carrying: hash(3))
        empty.attachment?.voice = VoiceDescription()
        store.save(empty)
        #expect(store.message("c")?.attachment?.voice == nil, "both halves missing is no description, in every store")
    }

    @Test func aDescriptionIsEmptyOnlyWithNeitherHalf() {
        #expect(VoiceDescription().isEmpty)
        #expect(VoiceDescription(peaks: []).isEmpty)
        #expect(VoiceDescription(peaks: []).peaks == nil)
        #expect(!VoiceDescription(durationMs: 0).isEmpty)
        #expect(!VoiceDescription(peaks: [0]).isEmpty)
    }
}
