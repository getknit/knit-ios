import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Photos in chats as the app shows them: picked into the composer, sent with words or alone, owed until their bytes
/// arrive, opened with their key, and named in the lists and notifications (ADR 2026-10.nh55).
@MainActor
@Suite struct ChatPhotoTests {
    private static let picked = Data("a picked photo".utf8)

    /// Stores a message from `sender` carrying `attachment`, as the engine would on arrival.
    @discardableResult
    private func receive(
        _ body: String, carrying attachment: MessageAttachment, from sender: NodeId, to recipient: NodeId? = nil, in rig: AppRig
    ) async -> MessageRecord {
        let record = MessageRecord(
            id: "\(sender)-\(body)-\(attachment.hash.string.prefix(8))",
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: rig.me),
            body: body,
            sentAt: 1000,
            arrivedAt: 1000,
            attachment: attachment
        )
        rig.stores.messages.save(record)
        await rig.session.handle(.received(record, isRequest: rig.session.threads().isRequest(record.conversationId)))
        return record
    }

    // MARK: The composer

    /// The composer's button adds a photo while there is nothing to send. A photo held sends alone or with the words,
    /// and both clear once the message is stored.
    @Test func aPickedPhotoIsHeldThenSentAloneAndCleared() async throws {
        let rig = AppRig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec())
        #expect(model.offersPhoto && !model.canSend)
        await model.choosePhoto(Self.picked)
        let staged = try #require(model.staged)
        #expect(staged.photo.bytes == Array("ready ".utf8) + Array(Self.picked), "what the codec prepared, not what was picked")
        #expect(staged.hash == BlobHash(of: staged.photo.bytes))
        #expect(!model.offersPhoto && model.canSend, "a photo needs no words")
        await model.send()
        #expect(model.staged == nil && model.offersPhoto)
        #expect(rig.mesh.calls.photos == [staged.hash])
        let sent = try #require(model.state.messages.last)
        #expect(sent.body.isEmpty && sent.isMine)
        #expect(sent.attachment == ChatAttachment(hash: staged.hash, kind: .photo, key: nil, isHeld: true, label: Copy.Attachments.photo))
    }

    @Test func aCaptionGoesWithThePhoto() async throws {
        let rig = AppRig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec())
        model.draft = "The view from the top"
        #expect(!model.offersPhoto, "words to send turn the button into Send")
        await model.choosePhoto(Self.picked)
        await model.send()
        let sent = try #require(model.state.messages.last)
        #expect(sent.body == "The view from the top" && sent.attachment?.kind == .photo)
        #expect(model.draft.isEmpty && model.staged == nil)
    }

    /// A photo the picker could not hand over, or the codec cannot read, says so, and a photo already held stays.
    @Test func aPhotoThatCannotBeReadSaysSoAndOneHeldCanBeRemoved() async {
        let rig = AppRig()
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec(reads: false))
        await model.choosePhoto(Self.picked)
        #expect(model.photoFailed && model.staged == nil)

        let reading = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec())
        await reading.choosePhoto(nil)
        #expect(reading.photoFailed)
        reading.photoFailed = false
        await reading.choosePhoto(Self.picked)
        #expect(reading.staged != nil && !reading.photoFailed)
        reading.removePhoto()
        #expect(reading.staged == nil && reading.offersPhoto)
        #expect(ChatModel(conversationId: Conversations.nearby, session: rig.session).offersPhoto, "a thread with no codec still offers")
    }

    /// A send the mesh refuses keeps the photo in the composer, to try again.
    @Test func aRefusedSendKeepsThePhoto() async {
        let rig = AppRig()
        let unknown = GroupId.derive([rig.me.string, AppRig.sam.nodeId.string])
        let model = ChatModel(conversationId: unknown, session: rig.session, codec: FakeCodec())
        await model.choosePhoto(Self.picked)
        await model.send()
        #expect(model.staged != nil)
    }

    // MARK: The thread

    /// A photo whose bytes have not arrived is owed, and shows once they land.
    @Test func aPhotoOnItsWayIsOwedUntilItsBytesArrive() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let bytes = Array("Sam's sunset".utf8)
        let hash = BlobHash(of: bytes)
        await receive("Sunset", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), from: AppRig.sam.nodeId, in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(model.state.messages.first?.attachment?.isHeld == false)
        rig.stores.blobs.insert(bytes, hash: hash, mime: "image/jpeg", storedAt: 2)
        await rig.session.handle(.attachmentArrived(hash))
        let shown = try #require(model.state.messages.first?.attachment)
        #expect(shown.isHeld && shown.key == nil && shown.label == Copy.Attachments.photo)
        #expect(rig.session.attachment(hash, key: nil) == bytes, "the room's photo is its own blob")
    }

    /// A DM's photo is sealed: its blob opens with the key its message carried, in memory, and with nothing else.
    @Test func aSealedPhotoOpensWithItsKeyAlone() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let photo = Array("for your eyes".utf8)
        let sealed = try #require(AttachmentCrypto.seal(photo))
        let hash = BlobHash(of: sealed.blob)
        let key = Base64.encode(sealed.key)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: "image/jpeg", storedAt: 1)
        await receive(
            "", carrying: MessageAttachment(hash: hash, mime: "image/jpeg", key: key), from: AppRig.sam.nodeId, to: rig.me, in: rig)
        let shown = try #require(ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session).state.messages.first?.attachment)
        #expect(shown.key == key && shown.isHeld)
        #expect(rig.session.attachment(hash, key: key) == photo)
        #expect(rig.session.attachment(hash, key: Base64.encode([UInt8](repeating: 7, count: 32))) == nil, "a wrong key opens nothing")
        #expect(rig.session.attachment(hash, key: "not base64!") == nil)
        #expect(rig.session.attachment(BlobHash(of: photo), key: key) == nil, "a blob that is missing opens nothing")
    }

    /// What a message carries is told by its name, then its type (`AttachmentKindTest`), and a link's card shows
    /// nothing the link in the text does not.
    @Test func kindsFollowAndroidsOrder() {
        let hash = BlobHash(of: Array("x".utf8))
        let cases: [(MessageAttachment, AttachmentKind)] = [
            (MessageAttachment(hash: hash, mime: "image/jpeg", name: "photo.jpg"), .file),
            (MessageAttachment(hash: hash, mime: "audio/aac"), .voice),
            (MessageAttachment(hash: hash, mime: AttachmentKind.linkCardType), .link),
            (MessageAttachment(hash: hash, mime: "image/png"), .photo),
            (MessageAttachment(hash: hash), .photo),
            (MessageAttachment(hash: hash, mime: "application/pdf"), .file),
            (MessageAttachment(hash: hash, mime: "IMAGE/JPEG"), .file),
        ]
        for (attachment, kind) in cases {
            #expect(AttachmentKind(attachment) == kind, "\(attachment)")
        }
        #expect(ChatAttachment(MessageAttachment(hash: hash, mime: AttachmentKind.linkCardType), isHeld: true) == nil)
        #expect(ChatAttachment(MessageAttachment(hash: hash, mime: "audio/aac"), isHeld: false)?.label == Copy.Attachments.voiceMessage)
        #expect(ChatAttachment(MessageAttachment(hash: hash, mime: "text/plain", name: "notes.txt"), isHeld: false)?.label == "notes.txt")
        #expect(ChatAttachment(MessageAttachment(hash: hash, mime: "text/plain"), isHeld: false)?.label == Copy.Attachments.file)
    }

    // MARK: Lines

    /// A message with no words says what it carries in the chat list, the requests and a notification; words win.
    @Test func aWordlessMessageSaysWhatItCarries() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let hash = BlobHash(of: Array("y".utf8))
        let lines: [(MessageAttachment, String)] = [
            (MessageAttachment(hash: hash, mime: "image/jpeg"), Copy.Attachments.photoPreview),
            (MessageAttachment(hash: hash, mime: "image/gif"), Copy.Attachments.gifPreview),
            (MessageAttachment(hash: hash, mime: "audio/aac"), Copy.Attachments.voicePreview),
            (MessageAttachment(hash: hash, mime: "application/pdf", name: "map.pdf"), Copy.Attachments.filePreview("map.pdf")),
            (MessageAttachment(hash: hash, mime: "application/zip"), Copy.Attachments.filePreview(Copy.Attachments.file)),
            (MessageAttachment(hash: hash, mime: AttachmentKind.linkCardType), Copy.Attachments.linkPreview),
        ]
        for (attachment, line) in lines {
            #expect(AttachmentKind.preview(of: attachment) == line)
        }
        #expect(Copy.Attachments.photoPreview == "📷 Photo" && Copy.Attachments.filePreview("map.pdf") == "📎 map.pdf")

        await receive("", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), from: AppRig.sam.nodeId, in: rig)
        let roomRow = ChatListModel(session: rig.session).state.rows.first(where: \.isRoom)
        let room = try #require(roomRow)
        #expect(room.preview == "Sam: 📷 Photo")
        #expect(rig.notifier.posted.last?.body == "Sam: 📷 Photo")
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await receive("", carrying: MessageAttachment(hash: hash, mime: "image/gif"), from: AppRig.sam.nodeId, to: rig.me, in: rig)
        #expect(rig.notifier.posted.last?.body == "🎞️ GIF", "a DM's notification is titled for its sender")
        await receive("Look", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), from: AppRig.sam.nodeId, to: rig.me, in: rig)
        #expect(rig.notifier.posted.last?.body == "Look", "words win")
    }

    @Test func aStrangersWordlessPhotoIsARequestThatSaysWhatItCarries() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.stranger, name: "Kim")
        let hash = BlobHash(of: Array("z".utf8))
        await receive("", carrying: MessageAttachment(hash: hash, mime: "image/jpeg"), from: AppRig.stranger.nodeId, to: rig.me, in: rig)
        let request = try #require(RequestsModel(session: rig.session).rows.first)
        #expect(request.preview == Copy.Attachments.photoPreview)
    }
}
