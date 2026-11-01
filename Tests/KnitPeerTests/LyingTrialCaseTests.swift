import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The door-cap trial's cases, as far as two ends on hand-moved links reach (`door-cap-lying-peers` contract, cases 1, 2,
/// 3 and 5; ADR 2026-10.r88m): a liar built as `knit-peer run --lying` builds it and driven by its control lines, linked
/// to an honest receiver's ``Mesh``, both link managers in the path. Peer B, the photo's honest owner, is never linked:
/// its profile reaches the receiver over the liar's link, so the want is photo-only, and that B then brings the photo is
/// the engine's (`MeshEngineAvatarCeilingTests`) and the trial's to show.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LyingTrialCaseTests {
    private let photo = fixtureBytes(30_000, seed: 41)
    private var hash: BlobHash { BlobHash(of: photo) }

    /// Three re-wants: the receiver never queries or asks the liar for the photo again.
    private func expectNeverAskedAgain(_ rig: LyingTrialRig, sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = rig.receiverAsks(for: hash)
        for _ in 0..<3 {
            await rig.rewant()
        }
        let after = rig.receiverAsks(for: hash)
        #expect(
            after.queries == before.queries && after.asks == before.asks, "before \(before), after \(after)", sourceLocation: sourceLocation
        )
        #expect(await rig.receiver.blobs.photosOverCeiling == 1, "passed over once", sourceLocation: sourceLocation)
        #expect(await rig.receiver.neighbors.map(\.nodeId) == [rig.keys.nodeId], "the link stays up", sourceLocation: sourceLocation)
        #expect(rig.receiverRadio.closed.isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: Case 1

    @Test func aLyingSizePassesTheLiarOverOnceAndItIsNeverAskedAgain() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        try await rig.link()
        let set = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(hash.string)","size":\#(LyingTrialRig.overCeiling)}"#)
        #expect(set["ok"] as? Bool == true)

        await rig.carry(try LyingTrialRig.profile(naming: photo))
        #expect(await rig.exchange { await rig.receiver.blobs.photosOverCeiling == 1 }, "the lie reached the receiver")
        #expect(rig.receiverAsks(for: hash).queries >= 1 && rig.receiverAsks(for: hash).asks == 0, "queried, never asked")
        #expect(rig.parts?.radio.counts.blobhasRewritten ?? 0 >= 1)
        await expectNeverAskedAgain(rig)
        let counts = try #require(try await rig.lying()["counts"] as? [String: Any])
        #expect(counts["blobhasRewritten"] as? Int ?? 0 >= 1)
        await rig.receiver.stop()
        await rig.node.stop()
    }

    // MARK: Case 2

    /// The liar's serve of the junk, as its link manager writes one through its radio (`LinkManager+Feeds`): the header
    /// with the junk's whole size, 16 KiB chunks read from the lying store, and the END. Written here, not by the feed,
    /// whose window would need hundreds of timer rounds to stream past 1 MiB; the receiver's ask that would set it off is
    /// held back from the liar, so its own feed never starts.
    private func serveJunk(_ rig: LyingTrialRig) throws {
        let parts = try #require(rig.parts)
        let channel = LyingTrialRig.liarChannel
        let header = FileHeader(kind: .attachment, key: hash.string, mime: LyingBlobStore.junkMime, size: LyingTrialRig.junkBytes)
        parts.radio.writeFileRecord(try #require(LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded), to: channel)
        var offset = 0
        while let chunk = parts.blobs.read(hash, offset: offset, count: 16_384), !chunk.isEmpty {
            parts.radio.writeFileRecord(try #require(LinkRecord(.fileChunk, payload: chunk).encoded), to: channel)
            offset += chunk.count
        }
        parts.radio.writeFileRecord(try #require(LinkRecord(.fileEnd).encoded), to: channel)
    }

    @Test(arguments: [nil, Int(LyingTrialRig.plausible)])
    func junkUnderTheHashIsCutOnItsChunksAndNothingIsStored(declare: Int?) async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        try await rig.link()
        _ = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(hash.string)","size":\#(LyingTrialRig.plausible)}"#)
        let declared = declare.map { #","declare":\#($0)"# } ?? ""
        let junk = try await rig.send(#"{"cmd":"junk","hash":"\#(hash.string)","bytes":\#(LyingTrialRig.junkBytes)\#(declared)}"#)
        #expect(junk["ok"] as? Bool == true)
        rig.drop(.blobRequest)

        await rig.carry(try LyingTrialRig.profile(naming: photo))
        #expect(await rig.exchange { rig.receiverAsks(for: hash).asks >= 1 }, "a plausible size, so the receiver asks the liar")
        #expect(await rig.receiver.blobs.photosOverCeiling == 0)
        await rig.settle()
        try serveJunk(rig)
        let header = try #require(rig.liarRecords.last { $0.tag == .fileHeader }.flatMap { LinkJSON.fileHeader(from: $0.payload) })
        #expect(header.size == declare && header.offset == nil, "the header declares what was set")
        #expect(await rig.exchange { await rig.receiver.blobs.photosOverCeiling == 1 }, "cut once past the ceiling")
        #expect(!rig.receiverStores.blobs.contains(hash), "nothing stored")
        #expect(rig.parts?.radio.counts.junkHeadersRewritten == 1)
        #expect((rig.parts?.blobs.junkBytesServed ?? 0) == Int64(LyingTrialRig.junkBytes))
        await expectNeverAskedAgain(rig)
        await rig.receiver.stop()
        await rig.node.stop()
    }

    // MARK: Case 3

    @Test func aFakeAdvertiserNeverPushesThePhotoAndIsPassedOverLikeAnyHolder() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        // The liar holds the photo's bytes too, which only the withholding keeps off the link.
        rig.stores.blobs.insert(photo, hash: hash, mime: "image/jpeg", storedAt: StillClock.wall)
        rig.liarClock.advance(by: 1000)
        #expect(try await rig.send(#"{"cmd":"advertise-photo","hash":"\#(hash.string)"}"#)["ok"] as? Bool == true)
        _ = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(hash.string)","size":\#(LyingTrialRig.overCeiling)}"#)
        try await rig.link()
        #expect(await rig.exchange { rig.receiverStores.peers.peer(rig.keys.nodeId)?.advertisedAvatarHash == hash }, "the lie is pinned")

        var passedOver = false
        for _ in 0..<4 where !passedOver {
            await rig.rewant()
            passedOver = await rig.receiver.blobs.photosOverCeiling == 1
        }
        #expect(passedOver, "the author's oversize claim passes it over, refusing nothing outright")
        let avatars = rig.liarRecords.filter { $0.tag == .fileHeader }.compactMap { LinkJSON.fileHeader(from: $0.payload) }
            .filter { $0.kind == .avatar && $0.key == hash.string }
        #expect(avatars.isEmpty, "no AVATAR push of the advertised photo")
        #expect(rig.parts?.radio.counts.advertisedPhotoPushed == 0)
        #expect(!rig.receiverStores.blobs.contains(hash))
        await expectNeverAskedAgain(rig)
        await rig.receiver.stop()
        await rig.node.stop()
    }

    // MARK: Case 5

    /// After case 1's pass-over the liar asks the receiver for the photo itself. The want keeps its 1 MiB ceiling and the
    /// liar is never asked again, as Android's `mergeCeiling` keeps it: a neighbour's ask moves no ceiling of ours
    /// (`ios-photo-ask-ceiling`, `c8e9f60`). At `54ba068` the ask cleared the want's photo-only flag, and this rig saw the
    /// receiver query the liar five more times and ask it three times across three re-wants.
    @Test func aPassedOverLiarsOwnAskKeepsTheCeiling() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        try await rig.link()
        _ = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(hash.string)","size":\#(LyingTrialRig.overCeiling)}"#)
        await rig.carry(try LyingTrialRig.profile(naming: photo))
        #expect(await rig.exchange { await rig.receiver.blobs.photosOverCeiling == 1 })
        await rig.settle()

        let unknown = try await rig.send(#"{"cmd":"ask-blob","hash":"\#(hash.string)","peer":"\#(identity(9).nodeId.string)"}"#)
        #expect(unknown["sent"] as? Bool == false)
        let ask = try await rig.send(#"{"cmd":"ask-blob","hash":"\#(hash.string)","peer":"\#(rig.receiverKeys.nodeId.string)"}"#)
        #expect(ask["ok"] as? Bool == true && ask["sent"] as? Bool == true)
        let id = try #require(ask["id"] as? String)
        let asks = rig.liarFrames.filter { $0.envelope.id == id }
        let sent = try #require(asks.count == 1 ? asks.first : nil)
        #expect(sent.envelope.type == .blobRequest && !sent.wire.relay && sent.wire.sig.isEmpty)
        #expect(try BlobRequestContent(decoding: sent.envelope.payload) == BlobRequestContent(hash: hash.string, pull: 3))
        let lying = try await rig.lying()
        #expect((lying["counts"] as? [String: Any])?["blobAsksSent"] as? [String: Int] == [rig.receiverKeys.nodeId.string: 1])
        await rig.settle()

        let before = rig.receiverAsks(for: hash)
        for _ in 0..<3 {
            await rig.rewant()
        }
        let after = rig.receiverAsks(for: hash)
        #expect(after.queries == before.queries && after.asks == before.asks, "before \(before), after \(after)")
        #expect(await rig.receiver.blobs.photosOverCeiling == 1)
        #expect(await rig.receiver.neighbors.map(\.nodeId) == [rig.keys.nodeId], "the link stays up")
        await rig.receiver.stop()
        await rig.node.stop()
    }

    // MARK: The forge on a live link

    @Test func thePaddedProfileGoesOnceOnTheLiveLinkAndAgainOnANewOne() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        try await rig.link()
        rig.liarClock.advance(by: 1000)
        let pad = try await rig.send(#"{"cmd":"pad-profile","signedBytes":8192}"#)
        #expect(pad["written"] as? Int == 1)
        let id = try #require(pad["id"] as? String)
        #expect(rig.liarFrames.filter { $0.envelope.id == id }.map(\.wire.signed.count) == [8192])
        await rig.settle()
        #expect(rig.liarFrames.filter { $0.envelope.id == id }.count == 1, "once per channel")
        #expect(await rig.receiver.profileOversizeRefused == 0, "at the cap, taken")

        // The link comes back on a new channel: the forge goes again, after our HELLO and our PROOF, once the receiver's
        // proof verified.
        rig.inner.emit(.closed(LyingTrialRig.liarChannel))
        let next = ChannelID(17)
        try await dialProving(as: rig.receiverKeys, on: next, deliver: { rig.inner.emit($0) }, written: { rig.inner.records(on: next) })
        #expect(await waitUntil { rig.inner.records(on: next).count >= 3 })
        let records = rig.inner.records(on: next)
        #expect(records.prefix(2).map(\.tag) == [.hello, .proof])
        let forged = records.dropFirst(2).first.flatMap { try? WireEnvelope(decoding: $0.payload) }
        #expect(forged.flatMap { try? RelayEnvelope(decoding: $0.signed) }?.id == id, "the forge next")
        let first = rig.liarFrames.first { $0.envelope.id == id }?.wire
        #expect(forged != nil && forged == first, "signed once: the same bytes on every channel")
        #expect(rig.parts?.radio.counts.forgedProfilesWritten == [rig.receiverKeys.nodeId: 2])
        rig.liarClock.advance(by: 1000)
        _ = try await rig.send(#"{"cmd":"pad-profile","clear":true}"#)
        await rig.node.stop()
        await rig.receiver.stop()
    }
}
