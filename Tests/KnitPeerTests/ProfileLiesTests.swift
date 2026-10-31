import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's profile switches through a real ``Mesh``, its frames taken by an honest engine on the far end of the link
/// (`door-cap-lying-peers`, cases 3 and 4, ADR 2026-10.r88m): `advertise-photo` has the engine sign and publish a profile
/// naming another's photo, in the clear and sealed, and clearing it publishes our own above it; `pad-profile`'s forge is
/// refused a byte over the cap, pins at it, and is outranked by the clear's edit, even on a clock that has not moved; and a
/// lie left set when the peer stops is outranked at its next start, from the marker alone.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ProfileLiesTests {
    private let ownPhoto = fixtureBytes(2000, seed: 21)
    private let theirPhoto = BlobHash(of: fixtureBytes(3000, seed: 22))

    private func profileContent(_ frame: (wire: WireEnvelope, envelope: RelayEnvelope)) throws -> ProfileContent {
        try ProfileContent(decoding: frame.envelope.payload)
    }

    // MARK: advertise-photo

    @Test func advertisingAPhotoPublishesItAboveOursAndClearingPublishesOursAboveIt() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        await rig.mesh.setAvatar(ownPhoto)
        let real = BlobHash(of: ownPhoto)
        rig.deliverToFar()
        let before = rig.forging.load().version
        #expect(rig.farRow?.advertisedAvatarHash == real)

        rig.clock.advance(by: 1000)
        let sent = rig.written(.profile).count
        try await rig.lies.setAdvertisedPhoto(theirPhoto)
        let lie = try #require(rig.written(.profile).dropFirst(sent).last, "the edit went out")
        let lying = try profileContent(lie)
        #expect(lying.avatarHash == theirPhoto.string && (lying.version ?? 0) > before)
        #expect(rig.keys.bundle.isValidSignature(lie.wire.sig, for: lie.wire.signed), "signed by the engine with our key")
        #expect(FileManager.default.fileExists(atPath: rig.markerPath))
        #expect(PeerState(directory: rig.directory).profileStore().load().avatarHash == real, "the file keeps our own photo")
        #expect(rig.blobs.withheld == [theirPhoto])
        #expect(await rig.lies.advertisedPhoto == theirPhoto)
        rig.deliverToFar()
        #expect(rig.farRow?.advertisedAvatarHash == theirPhoto, "the far end takes the lie")

        rig.clock.advance(by: 1000)
        let lied = rig.written(.profile).count
        try await rig.lies.clearAdvertisedPhoto()
        let honest = try #require(rig.written(.profile).dropFirst(lied).last)
        let content = try profileContent(honest)
        #expect(content.avatarHash == real.string && (content.version ?? 0) > (lying.version ?? 0))
        #expect(!FileManager.default.fileExists(atPath: rig.markerPath) && rig.blobs.withheld.isEmpty)
        rig.deliverToFar()
        #expect(rig.farRow?.advertisedAvatarHash == real, "and our own above it")
        await rig.mesh.stop()
    }

    /// With the ratchet on, the sealed `CTL_PROFILE` to a confirmed session follows each edit, the advertised hash beside
    /// its seal, and the clear's sealed copy names our own again.
    @Test func withTheRatchetTheSealedProfileFollowsBothEdits() async throws {
        let rig = try LyingProfileRig(ratchet: true)
        defer { rig.remove() }
        try await rig.start()
        await rig.mesh.setAvatar(ownPhoto)
        let real = BlobHash(of: ownPhoto)
        rig.deliverToFar()
        #expect(rig.farRow?.prekey != nil, "the far end pinned our prekey")
        let dm = try #require(rig.farEngine.sendDirectMessage("hello", to: rig.keys.nodeId), "the far end opens a session")
        rig.deliverFromFar()
        #expect(await waitUntil { rig.stores.messages.message(dm.id) != nil }, "the liar took the far end's first DM")
        rig.deliverToFar()

        func sealedToFar(after count: Int) throws -> [ChatContent] {
            try rig.written(.chat).dropFirst(count).filter { $0.envelope.recipientId == rig.far.nodeId.string }.map { frame in
                try ChatContent(decoding: frame.envelope.payload)
            }.filter { $0.enc != nil && $0.body.isEmpty }
        }

        rig.clock.advance(by: 1000)
        var chats = rig.written(.chat).count
        try await rig.lies.setAdvertisedPhoto(theirPhoto)
        let lie = try sealedToFar(after: chats)
        // What the DM's arrival queued (our answer, and the sealed copy of the version the session confirmed after) can
        // reach the radio after the count, so only the edit's own sealed copy is counted.
        #expect(lie.filter { $0.attachmentHash == theirPhoto.string }.count == 1, "sealed beside the advertised hash")
        #expect(lie.last?.attachmentHash == theirPhoto.string)

        rig.clock.advance(by: 1000)
        chats = rig.written(.chat).count
        try await rig.lies.clearAdvertisedPhoto()
        let honest = try sealedToFar(after: chats)
        #expect(honest.count == 1 && honest.first?.attachmentHash == real.string, "the clear's sealed copy names our own")
        #expect(honest.allSatisfy { $0.attachmentHash != theirPhoto.string })
        rig.deliverToFar()
        #expect(rig.farRow?.advertisedAvatarHash == real)
        await rig.mesh.stop()
    }

    // MARK: pad-profile

    @Test func aForgeOverTheCapIsRefusedOneAtItPinsAndTheClearOutranksIt() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        let pinned = try #require(rig.farRow)
        let proof = rig.farEngine.stores.peers.profileFrame(of: rig.keys.nodeId)

        rig.clock.advance(by: 1000)
        let over = try await rig.lies.pad(signedBytes: 8193)
        #expect(over.wire.signed.count == 8193 && FileManager.default.fileExists(atPath: rig.markerPath))
        #expect(await rig.lies.paddedProfile == over)
        try rig.inject(over.wire)
        #expect(rig.farEngine.profileOversizeRefused == 1)
        #expect(rig.farRow == pinned && rig.farEngine.stores.peers.profileFrame(of: rig.keys.nodeId) == proof, "no new row or proof")
        #expect(!rig.farEngine.stores.custody.contains(over.id), "no custody row")

        await #expect(throws: ProfileLies.Failure.clockNotPastForge(now: over.publishedAt, forged: over.publishedAt)) {
            try await rig.lies.pad(signedBytes: 8192)
        }
        rig.clock.advance(by: 1)
        let atCap = try await rig.lies.pad(signedBytes: 8192)
        try rig.inject(atCap.wire)
        let lying = try #require(rig.farRow)
        #expect(lying.status.utf16.count == TextLimits.status && lying.updatedAt == atCap.version, "pinned, its status cut")
        #expect(rig.farEngine.stores.custody.contains(atCap.id) && rig.farEngine.profileOversizeRefused == 1)

        rig.clock.advance(by: 1000)
        try await rig.lies.clearPad()
        #expect(await rig.lies.paddedProfile == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.markerPath))
        rig.deliverToFar()
        let honest = try #require(rig.farRow)
        #expect(honest.status == "lying low" && honest.updatedAt > atCap.version, "the honest profile wins")
        try rig.inject(atCap.wire)
        #expect(rig.farRow == honest, "a re-serve of the forge is stale")
        await rig.mesh.stop()
    }

    /// On a clock that has not moved since the forge, the clear's first edit lands on the forge's own stamp, so a second
    /// runs, and the honest profile still outranks it.
    @Test func theClearOutranksTheForgeOnAClockThatHasNotMoved() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        rig.clock.advance(by: 1000)
        let forged = try await rig.lies.pad(signedBytes: 8192)
        try rig.inject(forged.wire)
        try await rig.lies.clearPad()
        let own = rig.forging.load()
        #expect(own.version > forged.version && own.publishedAt > forged.publishedAt)
        rig.deliverToFar()
        let row = try #require(rig.farRow)
        #expect(row.status == "lying low" && row.updatedAt == own.version)
        await rig.mesh.stop()
    }

    @Test func clearingWithNoForgeHeldStillEditsAndAForgeTheEngineCannotMakeIsRefused() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        let before = rig.forging.load()
        await #expect(throws: ProfileLies.Failure.forge(.versionNotBehindClock(version: before.version, now: before.version))) {
            try await rig.lies.pad(signedBytes: 8192)
        }
        rig.clock.advance(by: 1000)
        await #expect(throws: ProfileLies.Failure.forge(.unreachableLength(signedBytes: 10))) {
            try await rig.lies.pad(signedBytes: 10)
        }
        #expect(!FileManager.default.fileExists(atPath: rig.markerPath), "a refused forge leaves no marker")
        try await rig.lies.clearPad()
        #expect(rig.forging.load().version > before.version, "an honest edit all the same")
        await rig.mesh.stop()
    }

    // MARK: Restart

    enum Left: CaseIterable, Sendable {
        case advertised
        case padded
    }

    /// A lie left set when the peer stopped, and a fresh process on the same state directory, without `--lying`: the
    /// marker alone has the start publish an honest profile above it, and goes. The clock has not moved, so the marker's
    /// clocks are what lift the edit above a forge.
    @Test(arguments: Left.allCases)
    func aLieLeftSetIsOutrankedAtTheNextStart(left: Left) async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        await rig.mesh.setAvatar(ownPhoto)
        rig.clock.advance(by: 1000)
        let lie: (version: Int64, frame: WireEnvelope)
        switch left {
        case .advertised:
            try await rig.lies.setAdvertisedPhoto(theirPhoto)
            let frame = try #require(rig.written(.profile).last)
            lie = (try profileContent(frame).version ?? 0, frame.wire)
        case .padded:
            let forged = try await rig.lies.pad(signedBytes: 8192)
            lie = (forged.version, forged.wire)
        }
        try rig.inject(lie.frame)
        #expect(rig.farRow?.updatedAt == lie.version)
        await rig.mesh.stop()
        #expect(FileManager.default.fileExists(atPath: rig.markerPath))

        let state = PeerState(directory: rig.directory)
        let stores = MeshStores.inMemory(ownProfileStore: state.profileStore())
        let mesh = Mesh(
            identity: rig.keys, deviceTag: nil, stores: stores, radio: PeerRadio(), clock: rig.clock, random: CountingGenerator())
        await mesh.start()
        #expect(try await ProfileLies.recoverAtStart(stateDirectory: rig.directory, mesh: mesh, stores: stores))
        #expect(!FileManager.default.fileExists(atPath: rig.markerPath))
        #expect(try await !ProfileLies.recoverAtStart(stateDirectory: rig.directory, mesh: mesh, stores: stores), "once")

        let own = state.profileStore().load()
        #expect(own.version > lie.version && own.avatarHash == BlobHash(of: ownPhoto))
        let id = FrameId.profileId(sender: rig.keys.nodeId.string, publishedAt: own.publishedAt)
        let honest = try #require(stores.custody.frame(id, now: rig.clock.wallMilliseconds()), "signed and carried")
        try rig.inject(honest.reserved)
        let row = try #require(rig.farRow)
        #expect(row.updatedAt == own.version && row.advertisedAvatarHash == BlobHash(of: ownPhoto) && row.status == "lying low")
        await mesh.stop()
    }
}
