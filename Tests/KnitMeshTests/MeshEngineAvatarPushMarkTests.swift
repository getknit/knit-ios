import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A pushed AVATAR past the photo's ceiling never passes its pusher over (contract `ios-avatar-push-mark`, trial run
/// 20261031-021140), beside ``MeshEngineAvatarCeilingTests``, through a real link manager into the engine, as ``Mesh``
/// drives them (``PipeNode``): only the link knows a stream's kind, so a direct ``MeshEngine/fileOverLimit(_:from:)`` call
/// cannot tell a push from a fetch. Bob is asked for dave's photo, wanted only as a photo, and then pushes a photo of
/// the same hash past the ceiling: the push marks nobody, withdraws nothing and steps nothing (`ceilingOf` and
/// `refuseOver`, knit-next `FileIntake.kt:344-363` and `:388-398` at `a0b52f865`), while the fetch's own stream past it
/// still passes bob over and withdraws the ask.
@Suite struct MeshEngineAvatarPushMarkTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let dave = TestPeer(seed: 4)
    private let channel = ChannelID(70)
    private let photo = BlobHash(of: Array("dave's face".utf8))

    private func frame(_ frame: TestFrame) -> [UInt8] {
        LinkRig.admittedRecord(frame)
    }

    private func header(_ kind: FileHeader.Kind) -> [UInt8] {
        let header = FileHeader(kind: kind, key: photo.string, mime: "image/jpeg", size: FileIntake.maxAvatarBytes + 1)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    /// The frames alice wrote to bob of `type` that name the photo, in order.
    private func written(_ node: PipeNode, _ type: FrameType) -> [RelayEnvelope] {
        let envelopes = node.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }
        return envelopes.filter { $0.type == type && hashes(of: $0).contains(photo.string) }
    }

    private func hashes(of envelope: RelayEnvelope) -> [String] {
        switch envelope.type {
        case .blobRequest:
            (try? BlobRequestContent(decoding: envelope.payload)).map { [$0.hash] } ?? []
        case .blobHave:
            (try? BlobHaveContent(decoding: envelope.payload))?.hashes ?? []
        case .blobCancel:
            (try? BlobCancelContent(decoding: envelope.payload)).map { [$0.hash] } ?? []
        default:
            []
        }
    }

    /// Alice, linked to bob, who holds dave's photo and has been asked for it, wanted only as a photo.
    private func asking() throws -> (PipeNode, ManualClock) {
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let node = PipeNode(alice, clock: clock, seed: 7)
        node.start()
        node.apply(node.links.handle(.accepted(channel)))
        // Bob's HELLO as a build from before the link's proof writes it, so the link registers on it alone.
        let hello = Hello(nodeId: bob.nodeId.string, capabilities: Capabilities.local.union(.blobHave).subtracting(.linkProof)).payload
        node.receive(LinkRecord(.hello, payload: hello).encoded ?? [], on: channel)
        node.receive(frame(try dave.profile(publishedAt: EngineFixture.start, avatarHash: photo.string)), on: channel)
        #expect(node.engine.blobExchange.isPhotoOnly(photo))
        node.receive(frame(bob.blobHas([BlobHasItem(hash: photo.string, state: .have, size: 1024)], re: "bob-photo")), on: channel)
        #expect(written(node, .blobRequest).count == 1, "bob is asked")
        return (node, clock)
    }

    @Test func aPushedAvatarPastTheCeilingMarksNobodyAndWithdrawsNothing() throws {
        let (node, clock) = try asking()
        // Cut at its header, its stream read past to its END, as bob's link would send it.
        node.receive(header(.avatar) + (LinkRecord(.fileEnd).encoded ?? []), on: channel)
        #expect(node.links.filesRefused == 1, "cut off at its header")
        #expect(node.engine.blobExchange.counts.photosOverCeiling == 0)
        #expect(!node.engine.blobExchange.photoRefusals.isMarked(photo, holder: bob.nodeId))
        #expect(written(node, .blobCancel).isEmpty, "the ask on bob stands")
        #expect(!node.log.all.contains { $0.contains("passed over") })
        #expect(node.log.all.contains { $0.contains("over its limit of \(FileIntake.maxAvatarBytes)B, AVATAR") })
        // Nothing stepped the want on: bob is asked again at the want's own pace, never passed over.
        let asked = written(node, .blobRequest).count + written(node, .blobHave).count
        for _ in 0..<3 {
            clock.advance(60_000)
            node.fireDueTimers()
        }
        #expect(written(node, .blobRequest).count + written(node, .blobHave).count > asked, "bob is still asked")
        #expect(!node.engine.blobExchange.photoRefusals.isMarked(photo, holder: bob.nodeId))
    }

    @Test func theFetchesOwnStreamPastTheCeilingPassesBobOverAndWithdrawsTheAsk() throws {
        let (node, _) = try asking()
        node.receive(header(.attachment), on: channel)
        #expect(node.engine.blobExchange.counts.photosOverCeiling == 1)
        #expect(node.engine.blobExchange.photoRefusals.isMarked(photo, holder: bob.nodeId))
        #expect(written(node, .blobCancel).count == 1, "the ask on bob is withdrawn")
    }
}
