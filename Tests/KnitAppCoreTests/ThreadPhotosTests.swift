import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A photo the engine does not fetch says why in its thread (knit-ios #21, ADR 2026-10.vzem): a message request's waits for
/// accept, and a stranger's Nearby photo past the bound on strangers' photos says Knit keeps only the newest.
@MainActor
@Suite struct ThreadPhotosTests {
    /// Stores `sender`'s message carrying a photo named `name`, sent at `sentAt`, as the engine would on arrival.
    @discardableResult
    private func receive(
        photo name: String, from sender: NodeId, to recipient: NodeId? = nil, sentAt: Int64 = 1000, in rig: AppRig
    ) async -> MessageRecord {
        let attachment = MessageAttachment(hash: BlobHash(of: Array(name.utf8)), mime: "image/jpeg")
        let record = MessageRecord(
            id: "\(sender)-\(name)",
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: rig.me),
            body: name,
            sentAt: sentAt,
            arrivedAt: sentAt,
            attachment: attachment
        )
        rig.stores.messages.save(record)
        await rig.session.handle(.received(record, isRequest: rig.session.threads().isRequest(record.conversationId)))
        return record
    }

    private func shown(_ conversation: String, in rig: AppRig) -> [String: ChatAttachment] {
        let messages = ChatModel(conversationId: conversation, session: rig.session).state.messages
        return Dictionary(uniqueKeysWithValues: messages.compactMap { message in message.attachment.map { (message.body, $0) } })
    }

    // MARK: Requests

    /// A stranger's DM photo waits for accept, even with its bytes here, and shows once the request is accepted.
    @Test func aRequestsPhotoWaitsForAcceptWhateverIsHere() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.stranger, name: "Kim")
        let record = await receive(photo: "kim's", from: AppRig.stranger.nodeId, to: rig.me, in: rig)
        let hash = try #require(record.attachment?.hash)
        rig.stores.blobs.insert(Array("kim's".utf8), hash: hash, mime: "image/jpeg", storedAt: 2)
        let waiting = try #require(shown(AppRig.stranger.nodeId.string, in: rig)["kim's"])
        #expect(waiting.waits == .accept && !waiting.isHeld, "only an accept fetches it from its author")
        rig.mesh.accept(AppRig.stranger.nodeId.string)
        let accepted = try #require(shown(AppRig.stranger.nodeId.string, in: rig)["kim's"])
        #expect(accepted.waits == nil && accepted.isHeld)
    }

    /// A contact's DM photo on its way waits for a phone that has it, as before.
    @Test func aContactsPhotoOnItsWayWaitsForNothingButItsBytes() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        await receive(photo: "sam's", from: AppRig.sam.nodeId, to: rig.me, in: rig)
        let owed = try #require(shown(AppRig.sam.nodeId.string, in: rig)["sam's"])
        #expect(owed.waits == nil && !owed.isHeld)
    }

    // MARK: The room's bound

    /// A stranger's ninth room photo pushes out their oldest, which says why it is not coming, while a contact's room
    /// photos never do.
    @Test func aStrangersOldestRoomPhotoPastTheBoundSaysWhy() async {
        let rig = AppRig()
        await rig.pin(AppRig.stranger, name: "Kim")
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        for index in 0...StrangerRoomPhotos.perSender {
            await receive(photo: "kim \(index)", from: AppRig.stranger.nodeId, sentAt: 1000 + Int64(index), in: rig)
            await receive(photo: "sam \(index)", from: AppRig.sam.nodeId, sentAt: 1000 + Int64(index), in: rig)
        }
        let room = shown(Conversations.nearby, in: rig)
        #expect(room["kim 0"]?.waits == .roomBound, "older than Kim's newest eight")
        #expect((1...StrangerRoomPhotos.perSender).allSatisfy { room["kim \($0)"]?.waits == nil })
        #expect((0...StrangerRoomPhotos.perSender).allSatisfy { room["sam \($0)"]?.waits == nil }, "Sam is verified")
    }

    /// A room photo past the bound that is here anyway shows: only one not coming says so.
    @Test func aRoomPhotoPastTheBoundButHereShows() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.stranger, name: "Kim")
        let oldest = await receive(photo: "kim 0", from: AppRig.stranger.nodeId, sentAt: 1000, in: rig)
        for index in 1...StrangerRoomPhotos.perSender {
            await receive(photo: "kim \(index)", from: AppRig.stranger.nodeId, sentAt: 1000 + Int64(index), in: rig)
        }
        let hash = try #require(oldest.attachment?.hash)
        rig.stores.blobs.insert(Array("kim 0".utf8), hash: hash, mime: "image/jpeg", storedAt: 2)
        let held = try #require(shown(Conversations.nearby, in: rig)["kim 0"])
        #expect(held.waits == nil && held.isHeld)
    }

    /// Knowing someone in the table is the engine's `knownSenders`: us, an accepted or written-in DM, or a verified peer.
    @Test func theTableKnowsWhomTheEngineKnows() async {
        let rig = AppRig()
        await rig.pin(AppRig.stranger, name: "Kim")
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        await rig.pin(AppRig.priya, name: "Priya")
        rig.mesh.accept(AppRig.priya.nodeId.string)
        let threads = rig.session.threads()
        #expect(threads.knows(rig.me) && threads.knows(AppRig.sam.nodeId) && threads.knows(AppRig.priya.nodeId))
        #expect(!threads.knows(AppRig.stranger.nodeId))
    }
}
