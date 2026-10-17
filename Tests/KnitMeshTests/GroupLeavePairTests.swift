import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A lost departure recovered, read by the leaver (ADR 2026-10.5sk9, phase P7a; both reviews' trial): an iPhone author over
/// SQL with the switch on, and Alice and Carol as Android members with their own session layers (``GroupFormReader``).
/// Carol's leave reaches the author, whose departure unit fails; the author restarts and sends. Carol, who read the group
/// before, opens nothing it sends after the restart, and its outbox holds no row for her.
@Suite struct GroupLeavePairTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    @Test func aLeaverWhoseDepartureWasLostReadsNothingSentAfterTheRestart() throws {
        let directory = scratchDirectory("leave-pair")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let author = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, seed: 81)
        let aliceReader = GroupFormReader(try AndroidPeer(alice))
        let carolReader = GroupFormReader(try AndroidPeer(carol))
        try author.pin(aliceReader.android)
        try author.pin(carolReader.android)
        let group = author.holdGroup(with: [alice, carol])
        _ = try #require(author.engine.sendGroupMessage("before", to: group.id))
        for seed in author.chats(to: carol) {
            try carolReader.receive(seed, from: me)
        }
        let before = try #require(author.groupFrames(in: group.id).last)
        #expect(carolReader.body(of: before, from: me) == "before", "Carol read the group while in it")
        refusing.refusesSaves = true
        author.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        refusing.refusesSaves = false
        #expect(author.engine.dropped[.storeRefused] == 1)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 82)
        _ = try #require(restarted.engine.sendGroupMessage("after", to: group.id))
        #expect(stores.groupRatchet.keySend(group.id, member: carol.nodeId) == nil, "no outbox row for Carol")
        #expect(restarted.chats(to: carol).isEmpty, "no seed to Carol")
        for chat in restarted.chats(to: carol) {
            try carolReader.receive(chat, from: me)
        }
        let after = try #require(restarted.groupFrames(in: group.id).last)
        #expect(try EngineFixture.sealed(after).keys.isEmpty, "the group form, with no v1 wrap for anyone")
        #expect(carolReader.body(of: after, from: me) == nil, "Carol opens nothing sent after the restart")
        for chat in restarted.chats(to: alice) {
            try aliceReader.receive(chat, from: me)
        }
        #expect(aliceReader.body(of: after, from: me) == "after", "Alice does")
    }
}
