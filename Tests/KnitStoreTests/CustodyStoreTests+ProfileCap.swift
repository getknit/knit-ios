import KnitStoreSQL
import KnitWire
import Testing

@testable import KnitStore

/// What the sweep deletes for the profile cap (ADR 2026-10.r88m), part of ``CustodyStoreTests`` and run against every store.
/// Here rather than beside the rest only for the file's length.
extension CustodyStoreTests {
    /// A frame of `type` padded with a chat body to exactly `signedBytes` of `signed`, the body's length searched upward, since
    /// CBOR's length prefixes grow at 24, 256 and 65,536. A profile names no recipient; custody never decodes the payload.
    private static func padded(_ id: String, to signedBytes: Int, type: FrameType, sentAt: Int64) throws -> CarriedFrame {
        var envelope = RelayEnvelope(
            type: type, id: id, senderId: "peer", sentAt: sentAt, recipientId: type == .profile ? nil : "bob", payload: [])
        for length in 0...signedBytes {
            envelope.payload = ChatContent(body: String(repeating: "x", count: length)).encoded
            if envelope.encoded.count >= signedBytes {
                break
            }
        }
        try #require(envelope.encoded.count == signedBytes, "no body length makes \(signedBytes) signed bytes")
        return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    @Test(arguments: CustodyStoreKind.allCases)
    func theSweepDeletesAProfileOverTheProfileCapAndKeepsOneAtIt(kind: CustodyStoreKind) throws {
        // A build without the profile cap stored all three; the build with it reopens the store under the production
        // limits and sweeps. The SQL store's `type` is a BLOB, so this proves its delete matches the profile's bytes.
        let cap = CustodyLimits().maxProfileSignedBytes
        let loose = CustodyLimits(maxProfileSignedBytes: 1_000_000)
        let old: any CustodyStore
        let reopen: () -> any CustodyStore
        switch kind {
        case .memory:
            let memory = MemoryCustodyStore(limits: loose)
            old = memory
            reopen = {
                memory.limits = CustodyLimits()
                return memory
            }
        case .sql:
            let database = try KnitDatabase.inMemory(failures: recordFailure)
            old = SQLCustodyStore(database, limits: loose)
            reopen = { SQLCustodyStore(database, limits: CustodyLimits()) }
        }
        let over = try Self.padded("over", to: cap + 1, type: .profile, sentAt: 5)
        let atCap = try Self.padded("at", to: cap, type: .profile, sentAt: 6)
        let chat = try Self.padded("chat", to: cap + 1, type: .chat, sentAt: 7)
        for frame in [over, atCap, chat] {
            #expect(old.store(frame, origin: .relayed, now: 10).held)
        }
        let store = reopen()
        #expect(store.contains("over"), "no live read applies the cap: until the sweep the row is held")

        #expect(store.sweepExpired(now: 10) == 1, "the sweep counts the profile it deleted")
        #expect(!store.contains("over"))
        #expect(Set(store.liveIndex(now: 10).map(\.id)) == ["at", "chat"])
        #expect(Set(store.liveIds(now: 10)) == ["at", "chat"])
        #expect(store.frame("at", now: 10) == atCap)
        #expect(store.sweepExpired(now: 10) == 0, "once the old rows are gone it finds nothing")
    }
}
