import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The photo's ceiling against what names a blob (ADR 2026-10.r88m), beside ``MeshEngineAvatarCeilingTests``: the
/// re-want's kind follows the rows it takes, a held in-ceiling copy stays named whatever the session refused, and an
/// echo's bytes stay for its asker.
@Suite struct MeshEngineAvatarCeilingRowsTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private static let querying = MeshConfiguration(queriesBlobHolders: true)
    private let android = Capabilities.local.union(.blobHave)
    /// A photo one byte past the ceiling.
    private let oversize = [UInt8](repeating: 0xD8, count: FileIntake.maxAvatarBytes + 1)
    private let small: [UInt8] = Array("a 256-pixel JPEG, in spirit".utf8)

    private func profile(of peer: TestPeer, photo: BlobHash?, version: Int64, from fixture: EngineFixture) throws -> TestFrame {
        try peer.profile(version: version, publishedAt: fixture.clock.wallMilliseconds() + version, avatarHash: photo?.string)
    }

    /// The neighbours asked for `hash`, in order.
    private func asked(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobRequest).filter { try BlobRequestContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    @Test func aMessageRequestNamingAnOversizePhotoDoesNotMakeItAnAttachmentToFetchAgain() throws {
        // Bob, a stranger, advertises an over-ceiling photo and sends a request naming it. The request's row is no row the
        // re-want takes, so the photo stays photo-only: its holder is passed over once, and never asked again.
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(carol, capabilities: android)
        let hash = BlobHash(of: oversize)
        fixture.deliver(try profile(of: bob, photo: nil, version: 1, from: fixture), from: bob)
        let naming = MessageContent(body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg")
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-req"), sentAt: EngineFixture.start, content: naming), from: carol)
        fixture.deliver(try profile(of: bob, photo: hash, version: 2, from: fixture), from: carol)
        fixture.deliver(carol.blobHas([BlobHasItem(hash: hash.string, state: .have, size: 1000)], re: "carol-1"), from: carol)
        #expect(try asked(fixture, for: hash) == [carol.nodeId])
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.isPhotoOnly(hash), "the re-want keeps the photo's kind")
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: oversize))
        #expect(!fixture.stores.blobs.contains(hash))
        for _ in 0..<3 {
            fixture.advance(60_000)
        }
        #expect(try asked(fixture, for: hash) == [carol.nodeId], "exactly one ask across three re-offers")
    }

    @Test func anInCeilingPushOfARefusedHashIsShownAndKeptPastTheSweep() throws {
        let fixture = EngineFixture(alice)
        fixture.link(dave)
        let hash = BlobHash(of: small)
        fixture.engine.blobExchange.refusePhoto(hash)
        fixture.deliver(try profile(of: dave, photo: hash, version: 5, from: fixture), from: dave)
        fixture.engine.receiveFile(InboundFile(from: dave.nodeId, kind: .avatar, hash: hash, mime: "image/jpeg", bytes: small))
        #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == hash)
        for _ in 0..<4 {
            fixture.advance(fixture.engine.configuration.sweepMilliseconds)
        }
        #expect(fixture.stores.blobs.contains(hash), "held, in the ceiling, and a face: named whatever the session refused")
        #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == hash)
    }

    @Test func anEchosOversizeBytesStayForItsAskerAndAreNeverShown() throws {
        // Dave is linked, so his photo is left to his push and is no want of ours; Carol asks for it, which makes an echo.
        let fixture = EngineFixture(alice)
        fixture.link(carol, dave, capabilities: android)
        let hash = BlobHash(of: oversize)
        fixture.deliver(try profile(of: dave, photo: hash, version: 5, from: fixture), from: dave)
        fixture.deliver(carol.blobRequest(for: hash.string, id: frameIdOf("breq-echo-1")), from: carol)
        #expect(fixture.engine.blobExchange.isEcho(hash))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: oversize))
        #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == nil, "never shown")
        #expect(fixture.engine.blobExchange.isPhotoRefused(hash))
        #expect(fixture.stores.blobs.contains(hash), "kept for its asker")
        fixture.deliver(carol.blobRequest(for: hash.string, id: frameIdOf("breq-echo-2")), from: carol)
        #expect(fixture.transport.files.contains { $0.hash == hash && $0.to == carol.nodeId }, "served from the held copy")
    }

    @Test func aPhotoOnlyAskNeverResumesPastTheCeiling() throws {
        // A prefix longer than the ceiling, kept for an earlier attachment want of the same hash, is dropped: the ask goes
        // from byte 0, so the photo's ceiling binds the whole file.
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        let hash = BlobHash(of: small)
        let prefix = [UInt8](repeating: 1, count: FileIntake.maxAvatarBytes + 1)
        try #require(fixture.engine.partials.keep(hash, bytes: prefix, basedOn: nil, now: 0))
        try #require(fixture.engine.partials.length(hash) == prefix.count)
        fixture.deliver(try profile(of: dave, photo: hash, version: 5, from: fixture), from: carol)
        #expect(fixture.engine.blobExchange.isPhotoOnly(hash))
        let ask = try #require(fixture.transport.written(.blobRequest).first)
        #expect(try BlobRequestContent(decoding: ask.envelope.payload).offset == nil)
        #expect(fixture.engine.partials.length(hash) == 0)
    }
}
