import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's profile switches when they cannot do what they say (`door-cap-lying-peers`, ADR 2026-10.r88m): a second
/// advertised photo releases the first; a marker that cannot be written refuses the switch before anything is set, and one
/// that cannot be rewritten or removed fails the clear loudly; and a marker whose forge is ahead of the clock leaves our
/// profile below it, which the start says rather than claiming an honest profile won.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ProfileLiesFailureTests {
    private let first = BlobHash(of: fixtureBytes(3000, seed: 41))
    private let second = BlobHash(of: fixtureBytes(3000, seed: 42))

    /// A marker no write or removal gets past: a directory where the file goes, holding a file in a directory no one may
    /// write. Answers the read-only directory, which the caller opens again before removing it.
    private func blockMarker(at path: String) throws -> String {
        try? FileManager.default.removeItem(atPath: path)
        let locked = path + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: locked + "/file", contents: Data([1])))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        return locked
    }

    private func unblock(_ locked: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
    }

    /// The marker's text for a forge at `clocks`.
    private func marker(forged clocks: Int64) -> Data {
        Data(#"{"forged":{"version":\#(clocks),"publishedAt":\#(clocks)}}"#.utf8)
    }

    @Test func aSecondAdvertisedPhotoReleasesTheFirst() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        rig.clock.advance(by: 1000)
        try await rig.lies.setAdvertisedPhoto(first)
        #expect(rig.blobs.withheld == [first])
        rig.clock.advance(by: 1000)
        try await rig.lies.setAdvertisedPhoto(second)
        #expect(rig.blobs.withheld == [second], "the first one's bytes are ours to serve again")
        #expect(await rig.lies.advertisedPhoto == second)
        try await rig.lies.setAdvertisedPhoto(second)
        #expect(rig.blobs.withheld == [second], "the same photo again keeps it back")
        await rig.mesh.stop()
    }

    @Test func aMarkerThatCannotBeWrittenRefusesTheSwitchBeforeAnythingIsSet() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        let file = rig.directory + "/not-a-directory"
        #expect(FileManager.default.createFile(atPath: file, contents: Data([1])))
        let lies = ProfileLies(
            mesh: rig.mesh,
            stores: rig.stores,
            profile: rig.forging,
            blobs: rig.blobs,
            identity: rig.keys,
            clock: rig.clock,
            stateDirectory: file + "/state"
        )
        let before = rig.forging.load()
        let error = await #expect(throws: ProfileLies.Failure.self) {
            try await lies.setAdvertisedPhoto(first)
        }
        guard case .marker(let why) = error else {
            Issue.record("a marker failure, not \(String(describing: error))")
            return
        }
        #expect(why.hasPrefix("cannot write \(file)/state/\(ProfileLies.markerName): "))
        #expect(error?.description == why)
        #expect(await lies.advertisedPhoto == nil && rig.blobs.withheld.isEmpty && rig.forging.load() == before, "nothing set")
        await rig.mesh.stop()
    }

    /// With the advertised photo still set, clearing the forge must rewrite the marker; with nothing left, the advertised
    /// photo's clear must remove it. Either one that cannot fails, after the honest edit went out.
    @Test func aMarkerThatCannotBeRewrittenOrRemovedFailsTheClear() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        rig.clock.advance(by: 1000)
        try await rig.lies.setAdvertisedPhoto(first)
        rig.clock.advance(by: 1000)
        let forged = try await rig.lies.pad(signedBytes: 4000)
        let locked = try blockMarker(at: rig.markerPath)
        defer { unblock(locked) }

        rig.clock.advance(by: 1000)
        let rewrite = await #expect(throws: ProfileLies.Failure.self) {
            try await rig.lies.clearPad()
        }
        guard case .marker(let why) = rewrite else {
            Issue.record("a marker failure, not \(String(describing: rewrite))")
            return
        }
        #expect(why.hasPrefix("cannot write \(rig.markerPath): "))
        #expect(await rig.lies.paddedProfile == nil && rig.forging.load().version > forged.version, "the edit went out first")

        rig.clock.advance(by: 1000)
        let remove = await #expect(throws: ProfileLies.Failure.self) {
            try await rig.lies.clearAdvertisedPhoto()
        }
        guard case .marker(let removing) = remove else {
            Issue.record("a marker failure, not \(String(describing: remove))")
            return
        }
        #expect(removing.hasPrefix("cannot remove \(rig.markerPath): "))
        #expect(await rig.lies.advertisedPhoto == nil && rig.blobs.withheld.isEmpty, "cleared all the same")
        await rig.mesh.stop()
    }

    /// The marker names a forge stamped far ahead of the clock: three honest edits cannot pass it, so the start throws,
    /// naming where our profile stopped, and leaves the marker for the next.
    @Test func aForgeAheadOfTheClockLeavesOurProfileBelowItAndSaysSo() async throws {
        let rig = try LyingProfileRig()
        defer { rig.remove() }
        try await rig.start()
        let ahead = rig.clock.wallMilliseconds() + 86_400_000
        #expect(FileManager.default.createFile(atPath: rig.markerPath, contents: marker(forged: ahead)))
        let error = await #expect(throws: ProfileLies.Failure.self) {
            try await ProfileLies.recoverAtStart(stateDirectory: rig.directory, mesh: rig.mesh, stores: rig.stores)
        }
        let own = rig.forging.load()
        let forge = ProfileLies.ForgedClocks(version: ahead, publishedAt: ahead)
        #expect(error == .honestEditsBelowForge(version: own.version, publishedAt: own.publishedAt, forged: forge))
        #expect(own.version < ahead, "below the forge")
        #expect(
            error?.description
                == "our profile stayed at version \(own.version), stamp \(own.publishedAt), not above the forged version \(ahead), "
                + "stamp \(ahead): the clock is behind the forge")
        #expect(FileManager.default.fileExists(atPath: rig.markerPath), "kept for the next start")
        await rig.mesh.stop()
    }
}
