import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// ``MeshEngineFlooredResetTests``' edges: which of two resets is held, and a re-open that verifies nothing, that the chat
/// door refuses, or whose backlog's row read fails.
extension MeshEngineFlooredResetTests {
    /// The re-open verifies the held frame again against the sender's pin, and drops one that no longer verifies.
    @Test func aHeldResetThatNoLongerVerifiesIsDropped() throws {
        let shape = try floored()
        let held = try #require(shape.fixture.engine.flooredResets.byPeer[alice.nodeId])
        var sig = held.wire.sig
        sig[0] ^= 1
        let forged = FlooredResets.Held(
            wire: WireEnvelope(sig: sig, signed: held.wire.signed),
            envelope: held.envelope,
            source: held.source,
            initEph: held.initEph,
            generation: held.generation,
            mayBeEvidence: held.mayBeEvidence
        )
        _ = shape.fixture.engine.flooredResets.hold(forged, for: alice.nodeId)
        clock(shape, at: 10 * Self.second + Self.minute)
        shape.fixture.engine.reopenFlooredResets()
        #expect(shape.fixture.engine.flooredCounts.flooredResetsReopened == 0)
        #expect(shape.fixture.ratchetRecords(of: alice).session?.root == shape.firstRoot)
        #expect(shape.fixture.log.all.contains { $0.contains("it no longer verifies against the pin") })
    }

    /// The backlog's exists-gate: a row read the store fails, inside the backlog's own unit, skips the frame.
    @Test func aBacklogWhoseRowReadFailsSkipsTheFrame() throws {
        let directory = scratchDirectory("floored-backlog-read-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let shape = try floored(stores: stores)
        _ = try followUps(shape)
        refusing.failsReads = true
        shape.fixture.engine.replayFlooredResetBacklog(of: alice.nodeId, initEph: shape.initEph, except: frameIdOf("reset-2"))
        refusing.failsReads = false
        #expect(
            shape.fixture.log.all.contains { line in
                line.contains("mesh floored reset backlog \(frameIdOf("under-second-1")) from \(alice.nodeId) skipped")
            })
    }

    /// A pin read the store fails puts the hold back for the next re-offer, never dropping it as a pin gone; the next
    /// re-offer, the store answering again, opens it.
    @Test func aPinReadThatFailsKeepsTheHoldForTheNextReOffer() throws {
        let directory = scratchDirectory("floored-pin-read-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingPeerReads(blobs: directory, failures: ReportedFailures().record)
        let shape = try floored(stores: stores)
        clock(shape, at: 10 * Self.second + Self.minute)
        refusing.failsReads = true
        shape.fixture.engine.reopenFlooredResets()
        refusing.failsReads = false
        #expect(shape.fixture.engine.flooredResets.byPeer[alice.nodeId] != nil, "the hold is back")
        #expect(shape.fixture.engine.flooredCounts == RatchetFlooredCounts(flooredResetsHeld: 1))
        #expect(shape.fixture.log.all.contains { $0.contains("for the next re-offer: a store failed") })
        shape.fixture.engine.reopenFlooredResets()
        #expect(shape.fixture.engine.flooredCounts.flooredResetsAdopted == 1)
    }

    /// The crypto review's C1: a reset held, then dropped by our own re-root, which Android answers, so we are the
    /// confirmed initiator of an era whose `establishedAt` is our clock. A restart forgets the drop, and Android's reset,
    /// stamped ahead of our re-root by its clock, waits in custody with a root we never held. Under an era we opened the
    /// start's replay never holds it, or the re-open would adopt a root Android has left.
    @Test func theStartsReplayHoldsNothingUnderAnEraWeOpened() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let shape = try floored(stores: stores, keychain: keychain)
        let (fixture, android) = (shape.fixture, shape.android)
        guard case .sent(_, reRooted: true) = fixture.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our re-root goes")
            return
        }
        let ours = try #require(fixture.resetsSent(to: alice).last)
        _ = try android.open(ours, from: me, now: now + 71 * Self.second)
        #expect(android.session(with: me)?.root == fixture.ratchetRecords(of: alice).session?.root, "Android took our re-root")
        fixture.deliver(
            try android.dm(
                "under yours", to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("under-yours"), sentAt: now + 72 * Self.second),
            from: android)
        let held = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(held.confirmed && held.weAreInitiator && held.establishedAt < now + 70 * Self.second, "our era, her reset stamped past it")

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 30 * Self.second, seed: 8)
        #expect(restarted.engine.flooredCounts.flooredResetsHeld == 0)
        restarted.engine.reopenFlooredResets()
        #expect(restarted.ratchetRecords(of: alice).session?.root == held.root, "still on our own root")
    }

    /// The security review's S1: a hold the start's replay took opens as non-evidence, since custody keeps a spool's frame
    /// without its source. A flagged reset whose body is spoiled floors, a restart holds it, and its re-open fails the AEAD
    /// once adopted: nothing is counted and no reset goes.
    @Test func aStartReplayHoldsReOpenIsNeverEvidence() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (fixture, android) = try confirmed(stores: stores, keychain: keychain)
        let prekey = try fixture.ourPrekey()
        fixture.clock.advance(10 * Self.second)
        fixture.deliver(try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-1"), at: now + 10 * Self.second), from: android)
        fixture.clock.advance(10 * Self.second)
        let reset = try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-2"), at: now + 70 * Self.second)
        var chat = try ChatContent(decoding: reset.envelope.payload)
        chat.enc?.ct[0] ^= 1
        var envelope = reset.envelope
        envelope.payload = chat.encoded
        fixture.deliver(try alice.signed(envelope), from: android)
        #expect(fixture.engine.dropped[.ratchetResetFloored] == 1)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 30 * Self.second, seed: 8)
        #expect(restarted.engine.flooredCounts.flooredResetsHeld == 1, "held at the start's replay")
        restarted.engine.reopenFlooredResets()
        #expect(restarted.engine.flooredCounts.flooredResetsReopened == 1)
        #expect(restarted.engine.dropped[.ratchetAeadFail] == 1, "opened, and failed")
        #expect(restarted.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0, "no evidence")
        #expect(restarted.resetsSent(to: alice).isEmpty)
    }
}
