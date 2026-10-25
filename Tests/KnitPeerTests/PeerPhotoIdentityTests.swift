import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A photo saved from Knit, given new EXIF by Photos and picked again, goes back as the blob every recipient already
/// holds (ADR 2026-10.f3mv, knit-ios #12), over the control lines a pick takes, `heldPhoto(picked:) ?? the bytes`, to an
/// engine on the far end of the link: nobody asks for a byte.
@Suite(.timeLimit(.minutes(1))) struct PeerPhotoIdentityTests {
    /// The picture as Knit for Android sent it, its EXIF Android's.
    private let original = JPEGFixture.jpeg(exif: [JPEGFixture.androidExif])
    /// The same picture as Photos handed it back, its EXIF rewritten.
    private let rewritten = JPEGFixture.jpeg(exif: [JPEGFixture.appleExif])

    /// The node and the far engine linked, each holding the other's profile.
    private func linked() async throws -> PeerRig {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "profile" })
        rig.deliverToFar()
        return rig
    }

    /// Streams sealed blob `blob` to the node over the link, as the far peer would serve its ask, and waits until it is
    /// held.
    private func serve(_ blob: [UInt8], to rig: PeerRig) async {
        rig.radio.emit(.received(PeerRig.channel, rig.fileRecords(.attachment, blob)))
        #expect(await eventually { rig.stores.blobs.contains(BlobHash(of: blob)) }, "the node took the file it asked for")
    }

    /// Saves the node's copy of blob `hash` under `key` as `AppSession.attachmentToSave` does.
    private func save(_ hash: BlobHash, key: String?, in rig: PeerRig) throws {
        let name = try #require(ExiflessJPEG.name(of: original))
        #expect(rig.stores.messages.setAttachmentExiflessHash(hash, key: key, to: name.hash))
    }

    /// The types of the frames the node wrote after the first `skipping`.
    private func written(by rig: PeerRig, after skipping: Int) -> [FrameType] {
        rig.radio.frames(on: PeerRig.channel).dropFirst(skipping).compactMap { try? RelayEnvelope(decoding: $0.signed).type }
    }

    private static let asks: Set<FrameType> = [.blobRequest, .blobHave]

    @Test func aDmPhotoSavedAndPickedWithNewExifGoesBackAsTheBlobItCameAs() async throws {
        let rig = try await linked()
        let sent = try #require(
            rig.farEngine.sendDirectMessage("", to: rig.keys.nodeId, photo: OutgoingPhoto(bytes: original, mime: "image/jpeg"))?.attachment)
        let key = try #require(sent.key)
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "message" && $0["conv"] as? String == rig.far.nodeId.string })
        let sealed = try #require(rig.farEngine.stores.blobs.bytes(of: sent.hash))
        await serve(sealed, to: rig)
        try save(sent.hash, key: key, in: rig)

        let ours = rig.stores.blobs.allHashes()
        let theirs = rig.farEngine.stores.blobs.allHashes()
        let before = rig.radio.frames(on: PeerRig.channel).count
        _ = rig.farTransport.take()
        let photo = Base64.encode(rewritten)
        let reply = try await rig.send(#"{"cmd":"dm","to":"\#(rig.far.nodeId)","photo":"\#(photo)"}"#)
        #expect(reply["reused"] as? Bool == true && reply["attachmentHash"] as? String == sent.hash.string)
        rig.deliverToFar()

        let id = try #require(reply["id"] as? String)
        let arrived = try #require(rig.farEngine.stores.messages.message(id)?.attachment)
        #expect(arrived.hash == sent.hash && arrived.key == key, "the far peer's new row names the blob it sent")
        #expect(written(by: rig, after: before).allSatisfy { !Self.asks.contains($0) }, "the node asked for nothing")
        let farFrames = rig.farTransport.take().compactMap { try? RelayEnvelope(decoding: $0.signed).type }
        #expect(farFrames.allSatisfy { !Self.asks.contains($0) }, "nor did the far peer")
        #expect(rig.stores.blobs.allHashes() == ours, "nothing sealed again")
        #expect(rig.farEngine.stores.blobs.allHashes() == theirs)
        #expect(rig.farEngine.stores.messages.attachmentHashes() == [sent.hash], "no message names another blob")
    }

    @Test func aGroupPhotoSavedAndPickedWithNewExifGoesBackAsTheBlobAThirdMemberHolds() async throws {
        let rig = try await linked()
        let third = ThirdMember(rig)
        #expect(await eventually { rig.stores.peers.peer(third.keys.nodeId) != nil }, "the node pinned the third")
        // Nothing is sent yet: the others learn of the group from its first message.
        let group = try #require(rig.farEngine.createGroup(with: [rig.keys.nodeId, third.keys.nodeId]))
        let photo = OutgoingPhoto(bytes: original, mime: "image/jpeg")
        let sent = try #require(rig.farEngine.sendGroupMessage("", to: group.id, photo: photo)?.attachment)
        let key = try #require(sent.key)
        third.pump()
        let sealed = try #require(rig.farEngine.stores.blobs.bytes(of: sent.hash))
        #expect(await eventually { rig.stores.messages.attachmentHashes().contains(sent.hash) }, "the node took the group's message")
        await serve(sealed, to: rig)
        third.engine.receiveFile(InboundFile(from: rig.far.nodeId, kind: .attachment, hash: sent.hash, mime: "image/jpeg", bytes: sealed))
        #expect(third.engine.stores.blobs.contains(sent.hash), "the third holds the original")
        try save(sent.hash, key: key, in: rig)
        third.pump()

        let thirdBlobs = third.engine.stores.blobs.allHashes()
        let ours = rig.stores.blobs.allHashes()
        _ = third.transport.take()
        let picked = Base64.encode(rewritten)
        let reply = try await rig.send(#"{"cmd":"group-send","conv":"\#(group.id)","photo":"\#(picked)"}"#)
        #expect(reply["reused"] as? Bool == true && reply["attachmentHash"] as? String == sent.hash.string)
        third.pump()

        let id = try #require(reply["id"] as? String)
        let arrived = try #require(third.engine.stores.messages.message(id)?.attachment)
        #expect(arrived.hash == sent.hash && arrived.key == key, "the third's new row names the blob it holds")
        let asked = third.transport.take().compactMap { try? RelayEnvelope(decoding: $0.signed).type }
        #expect(asked.allSatisfy { !Self.asks.contains($0) }, "the third asked for nothing")
        #expect(third.engine.stores.blobs.allHashes() == thirdBlobs && rig.stores.blobs.allHashes() == ours)
        #expect(third.engine.stores.messages.attachmentHashes() == [sent.hash])
    }
}

/// A third group member, linked to the far engine alone, its frames carried by hand: the recipient #12 is for, who already
/// holds the original when the node sends it back.
private final class ThirdMember {
    let keys = identity(3)
    let rig: PeerRig
    let transport: CapturingTransport
    let engine: MeshEngine
    /// How many of the node's frames the third has been handed.
    private var handed = 0

    /// A third member on fresh stores, holding the profiles the far engine carries, its own and the node's, as a
    /// link-up's digest would bring them, and known to both after two rounds.
    init(_ rig: PeerRig) {
        self.rig = rig
        transport = CapturingTransport(peer: rig.far.nodeId)
        engine = MeshEngine(
            identity: keys,
            deviceTag: nil,
            stores: .inMemory(ownProfile: OwnProfile(name: "Third")),
            transport: transport,
            clock: StillClock(),
            random: CountingGenerator(state: 0x5151_5151_5151_5151)
        )
        engine.start()
        engine.linkUp(Neighbor(nodeId: rig.far.nodeId, capabilities: .local))
        for frame in rig.farEngine.stores.custody.liveFrames(now: StillClock.wall) {
            engine.receive(InboundFrame(wire: frame.reserved, envelope: frame.envelope, from: rig.far.nodeId))
        }
        pump()
        pump()
    }

    /// Carries what the third and the far engine sent to the others, and what the node wrote to both. The far engine's
    /// relay of the third's frames is not captured, so the third's go to the node as if relayed.
    func pump() {
        for wire in transport.take() {
            guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
                continue
            }
            rig.farEngine.receive(InboundFrame(wire: wire, envelope: envelope, from: keys.nodeId))
            rig.radio.emit(.received(PeerRig.channel, record(.frame, wire.encoded)))
        }
        for wire in rig.farTransport.take() {
            guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
                continue
            }
            rig.radio.emit(.received(PeerRig.channel, record(.frame, wire.encoded)))
            engine.receive(InboundFrame(wire: wire, envelope: envelope, from: rig.far.nodeId))
        }
        let written = rig.radio.frames(on: PeerRig.channel)
        for wire in written.dropFirst(handed) {
            guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
                continue
            }
            rig.farEngine.receive(InboundFrame(wire: wire, envelope: envelope, from: rig.keys.nodeId))
            engine.receive(InboundFrame(wire: wire, envelope: envelope, from: rig.far.nodeId))
        }
        handed = written.count
    }
}

/// Waits, yielding, until `condition` holds, for at most five seconds, as ``LineCollector`` waits for a line.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}
