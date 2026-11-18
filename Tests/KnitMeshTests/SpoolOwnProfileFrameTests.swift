import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our profile in a DM scope across a restart that finds its custody row evicted (ADR 2026-11.xfcq, knit-next ADR
/// 2026-09.y5f3): the kept bytes go back, so the scope holds one blob for the profile's id, not one for each signing. The
/// restart moves the device tag, so a second signing would seal to a second blob on Linux too.
@Suite struct SpoolOwnProfileFrameTests {
    private let alice = SpoolEngineLabTests.alice
    private let bob = SpoolEngineLabTests.bob

    /// Alice (0, her prekeys in `keychain`) and Bob (1), greeted over radio until their session confirmed, then apart and
    /// both on the spool, their scope settled.
    private func online(keychain: KeptSecretStore) throws -> (SpoolLab, SpoolScope) {
        let fixtures = [
            try EngineFixture.ratcheting(alice, keychain: keychain, seed: 11), try EngineFixture.ratcheting(bob, seed: 12),
        ]
        let lab = SpoolLab(fixtures)
        lab.radio.link(0, 1)
        try SpoolEngineLabTests.send(lab, 0, 1, "hello")
        try SpoolEngineLabTests.send(lab, 1, 0, "hi")
        lab.advance(SpoolEngineLabTests.minute)
        try SpoolEngineLabTests.send(lab, 0, 1, "again")
        try SpoolEngineLabTests.send(lab, 1, 0, "and again")
        lab.advance(SpoolEngineLabTests.minute)
        lab.radio.unlink(0, 1)
        SpoolEngineLabTests.online(lab, [0, 1])
        return (lab, try #require(lab.scopes(0).first))
    }

    /// The blobs the spool holds in `scope` under `id`.
    private func blobs(_ lab: SpoolLab, _ scope: SpoolScope, of id: String) -> [(sig: [UInt8], envelope: RelayEnvelope)] {
        lab.opened(scope).filter { ExactKey($0.envelope.id) == ExactKey(id) }
    }

    /// Alice starts again over her stores, her custody row evicted, with another device tag, and goes online.
    private func restartEvicted(_ lab: SpoolLab, keychain: KeptSecretStore) throws {
        let stores = lab[0].stores
        stores.custody.remove(lab[0].ownProfileId)
        lab.replace(
            0,
            with: try EngineFixture.ratcheting(
                alice,
                stores: stores,
                keychain: keychain,
                wall: lab[0].clock.wallMilliseconds(),
                seed: 13,
                deviceTag: MeshEngineOwnProfileFrameTests.laterTag
            )
        )
        lab.connect(0)
        lab.run(6)
    }

    /// Test 8. After the restart, the pair's scope holds one blob for Alice's profile, the first bytes.
    @Test func aRestartAfterAnEvictionLeavesOneBlobForTheProfileInTheScope() throws {
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let (lab, scope) = try online(keychain: keychain)
        let id = lab[0].ownProfileId
        let first = try #require(lab[0].ownRow)
        #expect(blobs(lab, scope, of: id).count == 1, "the profile rides the scope")

        try restartEvicted(lab, keychain: keychain)
        #expect(lab[0].ownProfileId == id, "the same stamp")
        let held = blobs(lab, scope, of: id)
        #expect(held.count == 1, "one blob for the profile's id")
        let firstEnvelope = try RelayEnvelope(decoding: first.signed)
        #expect(held.first.map { $0.sig == first.sig && $0.envelope.encoded == firstEnvelope.encoded } == true, "the first bytes")
        #expect(lab[0].ownRow?.sameBytes(as: first) == true)
        #expect(lab.pairIds(0, with: 1) == lab.pairIds(1, with: 0), "both custodies hold the pair's same live ids")
        for node in [0, 1] {
            #expect(lab.heal(node)?.localFold(scope.id) == lab.spoolDigest(scope.id), "node \(node)'s fold is the spool's digest")
        }
    }

    /// Two blobs for the profile's id left in the scope from before the fix, the first bytes and a second signing's: after
    /// the restart and one listing, the second is pulled and accounted on each side, and both folds are the spool's digest.
    @Test func twoBlobsLeftFromBeforeTheFixAreAccountedAndTheFoldsAgree() throws {
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let (lab, scope) = try online(keychain: keychain)
        let id = lab[0].ownProfileId
        let first = try #require(lab[0].ownRow)
        var content = try ProfileContent(decoding: try RelayEnvelope(decoding: first.signed).payload)
        content.deviceTag = "deadbeefdeadbeef"
        let envelope = try RelayEnvelope(decoding: first.signed)
        let resigned = try alice.signed(
            RelayEnvelope(type: .profile, id: id, senderId: envelope.senderId, sentAt: envelope.sentAt, payload: content.encoded))
        let second = try #require(ScopeFrames.seal(ScopeFixture.carried(resigned), into: scope))
        lab.spool.scopes[scope.id]?.live.append(FakeSpool.Held(id: second.id, data: second.blob, arrivedAt: lab.spool.now))
        #expect(blobs(lab, scope, of: id).count == 2, "one id, two blobs, as a build before the fix left them")

        lab.forgetSent(1)
        lab.spool.broadcastDigest(scope.id)
        lab.pump()
        try restartEvicted(lab, keychain: keychain)
        #expect(blobs(lab, scope, of: id).count == 2, "no third")
        #expect(lab.lists(0) >= 1 && lab.lists(1) >= 1)
        for node in [0, 1] {
            #expect(lab.heal(node)?.state(scope.id)?.accounted.contains(second.id) == true, "node \(node) accounted the second")
            #expect(lab.heal(node)?.localFold(scope.id) == lab.spoolDigest(scope.id), "node \(node)'s fold is the spool's digest")
            #expect(lab[node].stores.custody.frame(id, now: lab[node].clock.wallMilliseconds())?.reserved.sameBytes(as: first) == true)
        }
    }
}
