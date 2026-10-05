import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A photo's size, read on this phone and kept on every message that carries the photo, by every message store (schema
/// v10 for the SQL one, ADR 2026-10.6cas). It never crosses the wire.
@Suite struct PhotoDimensionsTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)
    private let sunset = BlobHash(String(repeating: "5", count: 64)) ?? .empty
    private let summit = BlobHash(String(repeating: "6", count: 64)) ?? .empty
    private let nowhere = BlobHash(String(repeating: "7", count: 64)) ?? .empty

    private func message(_ id: String, carrying hash: BlobHash?, key: String? = nil) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: bob,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: id,
            sentAt: 1,
            attachment: hash.map { MessageAttachment(hash: $0, mime: "image/jpeg", key: key) }
        )
    }

    @Test(arguments: kinds)
    func aSizeLandsOnEveryMessageThatCarriesThePhoto(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        for record in [message("a", carrying: sunset), message("b", carrying: summit), message("c", carrying: sunset)] {
            store.save(record)
        }
        store.save(message("d", carrying: nil))
        let size = try #require(PhotoDimensions(width: 1280, height: 960))
        #expect(store.setAttachmentDimensions(sunset, to: size))
        #expect(store.messages(in: Conversations.nearby).map(\.attachment?.dimensions) == [size, nil, size, nil])
        #expect(!store.setAttachmentDimensions(sunset, to: size), "the same size changes nothing")
        #expect(!store.setAttachmentDimensions(nowhere, to: size), "no message carries that blob")
        let upright = try #require(PhotoDimensions(width: 960, height: 1280))
        #expect(store.setAttachmentDimensions(sunset, to: upright))
        #expect(store.message("c")?.attachment?.dimensions == upright)
    }

    @Test(arguments: kinds)
    func theUnsizedAreEachBlobOnceTheLatestStoredFirst(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", carrying: sunset))
        store.save(message("b", carrying: summit, key: "a key"))
        store.save(message("c", carrying: sunset))
        store.save(message("d", carrying: nil))
        #expect(store.unsizedAttachments(named: nil).map(\.hash) == [sunset, summit])
        #expect(store.unsizedAttachments(named: summit) == [MessageAttachment(hash: summit, mime: "image/jpeg", key: "a key")])
        store.setAttachmentDimensions(sunset, to: try #require(PhotoDimensions(width: 2, height: 1)))
        #expect(store.unsizedAttachments(named: nil).map(\.hash) == [summit])
        #expect(store.unsizedAttachments(named: sunset).isEmpty)
    }

    @Test(arguments: kinds)
    func aSizeTheMessageCarriesIsKept(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var record = message("a", carrying: sunset)
        record.attachment?.dimensions = PhotoDimensions(width: 640, height: 480)
        store.save(record)
        #expect(store.message("a") == record)
        #expect(store.unsizedAttachments(named: nil).isEmpty)
    }

    @Test func aSizeHasBothSides() {
        #expect(PhotoDimensions(width: 0, height: 10) == nil)
        #expect(PhotoDimensions(width: 10, height: -1) == nil)
        #expect(PhotoDimensions(width: 1, height: 1)?.width == 1)
    }
}
