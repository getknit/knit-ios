import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A photo's size, read from its bytes on this phone and kept on its message, so a thread holds the photo's place at
/// its shape from its first frame (ADR 2026-10.6cas): read as it is sent, as its bytes land, and at launch for the
/// photos already held.
@MainActor
@Suite struct PhotoSizeTests {
    /// Reads any bytes as a photo as wide as they are long and three pixels tall, so a size shows what was read.
    private static let ruler: @Sendable ([UInt8]) -> PhotoDimensions? = { PhotoDimensions(width: $0.count, height: 3) }

    private func size(of bytes: [UInt8]) -> PhotoDimensions? {
        Self.ruler(bytes)
    }

    /// Stores a message from Sam carrying `attachment`, as the engine would on arrival.
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

    @Test func aSentPhotoIsSizedAsItGoes() async throws {
        let rig = AppRig(reading: Self.ruler)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec())
        await model.choosePhoto(Data("a picked photo".utf8))
        let staged = try #require(model.staged)
        await model.send()
        #expect(model.state.messages.last?.attachment?.dimensions == size(of: staged.photo.bytes))
    }

    /// A photo still on its way has no size; its bytes landing size it before the thread redraws for them.
    @Test func aPhotoIsSizedAsItsBytesLand() async {
        let rig = AppRig(reading: Self.ruler)
        await rig.pin(AppRig.sam, name: "Sam")
        let bytes = Array("Sam's sunset".utf8)
        let hash = BlobHash(of: bytes)
        await receive("sunset", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(model.state.messages.first?.attachment?.dimensions == nil)
        rig.stores.blobs.insert(bytes, hash: hash, mime: "image/jpeg", storedAt: 2)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(model.state.messages.first?.attachment?.dimensions == size(of: bytes))
    }

    /// A DM's photo is read from what its key opens, never from the sealed blob.
    @Test func aSealedPhotoIsSizedFromWhatItsKeyOpens() async throws {
        let rig = AppRig(reading: Self.ruler)
        await rig.pin(AppRig.sam, name: "Sam")
        let photo = Array("for your eyes".utf8)
        let sealed = try #require(AttachmentCrypto.seal(photo))
        let hash = BlobHash(of: sealed.blob)
        let attachment = MessageAttachment(hash: hash, mime: "image/jpeg", key: Base64.encode(sealed.key))
        let record = await receive("sealed", carrying: attachment, to: rig.me, in: rig)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: "image/jpeg", storedAt: 2)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(rig.stores.messages.message(record.id)?.attachment?.dimensions == size(of: photo))
    }

    /// A launch reads the size of every photo already held that has none, as after an update to a build that keeps
    /// sizes. A photo still on its way waits for its bytes, and a file is never read as one.
    @Test func aLaunchSizesThePhotosAlreadyHeld() async {
        let rig = AppRig(reading: Self.ruler)
        let held = Array("a held photo".utf8)
        let notes = Array("trail notes".utf8)
        let owed = BlobHash(of: Array("on its way".utf8))
        rig.stores.blobs.insert(held, hash: BlobHash(of: held), mime: "image/jpeg", storedAt: 1)
        rig.stores.blobs.insert(notes, hash: BlobHash(of: notes), mime: "application/pdf", storedAt: 1)
        let photo = await receive("photo", carrying: MessageAttachment(hash: BlobHash(of: held), mime: "image/jpeg"), in: rig)
        let file = MessageAttachment(hash: BlobHash(of: notes), mime: "application/pdf", name: "notes.pdf")
        let filed = await receive("file", carrying: file, in: rig)
        let waiting = await receive("owed", carrying: MessageAttachment(hash: owed, mime: "image/jpeg"), in: rig)
        rig.mesh.finish()
        await rig.session.listen()
        #expect(rig.stores.messages.message(photo.id)?.attachment?.dimensions == size(of: held))
        #expect(rig.stores.messages.message(filed.id)?.attachment?.dimensions == nil)
        #expect(rig.stores.messages.message(waiting.id)?.attachment?.dimensions == nil)
    }

    /// Without a reader, as on a build that cannot read images, nothing is sized and a thread draws as before.
    @Test func withoutAReaderNothingIsSized() async {
        let rig = AppRig()
        let bytes = Array("Sam's sunset".utf8)
        let hash = BlobHash(of: bytes)
        rig.stores.blobs.insert(bytes, hash: hash, mime: "image/jpeg", storedAt: 1)
        let record = await receive("sunset", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), in: rig)
        await rig.session.handle(.attachmentArrived(hash))
        #expect(rig.stores.messages.message(record.id)?.attachment?.dimensions == nil)
    }
}

extension AppRig {
    /// A rig whose session reads photos' sizes with `reader`, as the app reads them with ImageIO.
    init(reading reader: @escaping @Sendable ([UInt8]) -> PhotoDimensions?) {
        stores = MeshStores.inMemory()
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores)
        notifier = RecordingNotifier()
        session = AppSession(
            identity: OwnIdentity(bundle: Self.me.bundle),
            stores: stores,
            mesh: mesh,
            notifier: notifier,
            photoDimensions: reader
        )
    }
}
