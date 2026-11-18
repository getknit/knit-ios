import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's kept frame (ADR 2026-11.xfcq): a file beside `profile.json`, the wire's own envelope around the two byte
/// strings, read back by a later run; and the engine over it, whose custody is in memory, so every restart finds the kept
/// frame and no row, and serves the first bytes rather than signing the stamp again.
@Suite struct FileOwnProfileFrameTests {
    private let frame = WireEnvelope(sig: [0x00] + fixtureBytes(63, seed: 1), signed: [0x00, 0xFF] + fixtureBytes(400, seed: 2))

    @Test func theKeptFrameOutlivesTheStoreAndIsForgotten() throws {
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        #expect(state.profileStore().keptFrame() == .absent, "no file is none kept")
        #expect(state.profileStore().keep(WireEnvelope(ttl: 2, hops: 3, relay: false, sig: frame.sig, signed: frame.signed)))
        #expect(state.profileStore().keptFrame() == .kept(frame), "a later run reads the two byte strings back, flooded")
        let attributes = try FileManager.default.attributesOfItem(atPath: state.directory + "/profile-frame")
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let store = state.profileStore()
        #expect(store.keep(nil) && store.keptFrame() == .absent)
        #expect(state.profileStore().keptFrame() == .absent, "and the file is gone")
        #expect(store.keep(nil), "forgetting nothing is no failure")
    }

    @Test func aFileThatDoesNotDecodeIsNoneKeptAndOneThatCannotBeReadIsUnreadable() throws {
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        try FileManager.default.createDirectory(atPath: state.directory, withIntermediateDirectories: true)
        let path = state.directory + "/profile-frame"
        try Data([0xFF, 0x00]).write(to: URL(fileURLWithPath: path))
        #expect(state.profileStore().keptFrame() == .absent)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let store = state.profileStore()
        #expect(store.keptFrame() == .unreadable, "a directory where the file should be")
        #expect(!store.keep(frame), "a write that failed")
        #expect(store.lastError?.hasPrefix("cannot write \(path)") == true)
        #expect(store.keptFrame() == .unreadable, "holds nothing new")
        // A unit undone over a frame it could not read leaves whatever the unit kept: there is nothing to put back.
        let undone = MemoryTransactor(stores: [store]).atomically { () -> Int? in
            try? FileManager.default.removeItem(atPath: path)
            store.keep(frame)
            return nil
        }
        #expect(undone == .abandoned && store.keptFrame() == .kept(frame))
    }

    @Test func aFrameUnreadableAtTheStartIsReadAgainOnceItReads() throws {
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        let path = state.directory + "/profile-frame"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let store = state.profileStore()
        #expect(store.lastError == "cannot read \(path)", "the path, never the bytes")
        #expect(store.keptFrame() == .unreadable)
        try FileManager.default.removeItem(atPath: path)
        try Data(frame.encoded).write(to: URL(fileURLWithPath: path))
        #expect(store.keptFrame() == .kept(frame), "read again while it was unreadable")
        try FileManager.default.removeItem(atPath: path)
        #expect(store.keptFrame() == .kept(frame), "a frame read is held, not read at every call")
    }

    @Test func aStoreWithNoFileKeepsTheFrameInMemory() {
        let store = FileOwnProfileStore(path: temporaryStateDirectory() + "/profile.json")
        #expect(store.keep(frame) && store.keptFrame() == .kept(frame))
    }

    @Test func theForgingStorePassesTheKeptFrameThrough() {
        let inner = MemoryOwnProfileStore()
        let store = ForgingOwnProfileStore(wrapping: inner)
        #expect(store.keep(frame) && inner.keptFrame() == .kept(frame) && store.keptFrame() == .kept(frame))
        #expect(store.keep(nil) && inner.keptFrame() == .absent)
    }

    @Test func aUnitUndoneRestoresTheKeptFrameFile() {
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        let store = state.profileStore()
        store.keep(frame)
        let unit = MemoryTransactor(stores: [store])
        let undone = unit.atomically { () -> Int? in
            store.keep(WireEnvelope(sig: [1], signed: [2]))
            return nil
        }
        #expect(undone == .abandoned && state.profileStore().keptFrame() == .kept(frame))
        let forgotten = unit.atomically { () -> Int? in
            store.keep(nil)
            return nil
        }
        #expect(forgotten == .abandoned && state.profileStore().keptFrame() == .kept(frame))
        store.keep(nil)
        let kept = unit.atomically { () -> Int? in
            store.keep(frame)
            return nil
        }
        #expect(kept == .abandoned && state.profileStore().keptFrame() == .absent)
    }

    /// A knit-peer restart: custody starts empty, so the start's seed finds only the kept frame, and puts its bytes back.
    @Test func aRestartedPeerServesTheKeptBytesItsFreshCustodyLacks() throws {
        let state = PeerState(directory: temporaryStateDirectory())
        defer { try? FileManager.default.removeItem(atPath: state.directory) }
        let keys = identity(1)
        func started(deviceTag: String) -> MeshEngine {
            let engine = MeshEngine(
                identity: keys,
                deviceTag: deviceTag,
                stores: .inMemory(ownProfileStore: state.profileStore()),
                transport: CapturingTransport(peer: identity(2).nodeId),
                clock: StillClock(),
                random: CountingGenerator()
            )
            engine.start()
            return engine
        }
        let first = started(deviceTag: "0011223344556677")
        let id = FrameId.profileId(sender: keys.nodeId.string, publishedAt: state.profileStore().load().publishedAt)
        let row = try #require(first.stores.custody.frame(id, now: StillClock().wallMilliseconds()))
        let again = started(deviceTag: "8899aabbccddeeff")
        let held = try #require(again.stores.custody.frame(id, now: StillClock().wallMilliseconds()))
        #expect(held.sig == row.sig && held.signed == row.signed, "the first run's bytes, not a second signing")
    }
}
