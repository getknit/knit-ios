import Foundation
import KnitCrypto
import KnitPeer
import KnitTestSupport
import KnitWire
import Testing

/// The inits a peer answered, kept in its `identity` file beside its prekeys (ADR 2026-10.wcex), as the iPhone keeps them in
/// its Keychain item: the file grows by a fourth key that loading the identity and the prekeys reads past, a write the file
/// refuses or another identity in it changes nothing, and what is kept is pruned past its window. A restart with empty
/// stores, knit-peer's stand-in for a reinstall, reads them back.
@Suite struct PeerAnsweredInitsTests {
    private let start: Int64 = 1_756_200_000_000

    private func temporaryDirectory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("knit-peer-\(UInt64.random(in: 0...UInt64.max))").path
    }

    private func eph(_ seed: Int) -> [UInt8] {
        fixtureBytes(32, seed: 40 + seed)
    }

    @Test func theAnsweredInitsLiveBesideTheIdentityAndThePrekeysAndARestartReadsThemBack() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        let keys = try state.loadIdentity().keys
        var ring = try state.loadPrekeys(for: keys)
        try ring.rotate(now: start)
        let carol = identity(7).nodeId
        #expect(try ring.keepAnswered(eph(1), from: carol, now: start + 1))

        let again = PeerState(directory: directory)
        let loaded = try again.loadIdentity()
        #expect(loaded.origin == .stored && loaded.keys.nodeId == keys.nodeId, "an older build's load reads the grown file")
        let reloaded = try again.loadPrekeys(for: keys)
        #expect(reloaded.newest?.id == 1)
        #expect(reloaded.answered(eph(1), by: carol, now: start + 2))
        let mode = try FileManager.default.attributesOfItem(atPath: directory + "/identity")[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aRefusedWriteOrAnotherIdentityLeavesTheFileAndTheRingAsTheyWere() throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let state = PeerState(directory: directory)
        let keys = try state.loadIdentity().keys
        var ring = try state.loadPrekeys(for: keys)
        try ring.keepAnswered(eph(1), from: identity(7).nodeId, now: start)
        let kept = ring.answeredInits
        let file = try #require(FileManager.default.contents(atPath: directory + "/identity"))

        // The atomic write makes its temporary file in the directory, which now refuses it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        #expect(throws: PrekeyRing.Failure.self) {
            try ring.keepAnswered(eph(2), from: identity(7).nodeId, now: start + 1)
        }
        #expect(ring.answeredInits == kept)
        #expect(FileManager.default.contents(atPath: directory + "/identity") == file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

        try state.replaceIdentity(with: identity(5))
        #expect(throws: PrekeyRing.Failure.identityReplaced) {
            try ring.keepAnswered(eph(2), from: identity(7).nodeId, now: start + 1)
        }
        #expect(ring.answeredInits == kept)
        #expect(try state.loadIdentity().keys.nodeId == identity(5).nodeId)
    }

    @Test func whatIsKeptIsPrunedPastItsWindow() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        let keys = try state.loadIdentity().keys
        var ring = try state.loadPrekeys(for: keys)
        let carol = identity(7).nodeId
        try ring.keepAnswered(eph(1), from: carol, now: start)
        try ring.keepAnswered(eph(2), from: carol, now: start + PrekeyRing.answeredMilliseconds)
        let reloaded = try state.loadPrekeys(for: keys)
        #expect(reloaded.answeredInits.map(\.eph) == [eph(2)])
    }
}
