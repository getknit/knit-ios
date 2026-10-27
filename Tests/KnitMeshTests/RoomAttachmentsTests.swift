import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The attachments a room post may carry on the receiver (`RoomAttachmentsTest.kt` and `InboundPipelineTest.kt` at knit-next
/// `4408e0fca`, from `eccabcd72`; knit-ios #21): a picture, a link-preview card or a video, and nothing else, left off the row
/// and off what custody's frames name, while the frame is carried and relayed as it came.
@Suite struct RoomAttachmentsTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let voice = Array("a voice note".utf8)
    private var voiceHash: BlobHash { BlobHash(of: voice) }

    private func post(_ body: String, hash: String?, mime: String?, id: String = "post-1") throws -> TestFrame {
        let content = ChatContent(body: body, attachmentHash: hash, attachmentMime: mime)
        return try bob.roomPost(body, id: frameIdOf(id), sentAt: EngineFixture.start, content: content)
    }

    // MARK: The rule

    @Test func theRoomAdmitsAPictureACardOrAVideoByTheirExactPrefixes() {
        for admitted in [nil, "image/jpeg", "image/", "application/vnd.knit.link-preview", "video/mp4"] {
            #expect(RoomAttachments.admits(admitted), "\(admitted ?? "nil")")
        }
        for refused in [
            "audio/mpeg", "audio/aac", "application/pdf", "IMAGE/PNG", "Video/mp4", "application/vnd.knit.link-preview2", "", "image",
        ] {
            #expect(!RoomAttachments.admits(refused), "\(refused), case-sensitive as Kotlin's startsWith")
        }
    }

    @Test func onlyACleartextRoomPostNamingAnAttachmentIsRefused() {
        let room = RelayEnvelope(type: .chat, id: "p", senderId: bob.nodeId.string, payload: [])
        let audio = ChatContent(body: "hi", attachmentHash: voiceHash.string, attachmentMime: "audio/mpeg")
        #expect(RoomAttachments.refuses(room, audio))
        #expect(
            RoomAttachments.refuses(room, ChatContent(body: "", attachmentHash: "NOT-A-HASH", attachmentMime: "audio/mpeg")), "the raw hash"
        )
        #expect(!RoomAttachments.refuses(room, ChatContent(body: "", attachmentMime: "audio/mpeg")), "no attachment named")
        #expect(!RoomAttachments.refuses(room, ChatContent(body: "", attachmentHash: voiceHash.string, attachmentMime: "image/png")))
        var direct = room
        direct.recipientId = alice.nodeId.string
        #expect(!RoomAttachments.refuses(direct, audio), "a DM's is sealed and judged by its own thread")
        var group = room
        group.group = roster([bob, alice], createdBy: bob)
        #expect(!RoomAttachments.refuses(group, audio))
        var sealed = audio
        sealed.enc = EncEnvelope(version: EncEnvelope.Version.ratchet, nonce: [UInt8](repeating: 0, count: 12), ct: [1, 2, 3, 4], keys: [])
        #expect(!RoomAttachments.refuses(room, sealed), "a sealed room post opens nowhere")
        var receipt = room
        receipt.type = .receipt
        #expect(!RoomAttachments.refuses(receipt, audio))
    }

    @Test func aRefusedPostWithABlankBodyIsDroppedWholeByKotlinsWhitespace() {
        let room = RelayEnvelope(type: .chat, id: "p", senderId: bob.nodeId.string, payload: [])
        #expect(
            RoomAttachments.dropsWhole(
                room, ChatContent(body: " \n\u{1C}\u{3000}", attachmentHash: voiceHash.string, attachmentMime: "audio/aac")))
        #expect(
            !RoomAttachments.dropsWhole(room, ChatContent(body: "\u{85}", attachmentHash: voiceHash.string, attachmentMime: "audio/aac")),
            "U+0085 is not Kotlin whitespace")
        #expect(!RoomAttachments.dropsWhole(room, ChatContent(body: "hi", attachmentHash: voiceHash.string, attachmentMime: "audio/aac")))
        var quoted = ChatContent(body: "", attachmentHash: voiceHash.string, attachmentMime: "audio/aac")
        quoted.replyTo = ReplyRef(messageId: "m", authorId: alice.nodeId.string, author: "Alice", snippet: "words", hasAttachment: false)
        #expect(RoomAttachments.dropsWhole(room, quoted), "the body alone counts, never the quote")
        #expect(!RoomAttachments.dropsWhole(room, ChatContent(body: "", attachmentHash: voiceHash.string, attachmentMime: "image/png")))
    }

    // MARK: On receipt

    @Test func aVoiceNoteInTheRoomIsLeftOffTheRowAndNeverWanted() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.deliver(try post("listen", hash: voiceHash.string, mime: "audio/mpeg"), from: bob)
        let row = try #require(fixture.stores.messages.message(frameIdOf("post-1")))
        #expect(row.body == "listen" && row.attachment == nil)
        #expect(!fixture.engine.blobExchange.isWanted(voiceHash) && fixture.transport.written(.blobRequest).isEmpty)
        #expect(fixture.stores.custody.contains(frameIdOf("post-1")), "the frame is carried as it came")
        #expect(!fixture.engine.carriedBlobs().contains(voiceHash), "and custody's copy names nothing")
    }

    @Test func aRoomPostThatWasOnlyARefusedAttachmentKeepsNoRowAndIsStillTicked() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.deliver(try post("  ", hash: voiceHash.string, mime: "audio/aac"), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("post-1")) == nil)
        #expect(!fixture.engine.drainEvents().contains { if case .received = $0 { true } else { false } })
        #expect(!fixture.engine.blobExchange.isWanted(voiceHash))
        #expect(fixture.engine.footprint.owedTicks == 1, "acknowledged, as a blocked sender's post is")
    }

    @Test func aPictureKeepsItsAttachmentAndAnUppercaseTypeIsRefused() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let picture = BlobHash(of: Array("a picture".utf8))
        fixture.deliver(try post("", hash: picture.string, mime: "image/png"), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("post-1"))?.attachment == MessageAttachment(hash: picture, mime: "image/png"))
        #expect(fixture.engine.blobExchange.isWanted(picture))
        #expect(fixture.engine.carriedBlobs().contains(picture))
        fixture.deliver(try post("shout", hash: voiceHash.string, mime: "IMAGE/PNG", id: "post-2"), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("post-2"))?.attachment == nil, "refused, as on Android")
        #expect(!fixture.engine.blobExchange.isWanted(voiceHash))
    }

    /// Two engines carry the refused post alike: custody reads none of this, so their digests agree.
    @Test func twoEnginesCarryARefusedPostAndAgreeOnTheirLiveIds() throws {
        let lab = EngineLab([EngineFixture(alice, seed: 11), EngineFixture(TestPeer(seed: 5), seed: 12)])
        lab.link(0, 1)
        try lab[0].pin(bob)
        lab[0].deliver(try post("listen", hash: voiceHash.string, mime: "audio/mpeg"), from: bob)
        lab[0].deliver(try post("", hash: voiceHash.string, mime: "audio/aac", id: "post-2"), from: bob)
        lab.advance(60_000)
        let now = lab[0].clock.wallMilliseconds()
        let ids = Set(lab[0].stores.custody.liveIds(now: now))
        #expect(ids.isSuperset(of: [frameIdOf("post-1"), frameIdOf("post-2")]))
        #expect(Set(lab[1].stores.custody.liveIds(now: now)) == ids)
        #expect(lab[1].stores.messages.message(frameIdOf("post-1"))?.attachment == nil)
    }
}
