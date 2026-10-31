import KnitStoreSQL
import KnitWire
import Testing

@testable import KnitStore

/// Custody's byte cap (knit-next #227, `ForwardRepositoryTest`'s byte-cap cases), run against every store: a frame whose
/// `signed` is longer than ``CustodyLimits/maxSignedBytes`` is refused before any write, and the sweep deletes one a build
/// without the cap stored.
@Suite struct CustodyByteCapTests {
    private static let kinds = CustodyStoreKind.allCases

    /// The rig's cap, the shared vector's (`limits.maxSignedBytes`).
    private static let cap = 2048

    /// The rig's profile cap, the shared vector's (`limits.maxProfileSignedBytes`), under its byte cap.
    private static let profileCap = 1024

    /// A DM from `sender` padded with a chat body to exactly `signedBytes` of `signed`, the body's length searched upward,
    /// since CBOR's length prefixes grow at 24, 256 and 65,536 (`CustodyVectorTest.sized`). A profile, `type` says so,
    /// names no recipient; custody never decodes its payload, so the chat body pads it as well.
    private static func sized(
        _ id: String, _ signedBytes: Int, sender: String = "peer", sentAt: Int64 = 1, type: FrameType = .chat
    ) throws -> CarriedFrame {
        var envelope = RelayEnvelope(
            type: type, id: id, senderId: sender, sentAt: sentAt, recipientId: type == .profile ? nil : "bob", payload: [])
        for length in 0...signedBytes {
            envelope.payload = ChatContent(body: String(repeating: "x", count: length)).encoded
            if envelope.encoded.count >= signedBytes {
                break
            }
        }
        try #require(envelope.encoded.count == signedBytes, "no body length makes \(signedBytes) signed bytes")
        return CarriedFrame(envelope: envelope, sig: [UInt8](repeating: 1, count: 64), signed: envelope.encoded)
    }

    /// A store under `loose`, and a way to reopen what it holds under other limits: the memory store's limits set in place,
    /// or a second SQL store over the same database, as a newer build reopens the file an older one wrote.
    private static func reopenable(
        _ kind: CustodyStoreKind, _ loose: CustodyLimits
    ) throws -> (store: any CustodyStore, reopen: (CustodyLimits) -> any CustodyStore) {
        switch kind {
        case .memory:
            let store = MemoryCustodyStore(limits: loose)
            return (
                store,
                { limits in
                    store.limits = limits
                    return store
                }
            )
        case .sql:
            let database = try KnitDatabase.inMemory(failures: recordFailure)
            return (SQLCustodyStore(database, limits: loose), { SQLCustodyStore(database, limits: $0) })
        }
    }

    @Test(arguments: kinds)
    func exactlyTheCapIsKept(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxSignedBytes: Self.cap))
        let frame = try Self.sized("w1", Self.cap)
        #expect(store.store(frame, origin: .relayed, now: 1) == CustodyStoreResult(held: true, changed: true))
        #expect(store.frame("w1", now: 1) == frame)
    }

    @Test(arguments: kinds)
    func oneByteOverIsRefusedAndAFullStoreEvictsNothing(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3, maxSignedBytes: Self.cap))
        for index in 1...3 {
            store.store(try Self.sized("f\(index)", 100, sender: "s\(index)", sentAt: Int64(index)), origin: .relayed, now: 10)
        }
        let before = store.liveIds(now: 10)
        #expect(before.count == 3, "the store is at its cap")
        // Newer than everything held, so a frame it admitted would evict the oldest.
        let over = try Self.sized("w2", Self.cap + 1, sender: "walt", sentAt: 9)
        #expect(store.store(over, origin: .relayed, now: 10) == .refused(.oversize))
        #expect(store.store(over, origin: .own, now: 10) == .refused(.oversize), "our own frames are bound too")
        #expect(store.liveIds(now: 10) == before)
        #expect(!store.contains("w2"))
    }

    @Test(arguments: kinds)
    func theSweepDeletesARowOverTheCapAndKeepsOneAtIt(kind: CustodyStoreKind) throws {
        // A build without the cap stored both; the build with it reopens the store and sweeps.
        let (old, reopen) = try Self.reopenable(kind, CustodyLimits(maxSignedBytes: 1_000_000))
        let atCap = try Self.sized("at", Self.cap, sentAt: 5)
        let over = try Self.sized("over", Self.cap + 1, sentAt: 6)
        let small = try Self.sized("small", 200, sentAt: 7)
        for frame in [atCap, over, small] {
            #expect(old.store(frame, origin: .relayed, now: 10).held)
        }
        let store = reopen(CustodyLimits(maxSignedBytes: Self.cap))
        #expect(store.liveIds(now: 10).count == 3, "no live read applies the cap: until the sweep the row is held")

        #expect(store.sweepExpired(now: 10) == 1, "the sweep counts the row it deleted")
        #expect(!store.contains("over"))
        #expect(store.liveIds(now: 10) == ["at", "small"])
        #expect(Set(store.liveIndex(now: 10).map(\.id)) == ["at", "small"])
        #expect(Set(store.liveFrames(now: 10).map(\.envelope.id)) == ["at", "small"])
        #expect(store.sweepExpired(now: 10) == 0, "once the old rows are gone it finds nothing")
    }

    @Test(arguments: kinds)
    func aRowBothExpiredAndOverTheCapIsCountedOnce(kind: CustodyStoreKind) throws {
        let (old, reopen) = try Self.reopenable(kind, CustodyLimits(ttlMilliseconds: 100, maxSignedBytes: 1_000_000))
        old.store(try Self.sized("over", Self.cap + 1, sentAt: 5), origin: .relayed, now: 10)
        old.store(try Self.sized("stale", 200, sentAt: 6), origin: .relayed, now: 10)
        old.store(try Self.sized("live", 200, sentAt: 500), origin: .relayed, now: 500)
        let store = reopen(CustodyLimits(ttlMilliseconds: 100, maxSignedBytes: Self.cap))
        #expect(store.sweepExpired(now: 500) == 2)
        #expect(store.liveIds(now: 500) == ["live"])
        #expect(!store.contains("over") && !store.contains("stale"))
    }

    // MARK: The profile cap

    @Test(arguments: kinds)
    func aProfileAtTheProfileCapIsKeptAndAChatOverItToo(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxSignedBytes: Self.cap, maxProfileSignedBytes: Self.profileCap))
        let profile = try Self.sized("p1", Self.profileCap, type: .profile)
        let chat = try Self.sized("c1", Self.profileCap + 1)
        #expect(store.store(profile, origin: .relayed, now: 1) == CustodyStoreResult(held: true, changed: true))
        #expect(store.store(chat, origin: .relayed, now: 1) == CustodyStoreResult(held: true, changed: true))
        #expect(store.frame("p1", now: 1) == profile)
        #expect(store.frame("c1", now: 1) == chat)
    }

    @Test(arguments: kinds)
    func aProfileOneByteOverIsRefusedAndAFullStoreEvictsNothing(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3, maxSignedBytes: Self.cap, maxProfileSignedBytes: Self.profileCap))
        for index in 1...3 {
            store.store(try Self.sized("f\(index)", 100, sender: "s\(index)", sentAt: Int64(index)), origin: .relayed, now: 10)
        }
        let before = store.liveIds(now: 10)
        #expect(before.count == 3, "the store is at its cap")
        // Newer than everything held, so a profile it admitted would evict the oldest.
        let over = try Self.sized("p2", Self.profileCap + 1, sender: "walt", sentAt: 9, type: .profile)
        #expect(store.store(over, origin: .relayed, now: 10) == .refused(.profileOversize))
        #expect(store.store(over, origin: .own, now: 10) == .refused(.profileOversize), "our own profile is bound too")
        let both = try Self.sized("p3", Self.cap + 1, sender: "walt", sentAt: 9, type: .profile)
        #expect(store.store(both, origin: .relayed, now: 10) == .refused(.oversize), "over both caps is oversize")
        #expect(store.liveIds(now: 10) == before)
        #expect(!store.contains("p2") && !store.contains("p3"))
    }
}
