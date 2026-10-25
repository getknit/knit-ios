import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The names a picture goes by, kept by every message store (schema v12 for the SQL one, ADR 2026-10.f3mv), as
/// knit-next's `AttachmentIdentitiesTest` pins `MessageDao.identityFor` and `sealedHolding`.
@Suite struct AttachmentIdentityStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)

    /// A hash of one digit, `seed`, repeated.
    private func hash(_ seed: Int) -> BlobHash {
        BlobHash(String(repeating: String(seed % 10), count: 64)) ?? .empty
    }

    /// A sealed JPEG in blob `seed`, named as the plaintext `plainHash`.
    private func sealed(_ seed: Int, named plainHash: BlobHash) -> MessageAttachment {
        MessageAttachment(hash: hash(seed), mime: "image/jpeg", key: "aw==", plainHash: plainHash)
    }

    private func message(_ id: String, sentAt: Int64, in conversation: String, carrying attachment: MessageAttachment) -> MessageRecord {
        MessageRecord(
            id: id, senderId: bob, recipientId: nil, conversationId: conversation, body: "", sentAt: sentAt, attachment: attachment)
    }

    @Test(arguments: kinds)
    func aSealedCopyIsFoundByItsPlaintext(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let sealed = MessageAttachment(hash: hash(1), mime: "image/jpeg", key: "aw==", plainHash: hash(9))
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: sealed))
        #expect(store.identities(matching: hash(9)) == [sealed])
        #expect(store.identities(matching: hash(1)).isEmpty, "a ciphertext's hash names no picture")
        #expect(store.sealedCopies(of: hash(9)).map(\.id) == ["dm"])
    }

    @Test(arguments: kinds)
    func theRoomsPublicNameWinsOverAnEarlierSealedCopy(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: sealed(1, named: hash(9))))
        store.save(message("room", sentAt: 2, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(9), mime: "image/jpeg")))
        #expect(store.identities(matching: hash(9)).map(\.hash) == [hash(9), hash(1)])
        #expect(store.sealedCopies(of: hash(9)).map(\.id) == ["dm"], "a room post is no sealed copy")
    }

    @Test(arguments: kinds)
    func ofTwoSealedCopiesTheEarliestIsTheOneAndAMovingOneBeatsBoth(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("later", sentAt: 5, in: bob.string, carrying: sealed(2, named: hash(9))))
        store.save(message("earlier", sentAt: 3, in: bob.string, carrying: sealed(1, named: hash(9))))
        #expect(store.identities(matching: hash(9)).map(\.hash) == [hash(1), hash(2)])
        #expect(store.sealedCopies(of: hash(9)).map(\.id) == ["earlier", "later"])
        let moving = try #require(PhotoDimensions(width: 4, height: 3, animated: true))
        store.setAttachmentDimensions(hash(2), to: moving)
        #expect(store.identities(matching: hash(9)).map(\.hash) == [hash(2), hash(1)])
    }

    @Test(arguments: kinds)
    func ourOwnSendIsFoundByThePickersBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let sent = MessageAttachment(hash: hash(1), mime: "image/webp", key: "aw==", plainHash: hash(9), sourceHash: hash(8))
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: sent))
        let posted = MessageAttachment(hash: hash(7), mime: "image/webp", sourceHash: hash(6))
        store.save(message("room", sentAt: 2, in: Conversations.nearby, carrying: posted))
        #expect(store.identities(matching: hash(8)) == [sent])
        #expect(store.identities(matching: hash(6)) == [posted])
    }

    @Test(arguments: kinds)
    func aSealedRowThatDoesNotKnowItsPlaintextIsNeverMistakenForOne(kind: RepositoryKind) throws {
        // `identityFor`'s guard: without it the row's ciphertext hash would stand for the plaintext's.
        let store = try kind.make().messages
        let unnamed = MessageAttachment(hash: hash(1), mime: "image/jpeg", key: "aw==", sourceHash: hash(8))
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: unnamed))
        #expect(store.identities(matching: hash(8)).isEmpty)
        #expect(store.identities(matching: hash(1)).isEmpty)
        store.save(message("untyped", sentAt: 2, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(3))))
        #expect(store.identities(matching: hash(3)).isEmpty, "a picture with no type is none to send")
    }

    @Test(arguments: kinds)
    func aSealedRowLearnsItsPlaintextOnceAndAKeylessOneNever(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: MessageAttachment(hash: hash(1), mime: "image/jpeg", key: "aw==")))
        store.save(message("room", sentAt: 2, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(2), mime: "image/jpeg")))
        #expect(store.keyWantingPlainHash(hash(1)) == "aw==")
        #expect(store.keyWantingPlainHash(hash(2)) == nil)
        #expect(store.setAttachmentPlainHash(hash(1), to: hash(9)))
        #expect(!store.setAttachmentPlainHash(hash(1), to: hash(5)), "a name once learned stays")
        #expect(!store.setAttachmentPlainHash(hash(2), to: hash(9)))
        #expect(store.message("dm")?.attachment?.plainHash == hash(9))
        #expect(store.message("room")?.attachment?.plainHash == nil)
        #expect(store.keyWantingPlainHash(hash(1)) == nil)
    }

    @Test(arguments: kinds)
    func aSaveOverTheRowKeepsTheNamesItLearned(kind: RepositoryKind) throws {
        // A row saved again, delivered or re-sealed, is written from what the engine holds, which may predate the name.
        let store = try kind.make().messages
        var record = message("dm", sentAt: 1, in: bob.string, carrying: MessageAttachment(hash: hash(1), mime: "image/jpeg", key: "aw=="))
        store.save(record)
        store.setAttachmentPlainHash(hash(1), to: hash(9))
        record.body = "a caption"
        store.save(record)
        #expect(store.message("dm")?.attachment?.plainHash == hash(9))
        record.attachment = MessageAttachment(hash: hash(2), mime: "image/jpeg", key: "aw==")
        store.save(record)
        #expect(store.message("dm")?.attachment?.plainHash == nil, "another blob's name is not this one's")
    }

    // MARK: The EXIF-less name (#12)

    @Test(arguments: kinds)
    func theExiflessNameFindsWhatSaveNamedInTheSameOrderUnderTheSameGuard(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("later", sentAt: 5, in: bob.string, carrying: sealed(2, named: hash(9))))
        store.save(message("earlier", sentAt: 3, in: bob.string, carrying: sealed(1, named: hash(9))))
        store.save(message("room", sentAt: 7, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(9), mime: "image/jpeg")))
        // Sealed, saved before its plaintext was named: its name could stand for the ciphertext's.
        let unnamed = MessageAttachment(hash: hash(3), mime: "image/jpeg", key: "aw==")
        store.save(message("unnamed", sentAt: 1, in: bob.string, carrying: unnamed))
        store.save(message("untyped", sentAt: 1, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(4))))
        for seed in [1, 2, 3] {
            #expect(store.setAttachmentExiflessHash(hash(seed), key: "aw==", to: hash(8)))
        }
        #expect(store.setAttachmentExiflessHash(hash(9), key: nil, to: hash(8)))
        #expect(store.setAttachmentExiflessHash(hash(4), key: nil, to: hash(8)))
        #expect(store.identities(exifless: hash(8)).map(\.hash) == [hash(9), hash(1), hash(2)])
        #expect(store.identities(exifless: hash(8)).allSatisfy { $0.exiflessHash == hash(8) })
        #expect(store.identities(exifless: hash(9)).isEmpty, "the plaintext's own name is not an EXIF-less one")
        #expect(store.identities(matching: hash(8)).isEmpty, "and an EXIF-less name is no exact one")
        let moving = try #require(PhotoDimensions(width: 4, height: 3, animated: true))
        store.setAttachmentDimensions(hash(2), to: moving)
        #expect(store.identities(exifless: hash(8)).map(\.hash) == [hash(2), hash(9), hash(1)])
        store.setAttachmentPlainHash(hash(3), to: hash(7))
        #expect(store.identities(exifless: hash(8)).map(\.hash) == [hash(2), hash(9), hash(3), hash(1)], "named, it answers")
    }

    @Test(arguments: kinds)
    func theSetterNamesOnlyThePairSaveOpenedAndOverwritesADifferentName(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("dm", sentAt: 1, in: bob.string, carrying: sealed(1, named: hash(9))))
        store.save(message("forward", sentAt: 2, in: bob.string, carrying: sealed(1, named: hash(9))))
        let otherKey = MessageAttachment(hash: hash(1), mime: "image/jpeg", key: "bA==", plainHash: hash(9))
        store.save(message("other key", sentAt: 3, in: bob.string, carrying: otherKey))
        store.save(message("keyless", sentAt: 4, in: Conversations.nearby, carrying: MessageAttachment(hash: hash(1), mime: "image/jpeg")))
        #expect(store.setAttachmentExiflessHash(hash(1), key: "aw==", to: hash(8)))
        #expect(store.message("dm")?.attachment?.exiflessHash == hash(8) && store.message("forward")?.attachment?.exiflessHash == hash(8))
        #expect(store.message("other key")?.attachment?.exiflessHash == nil, "another key is another pair")
        #expect(store.message("keyless")?.attachment?.exiflessHash == nil, "and so is no key")
        #expect(!store.setAttachmentExiflessHash(hash(1), key: "aw==", to: hash(8)), "an equal name changes nothing")
        #expect(store.setAttachmentExiflessHash(hash(1), key: "aw==", to: hash(6)), "a different one replaces it")
        #expect(store.message("dm")?.attachment?.exiflessHash == hash(6))
        #expect(store.setAttachmentExiflessHash(hash(1), key: nil, to: hash(5)))
        #expect(store.message("keyless")?.attachment?.exiflessHash == hash(5) && store.message("dm")?.attachment?.exiflessHash == hash(6))
        #expect(!store.setAttachmentExiflessHash(hash(2), key: nil, to: hash(5)), "a blob no row carries")
    }

    @Test(arguments: kinds)
    func aSaveOverTheRowKeepsItsExiflessName(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var record = message("dm", sentAt: 1, in: bob.string, carrying: sealed(1, named: hash(9)))
        store.save(record)
        store.setAttachmentExiflessHash(hash(1), key: "aw==", to: hash(8))
        record.body = "a caption"
        store.save(record)
        #expect(store.message("dm")?.attachment?.exiflessHash == hash(8))
        #expect(store.identities(exifless: hash(8)).map(\.hash) == [hash(1)])
        record.attachment = sealed(2, named: hash(9))
        store.save(record)
        #expect(store.message("dm")?.attachment?.exiflessHash == nil, "another blob's name is not this one's")
    }

    @Test(arguments: kinds)
    func atMostSixteenRowsAreReadForOneName(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        for index in 0..<20 {
            store.save(message("dm-\(index)", sentAt: Int64(index), in: bob.string, carrying: sealed(1, named: hash(9))))
        }
        store.setAttachmentExiflessHash(hash(1), key: "aw==", to: hash(8))
        #expect(store.identities(exifless: hash(8)).count == 16)
        #expect(store.identities(matching: hash(9)).count == 16)
    }
}
