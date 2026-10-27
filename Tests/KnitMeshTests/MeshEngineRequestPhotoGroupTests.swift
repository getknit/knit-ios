import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The groups' and the verification's side of ``MeshEngineRequestPhotoTests`` (knit-ios #21): a group is a request until a
/// known sender posts in it, a block leaves a group's photos named, and un-verifying keeps what verifying accepted.
@Suite struct MeshEngineRequestPhotoGroupTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let picture = Array("a stranger's picture".utf8)
    private let thirtyOneMinutes: Int64 = 31 * 60_000

    private func sealedPhoto() throws -> SealedPhoto {
        try SealedPhoto(picture)
    }

    // MARK: Groups

    @Test func aGroupWhoseOnlyKnownPosterIsBlockedFetchesNothingNewAndKeepsWhatItHolds() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.befriend(bob)
        let info = roster([bob, carol, alice], createdBy: bob)
        let first = try sealedPhoto()
        fixture.deliver(
            try bob.groupMessage(
                "", in: info, to: [alice, carol], id: frameIdOf("gm-1"), sentAt: EngineFixture.start, content: first.content),
            from: bob)
        #expect(fixture.engine.blobExchange.isWanted(first.hash), "Bob is known, so the group is accepted")
        fixture.engine.receiveFile(requestFile(first.sealed.blob, from: bob))
        fixture.engine.block(bob.nodeId)
        _ = fixture.engine.drainEvents()

        let second = try #require(AttachmentCrypto.seal(Array("carol's".utf8)))
        let secondHash = BlobHash(of: second.blob)
        let content = MessageContent(
            body: "", attachmentHash: secondHash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(second.key))
        fixture.deliver(
            try carol.groupMessage(
                "", in: info, to: [alice, bob], id: frameIdOf("gm-2"), sentAt: EngineFixture.start + 1, content: content),
            from: carol)
        let row = try #require(fixture.stores.messages.message(frameIdOf("gm-2")))
        #expect(fixture.engine.drainEvents().contains(.received(row, isRequest: true)), "as the screens read it, blocks left out")
        #expect(!fixture.engine.blobExchange.isWanted(secondHash))
        fixture.advance(thirtyOneMinutes)
        #expect(fixture.stores.blobs.contains(first.hash), "a block never sweeps a thread's photos")
    }

    @Test func aGroupRequestsPhotoIsWantedAtTheReOfferAfterAKnownSenderPosts() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = roster([carol, bob, alice], createdBy: carol)
        let photo = try sealedPhoto()
        fixture.deliver(
            try carol.groupMessage(
                "", in: info, to: [alice, bob], id: frameIdOf("gm-1"), sentAt: EngineFixture.start, content: photo.content),
            from: carol)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash), "a group no known sender posts in is a request")
        fixture.befriend(bob)
        fixture.deliver(
            try bob.groupMessage("hi", in: info, to: [alice, carol], id: frameIdOf("gm-2"), sentAt: EngineFixture.start + 1), from: bob)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash), "left to the re-offer")
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.wants[photo.hash]?.author == carol.nodeId)
    }

    // MARK: Verifying

    @Test func verifyingWantsThePhotoAndUnverifyingKeepsTheThreadAndItsPhotos() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash))
        // A group of Carol's that Bob's posts alone accept.
        let info = roster([carol, bob, alice], createdBy: carol)
        let groupPhoto = Array("carol's picture".utf8)
        let groupContent = MessageContent(body: "", attachmentHash: BlobHash(of: groupPhoto).string, attachmentMime: "image/jpeg")
        fixture.deliver(
            try bob.groupMessage("hi", in: info, to: [alice, carol], id: frameIdOf("gm-0"), sentAt: EngineFixture.start), from: bob)
        fixture.deliver(
            try carol.groupMessage(
                "", in: info, to: [alice, bob], id: frameIdOf("gm-1"), sentAt: EngineFixture.start, content: groupContent),
            from: carol)
        #expect(!fixture.engine.blobExchange.isWanted(BlobHash(of: groupPhoto)))

        fixture.transport.clear()
        fixture.engine.setVerified(bob.nodeId, true)
        #expect(fixture.engine.blobExchange.isWanted(photo.hash) && fixture.engine.blobExchange.isWanted(BlobHash(of: groupPhoto)))
        #expect(fixture.transport.written(.blobRequest).map(\.to).contains(bob.nodeId))
        fixture.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        fixture.engine.receiveFile(requestFile(groupPhoto, from: carol))
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty, "accepted by the verification alone")

        fixture.engine.setVerified(bob.nodeId, false)
        #expect(fixture.stores.conversations.acceptedConversations() == [bob.nodeId.string, info.id], "persisted before the basis went")
        fixture.advance(thirtyOneMinutes)
        #expect(fixture.stores.blobs.contains(photo.hash) && fixture.stores.blobs.contains(BlobHash(of: groupPhoto)))
        #expect(fixture.engine.mayFetch(for: bob.nodeId.string) && fixture.engine.mayFetch(for: info.id))
    }

    @Test func scanningAStrangersCodeWantsTheirPhotos() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash))
        let links = try #require(ContactCard.encode(bob.keys, name: "Bob", issuedAt: EngineFixture.start))
        let card = try #require(ContactCard.parse(links.url).card)
        #expect(fixture.engine.addContact(card, from: .scan, unblock: false) == .added(bob.nodeId))
        #expect(fixture.engine.blobExchange.wants[photo.hash]?.author == bob.nodeId)
    }

    @Test func aRequestGroupsRatchetSealedPhotoWaitsForAccept() throws {
        let iphone = try EngineFixture.ratcheting(alice)
        let android = try AndroidPeer(carol)
        try iphone.pin(android)
        let group = roster([carol, alice], createdBy: carol)
        let author = GroupFormAuthor(android, in: group.id)
        let seed = try author.seedDm(to: alice, prekey: try iphone.ourPrekey(), id: frameIdOf("seed-1"), sentAt: EngineFixture.start)
        iphone.deliver(seed, from: carol)
        let photo = try sealedPhoto()
        let frame = try author.frame(group, id: frameIdOf("gm-1"), sealing: photo.content.encoded, sentAt: EngineFixture.start + 1)
        iphone.deliver(frame, from: carol)
        #expect(iphone.stores.messages.message(frameIdOf("gm-1"))?.attachment?.hash == photo.hash, "opened in the group form")
        #expect(!iphone.engine.blobExchange.isWanted(photo.hash), "a group no known sender posts in is a request")
        iphone.advance(60_000)
        #expect(!iphone.engine.blobExchange.isWanted(photo.hash), "nor at the re-offer")
        iphone.engine.accept(group.id)
        #expect(iphone.engine.blobExchange.wants[photo.hash]?.author == carol.nodeId)
    }
}
