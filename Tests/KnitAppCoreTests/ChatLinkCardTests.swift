import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// A link's preview card in a thread (ADR 2026-11.hcvg): opened off the main actor once its blob is here, drawn only in
/// a build with link previews, and only beside a link in the words it describes (`linkCardFor` in knit-next).
@MainActor
@Suite struct ChatLinkCardTests {
    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]

    private static func card(_ url: String = "https://example.com/a", title: String = "A page") -> LinkPreviewBlob {
        LinkPreviewBlob(url: url, title: title, description: "What it says", image: jpeg, imageMime: "image/jpeg")
    }

    /// Stores `blob` as the room would, and a room post from Sam saying `body` and carrying it.
    @discardableResult
    private func post(_ body: String, card blob: [UInt8], holding: Bool = true, in rig: AppRig) async -> MessageAttachment {
        let hash = BlobHash(of: blob)
        if holding {
            rig.stores.blobs.insert(blob, hash: hash, mime: LinkPreviewBlob.mime, storedAt: 1)
        }
        let attachment = MessageAttachment(hash: hash, mime: LinkPreviewBlob.mime)
        await rig.receive(body, from: AppRig.sam.nodeId, attachment: attachment)
        return attachment
    }

    /// The thread's last message, once every card it asked for has been read.
    private func settled(_ model: ChatModel, _ rig: AppRig, _ attachment: MessageAttachment) async throws -> ChatMessage {
        _ = model.state
        await rig.session.linkCards?.open(attachment.hash, key: attachment.key)
        return try #require(model.state.messages.last)
    }

    // MARK: Drawn

    /// The card opens after the thread first asks, and the thread draws it beside the link, labelled with the host from
    /// its own address. It is no attachment: no ring, wait or tap counts it.
    @Test func aCardIsDrawnBesideTheLinkItDescribes() async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let attachment = await post("look at https://example.com/a", card: Self.card().encoded, in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(model.state.messages.last?.card == nil, "it opens off the main actor")
        let message = try await settled(model, rig, attachment)
        let card = try #require(message.card)
        #expect(card.url == "https://example.com/a" && card.host == "example.com" && card.title == "A page")
        #expect(card.description == "What it says" && card.hasImage && card.inRoom)
        #expect(card.hash == attachment.hash && card.key == nil)
        #expect(card.moderationText == "A page\nWhat it says")
        #expect(message.attachment == nil)
        #expect(rig.session.picture(of: card) == Self.jpeg)
    }

    /// The links compare normalized: a typed `http://`, a `www.` address and a fragment still match the card's form.
    @Test(arguments: [
        ("see http://Example.com/a#top", "https://example.com/a"),
        ("www.example.com/x", "https://www.example.com/x"),
        ("two: https://other.example/ and https://example.com/a", "https://example.com/a"),
    ])
    func aLinkMatchesItsCardOnceNormalized(body: String, url: String) async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let attachment = await post(body, card: Self.card(url).encoded, in: rig)
        let message = try await settled(ChatModel(conversationId: Conversations.nearby, session: rig.session), rig, attachment)
        #expect(message.card?.url == url)
    }

    /// A blank title shows the host, as Android's card does.
    @Test func aCardWithNoTitleShowsItsHost() async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let blob = LinkPreviewBlob(url: "https://www.example.com/a", title: " ")
        let attachment = await post("https://www.example.com/a", card: blob.encoded, in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let card = try #require(try await settled(model, rig, attachment).card)
        #expect(card.title == "example.com" && !card.hasImage && card.description == nil && card.moderationText.isEmpty)
    }

    // MARK: Not drawn

    /// A sender cannot attach one page's card to another page's link, nor a card to words with no link at all.
    @Test(arguments: [
        ("look at https://example.com/b", "another path"),
        ("look at https://evil.example/a", "another host"),
        ("no link at all", "no link"),
        ("https://10.0.0.1/a", "a link no card is fetched for"),
    ])
    func aCardForAnotherPageIsNotDrawn(body: String, why: String) async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let attachment = await post(body, card: Self.card().encoded, in: rig)
        let message = try await settled(ChatModel(conversationId: Conversations.nearby, session: rig.session), rig, attachment)
        #expect(message.card == nil, "\(why)")
    }

    /// A build without link previews, a release build, draws no card and reads none: it behaves as before.
    @Test func aBuildWithoutLinkPreviewsDrawsNone() async throws {
        let rig = AppRig()
        await post("look at https://example.com/a", card: Self.card().encoded, in: rig)
        let message = try #require(ChatModel(conversationId: Conversations.nearby, session: rig.session).state.messages.last)
        #expect(rig.session.linkCards == nil && message.card == nil && message.attachment == nil)
    }

    /// A blob that is not a card, another layout, or a card whose address is no plain web address is refused, and the
    /// thread draws nothing for it.
    @Test(arguments: [
        ([UInt8]("not cbor".utf8), "not a card"),
        (LinkPreviewBlob(version: 2, url: "https://example.com/a").encoded, "a newer layout"),
        (LinkPreviewBlob(url: "javascript:alert(1)").encoded, "no web address"),
    ])
    func aBlobThatIsNoCardIsRefused(blob: [UInt8], why: String) async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let attachment = await post("look at https://example.com/a", card: blob, in: rig)
        let message = try await settled(ChatModel(conversationId: Conversations.nearby, session: rig.session), rig, attachment)
        #expect(message.card == nil, "\(why)")
        #expect(rig.session.linkCards?.openedCount == 0)
    }

    /// Nothing is read for a blob not here yet. Once it lands the thread asks again, and draws it.
    @Test func aCardWhoseBlobLandsLaterIsDrawnThen() async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let blob = Self.card().encoded
        let attachment = await post("look at https://example.com/a", card: blob, holding: false, in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(try await settled(model, rig, attachment).card == nil)
        rig.stores.blobs.insert(blob, hash: attachment.hash, mime: LinkPreviewBlob.mime, storedAt: 2)
        await rig.session.handle(.attachmentArrived(attachment.hash))
        #expect(try await settled(model, rig, attachment).card?.url == "https://example.com/a")
    }

    /// A DM's card is sealed like a photo: it opens with the key its message carried, and is labelled outside the room.
    /// One whose key does not open it is refused.
    @Test func aSealedCardOpensWithItsKey() async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        let sealed = try #require(AttachmentCrypto.seal(Self.card().encoded))
        let hash = BlobHash(of: sealed.blob)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: LinkPreviewBlob.mime, storedAt: 1)
        let attachment = MessageAttachment(hash: hash, mime: LinkPreviewBlob.mime, key: Base64.encode(sealed.key))
        await rig.receive("look at https://example.com/a", from: AppRig.sam.nodeId, to: rig.me, attachment: attachment)
        let model = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session)
        let card = try #require(try await settled(model, rig, attachment).card)
        #expect(card.key == attachment.key && !card.inRoom)
        #expect(rig.session.picture(of: card) == Self.jpeg)
        let cards = try #require(rig.session.linkCards)
        #expect(await cards.open(hash, key: Base64.encode([UInt8](repeating: 7, count: 32))) == nil, "a wrong key opens nothing")
        #expect(await cards.open(hash, key: nil) == nil, "nor does none")
    }

    // MARK: The memo

    /// A card is read once however often it is asked for, a refused blob is never read again, and a missing one is read
    /// again at the next ask. Past ``LinkCards/cardsKept`` the card asked for least recently is let go, and read again.
    @Test func cardsAreReadOnceAndKeptWithinTheirBound() async {
        let reads = Lock(0)
        let held = Lock<[BlobHash: [UInt8]]>([:])
        let cards = LinkCards { hash in
            reads.withLock { $0 += 1 }
            return held.withLock { $0[hash] }
        }
        let blobs = (0...LinkCards.cardsKept).map { Self.card("https://example.com/\($0)").encoded }
        let first = BlobHash(of: blobs[0])
        #expect(await cards.open(first, key: nil) == nil && reads.withLock { $0 } == 1)
        #expect(await cards.open(first, key: nil) == nil && reads.withLock { $0 } == 2, "a missing blob is read again")
        held.withLock { store in
            for blob in blobs {
                store[BlobHash(of: blob)] = blob
            }
            store[BlobHash(of: [1])] = [1]
        }
        #expect(await cards.open(first, key: nil)?.url == "https://example.com/0")
        #expect(cards.card(first, key: nil) != nil && reads.withLock { $0 } == 3, "an open card is not read again")
        #expect(await cards.open(first, key: nil) != nil && reads.withLock { $0 } == 3)
        #expect(cards.openedCount == 1)
        #expect(await cards.open(BlobHash(of: [1]), key: nil) == nil && cards.card(BlobHash(of: [1]), key: nil) == nil)
        #expect(await cards.open(BlobHash(of: [1]), key: nil) == nil && reads.withLock { $0 } == 4, "a refused blob is read once")
        #expect(cards.openedCount == 1, "a refusal opens nothing")
        for blob in blobs.dropFirst() {
            await cards.open(BlobHash(of: blob), key: nil)
        }
        #expect(cards.openedCount == LinkCards.cardsKept + 1)
        #expect(cards.card(first, key: nil) == nil, "the card asked for least recently is let go")
        #expect(cards.card(BlobHash(of: blobs[1]), key: nil) != nil)
    }

    /// Past ``LinkCards/refusalsKept`` refusals the oldest is forgotten, and its blob read again when it is asked for.
    @Test func refusalsAreRememberedWithinTheirBound() async {
        let reads = Lock(0)
        let cards = LinkCards { _ in
            reads.withLock { $0 += 1 }
            return [1]
        }
        let hashes = (0...LinkCards.refusalsKept).map { BlobHash(of: [UInt8(truncatingIfNeeded: $0), UInt8($0 / 256)]) }
        for hash in hashes {
            await cards.open(hash, key: nil)
        }
        #expect(reads.withLock { $0 } == hashes.count)
        await cards.open(hashes[hashes.count - 1], key: nil)
        #expect(reads.withLock { $0 } == hashes.count, "the newest refusal is remembered")
        await cards.open(hashes[0], key: nil)
        #expect(reads.withLock { $0 } == hashes.count + 1, "the oldest is forgotten")
    }

    /// A thread keeps the cards it has drawn while it is open, so one the session's memo let go stays drawn and is not read
    /// again.
    @Test func aThreadKeepsTheCardsItDrew() async throws {
        let rig = AppRig(linkPreviews: LinkPreviews())
        let attachment = await post("look at https://example.com/a", card: Self.card().encoded, in: rig)
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(try await settled(model, rig, attachment).card != nil)
        let cards = try #require(rig.session.linkCards)
        for index in 0..<LinkCards.cardsKept {
            let blob = Self.card("https://example.com/\(index)").encoded
            rig.stores.blobs.insert(blob, hash: BlobHash(of: blob), mime: LinkPreviewBlob.mime, storedAt: 1)
            await cards.open(BlobHash(of: blob), key: nil)
        }
        #expect(cards.card(attachment.hash, key: nil) == nil, "the memo let it go")
        #expect(model.state.messages.last?.card?.url == "https://example.com/a", "the thread keeps it")
    }
}
