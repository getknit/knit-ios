import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// This device's prekeys beside its identity (`IdentityKeyStore`'s prekey half in knit-next): minted, rotated weekly,
/// five kept, written into the identity's own item without disturbing anything else there, and read back with their
/// signatures as minted (ADR 2026-10.5sk9).
@Suite struct PrekeyRingTests {
    private let start: Int64 = 1_756_200_000_000
    private let week = PrekeyRing.rotationMilliseconds

    private func keys(_ seed: Int) throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 1)))
    }

    /// A store holding `identity`, as `IdentityKeys.load` leaves it.
    private func store(holding identity: IdentityKeys) -> MemorySecretStore {
        MemorySecretStore(secret: identity.storedForm, refuses: false)
    }

    /// The stored item's entries.
    private func entries(_ bytes: [UInt8]?) throws -> [CBOR.Entry] {
        guard case .map(let entries) = try CBOR.decode(try #require(bytes)) else {
            Issue.record("the item is not a map")
            return []
        }
        return entries
    }

    /// `identity`'s item with `prekeys` and any `extra` entries beside it, written the way the ring writes it.
    private func item(_ identity: IdentityKeys, prekeys: [CBOR], extra: [CBOR.Entry] = []) throws -> [UInt8] {
        CBOR.map(try entries(identity.storedForm) + extra + [CBOR.Entry(key: .text("prekeys"), value: .array(prekeys))]).encoded
    }

    /// One stored prekey's entry.
    private func stored(id: Int64, privateKey: [UInt8], createdAt: Int64, signature: [UInt8]) -> CBOR {
        .map([
            CBOR.Entry(key: .text("id"), value: CBOR(id)),
            CBOR.Entry(key: .text("priv"), value: .bytes(privateKey)),
            CBOR.Entry(key: .text("createdAt"), value: CBOR(createdAt)),
            CBOR.Entry(key: .text("sig"), value: .bytes(signature)),
        ])
    }

    /// Prekey `id` of `identity`, its pair fixed by `seed`, as the ring would store it.
    private func stored(_ id: Int, of identity: IdentityKeys, seed: Int, createdAt: Int64 = 0) throws -> CBOR {
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: seed))
        let signature = try identity.signature(for: RatchetCrypto.spkSigningBytes(id: id, pub: pair.publicKey))
        return stored(id: Int64(id), privateKey: pair.privateKey, createdAt: createdAt, signature: signature)
    }

    @Test func aStoreWithNoPrekeysIsAnEmptyRingAndLoadingWritesNothing() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        let ring = try PrekeyRing.load(for: identity, from: store)
        #expect(ring.prekeys.isEmpty)
        #expect(ring.newest?.id == nil)
        #expect(ring.prekey(id: 1)?.id == nil)
        let empty = MemorySecretStore(secret: nil, refuses: false)
        #expect(try PrekeyRing.load(for: identity, from: empty).prekeys.isEmpty)
        #expect(store.writes == 0 && empty.writes == 0, "loading never writes")
    }

    @Test func theFirstMintIsIdOneKeptBesideTheIdentityWithItsSignatureAsMinted() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        let minted = try #require(try ring.rotateIfDue(now: start))
        #expect(minted.id == 1)
        #expect(minted.createdAt == start)
        #expect(ring.newest?.id == 1)
        #expect(store.writes == 1)
        // Verified as a peer verifies it, never compared with a signature made again: CryptoKit randomizes Ed25519.
        let verified = PeerPrekey(verifying: minted.info, signedBy: identity.bundle)
        #expect(verified?.id == 1)
        #expect(verified?.publicKey == minted.publicKey)
        let reread = try #require(try PrekeyRing.load(for: identity, from: store).prekey(id: 1))
        #expect(reread.privateKey == minted.privateKey)
        #expect(reread.publicKey == minted.publicKey)
        #expect(reread.signature == minted.signature, "the signature made at the mint, read back, not made again")
        #expect(reread.createdAt == start)
    }

    @Test func aPrekeyRotatesOnceItIsAWeekOldAndNotBefore() throws {
        let identity = try keys(1)
        var ring = try PrekeyRing.load(for: identity, from: store(holding: identity))
        _ = try ring.rotateIfDue(now: start)
        let early = try ring.rotateIfDue(now: start + week - 1)
        #expect(early?.id == nil)
        let due = try ring.rotateIfDue(now: start + week)
        #expect(due?.id == 2)
        #expect(ring.prekeys.map(\.id) == [2, 1])
    }

    @Test func theFiveHighestIdsAreKept() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        for minute in 0..<7 {
            try ring.rotate(now: start + Int64(minute) * 60_000)
        }
        #expect(ring.prekeys.map(\.id) == [7, 6, 5, 4, 3])
        let reread = try PrekeyRing.load(for: identity, from: store)
        #expect(reread.prekeys.map(\.id) == [7, 6, 5, 4, 3])
        #expect(reread.prekey(id: 2)?.id == nil, "an init made against it starts again")
        #expect(reread.prekey(id: 3)?.createdAt == start + 2 * 60_000)
    }

    @Test func theStoredFormIsTheIdentityMapGrownByItsPrekeysNewestFirst() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        try ring.rotate(now: start + 1)
        let held = try entries(store.contents)
        #expect(held.map(\.key) == [.text("signingSeed"), .text("agreementScalar"), .text("prekeys")])
        guard case .array(let prekeys) = held.last?.value else {
            Issue.record("prekeys is not an array")
            return
        }
        #expect(prekeys.count == 2)
        let newest = try #require(ring.newest)
        let expected = stored(
            id: Int64(newest.id), privateKey: newest.privateKey, createdAt: newest.createdAt, signature: newest.signature)
        #expect(prekeys.first == expected)
    }

    @Test func theGrownItemStillLoadsTheSameIdentityAndAnOlderBuildWritesNothingOverIt() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        let grown = try #require(store.contents)
        #expect(grown != identity.storedForm)
        #expect(IdentityKeys(storedForm: grown)?.nodeId == identity.nodeId)
        let loaded = try IdentityKeys.load(from: store)
        #expect(loaded.origin == .stored)
        #expect(loaded.keys.nodeId == identity.nodeId)
        #expect(store.contents == grown)
    }

    @Test func aWriteKeepsEveryOtherEntryInTheItem() throws {
        // A newer build's entry, which this one cannot read, survives this one's rotation.
        let identity = try keys(1)
        let future = CBOR.Entry(key: .text("future"), value: .text("kept"))
        let store = MemorySecretStore(secret: try item(identity, prekeys: [], extra: [future]), refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        let held = try entries(store.contents)
        #expect(held.contains(future))
        #expect(held.map(\.key).filter { $0 == .text("prekeys") }.count == 1)
        #expect(try PrekeyRing.load(for: identity, from: store).prekeys.map(\.id) == [1])
    }

    @Test func aRefusedOrLostWriteLeavesTheRingAndTheNextTryMintsTheSameId() throws {
        let identity = try keys(1)
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        let before = store.contents
        store.refusesWrites = true
        #expect(throws: PrekeyRing.Failure.store(.unavailable("full"))) {
            try ring.rotate(now: start + week)
        }
        #expect(ring.prekeys.map(\.id) == [1])
        #expect(store.contents == before)
        store.refusesWrites = false
        store.dropsWrites = true
        #expect(throws: PrekeyRing.Failure.readBack) {
            try ring.rotate(now: start + week)
        }
        #expect(ring.prekeys.map(\.id) == [1], "a write that did not read back is not kept")
        store.dropsWrites = false
        #expect(try ring.rotate(now: start + week).id == 2, "the next heal tries again")
        #expect(try PrekeyRing.load(for: identity, from: store).prekeys.map(\.id) == [2, 1])
    }

    @Test func aStoreThatCannotAnswerThrowsAndMintsNothing() throws {
        let identity = try keys(1)
        let locked = MemorySecretStore(secret: identity.storedForm, refuses: true)
        #expect(throws: SecretStoreError.unavailable("locked")) {
            try PrekeyRing.load(for: identity, from: locked)
        }
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        store.refuses = true
        #expect(throws: PrekeyRing.Failure.store(.unavailable("locked"))) {
            try ring.rotate(now: start)
        }
        #expect(ring.prekeys.isEmpty)
        #expect(store.writes == 0)
    }

    @Test func aStoreHoldingNoIdentityOrAnotherOneRefusesTheWrite() throws {
        let identity = try keys(1)
        let other = try keys(3)
        let empty = MemorySecretStore(secret: nil, refuses: false)
        var bare = try PrekeyRing.load(for: identity, from: empty)
        #expect(throws: PrekeyRing.Failure.identityReplaced) {
            try bare.rotate(now: start)
        }
        #expect(empty.contents == nil)
        // The identity replaced under a ring that loaded before: a knit-peer keygen, or a debug build's new identity.
        let store = store(holding: identity)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        try store.write(other.storedForm)
        #expect(throws: PrekeyRing.Failure.identityReplaced) {
            try ring.rotate(now: start + week)
        }
        #expect(store.contents == other.storedForm)
        #expect(ring.prekeys.map(\.id) == [1])
    }

    @Test func anotherIdentitysPrekeysAreNeverLoaded() throws {
        let identity = try keys(1)
        let other = try keys(3)
        let theirs = MemorySecretStore(secret: try item(other, prekeys: [try stored(1, of: other, seed: 40)]), refuses: false)
        #expect(try PrekeyRing.load(for: identity, from: theirs).prekeys.isEmpty)
        #expect(try PrekeyRing.load(for: other, from: theirs).prekeys.map(\.id) == [1])
    }

    @Test func aStoredPrekeyThatAPeerWouldRefuseIsLeftOut() throws {
        let identity = try keys(1)
        let other = try keys(3)
        let good = try stored(3, of: identity, seed: 40)
        let shortKey = try stored(4, of: identity, seed: 41)
        guard case .map(var fields) = shortKey else {
            Issue.record("a stored prekey is a map")
            return
        }
        fields[1] = CBOR.Entry(key: .text("priv"), value: .bytes(fixtureBytes(31, seed: 41)))
        let prekeys: [CBOR] = [
            good,
            try stored(5, of: other, seed: 42),
            .map(fields),
            try stored(0, of: identity, seed: 43),
            try stored(Int(Int32.max) + 1, of: identity, seed: 44),
            try stored(3, of: identity, seed: 45),
            .text("not a prekey"),
            .map([CBOR.Entry(key: .text("id"), value: CBOR(Int64(6)))]),
        ]
        let ring = try PrekeyRing.load(for: identity, from: MemorySecretStore(secret: try item(identity, prekeys: prekeys), refuses: false))
        #expect(ring.prekeys.map(\.id) == [3], "signed by another, a short key, ids off the wire, a second 3, and no fields")
        #expect(ring.prekey(id: 3)?.privateKey == fixtureBytes(32, seed: 40), "the first stored for an id")
    }

    @Test func aPrekeyWhoseAgeDoesNotFitIsDue() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(
            secret: try item(identity, prekeys: [try stored(1, of: identity, seed: 40, createdAt: .min)]), refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(try ring.rotateIfDue(now: start)?.id == 2)
    }

    @Test func idsStopAtTheWiresLimit() throws {
        let identity = try keys(1)
        let last = Int(Int32.max)
        let store = MemorySecretStore(secret: try item(identity, prekeys: [try stored(last, of: identity, seed: 40)]), refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(ring.newest?.id == last)
        #expect(throws: PrekeyRing.Failure.idsExhausted) {
            try ring.rotate(now: start)
        }
        #expect(store.writes == 0)
    }

    @Test func eachMintTakesItsPairFromTheSourceGiven() throws {
        let identity = try keys(1)
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 42))
        var ring = try PrekeyRing.load(for: identity, from: store(holding: identity)) { pair }
        let minted = try ring.rotate(now: start)
        #expect(minted.publicKey == pair.publicKey)
        #expect(minted.privateKey == pair.privateKey)
    }
}

// MARK: Entries this build cannot read

/// A rotation over stored entries this build cannot read: it mints past their ids and writes them back as they were
/// stored, as Android never mints over prekeys it cannot parse (`IdentityKeyStore.kt:136-137`, `:197`).
extension PrekeyRingTests {
    /// `entry` with `field` set to `value`, or added when it has none.
    private func setting(_ field: String, to value: CBOR, in entry: CBOR) -> CBOR {
        guard case .map(let fields) = entry else {
            Issue.record("a stored prekey is a map")
            return entry
        }
        let key = CBOR.text(field)
        let set = CBOR.Entry(key: key, value: value)
        return .map(fields.contains { $0.key == key } ? fields.map { $0.key == key ? set : $0 } : fields + [set])
    }

    /// The stored item's `prekeys` list.
    private func storedPrekeys(_ bytes: [UInt8]?) throws -> [CBOR] {
        guard case .array(let list) = try entries(bytes).first(where: { $0.key == .text("prekeys") })?.value else {
            Issue.record("prekeys is not a list")
            return []
        }
        return list
    }

    /// Whether `bytes` holds `part` as it is, byte for byte.
    private func holds(_ part: [UInt8], in bytes: [UInt8]?) -> Bool {
        guard let bytes, part.count <= bytes.count else {
            return false
        }
        return (0...(bytes.count - part.count)).contains { Array(bytes[$0..<$0 + part.count]) == part }
    }

    @Test func aRotationMintsPastAnUnreadableTopIdAndKeepsEveryEntryAsStored() throws {
        // A peer may hold id 9 under the public value it was published with, so it is never minted again
        // (`MeshManager.kt:1011-1013`), and an entry this build cannot read is written back as it was stored.
        let identity = try keys(1)
        let shortNine = setting("priv", to: .bytes(fixtureBytes(31, seed: 49)), in: try stored(9, of: identity, seed: 49))
        let offTheWire = try stored(Int(Int32.max) + 1, of: identity, seed: 44)
        let notAPrekey = CBOR.text("not a prekey")
        let withAField = setting("future", to: .text("kept"), in: try stored(2, of: identity, seed: 41))
        let store = MemorySecretStore(
            secret: try item(identity, prekeys: [shortNine, try stored(1, of: identity, seed: 40), notAPrekey, withAField, offTheWire]),
            refuses: false
        )
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(ring.prekeys.map(\.id) == [2, 1])
        #expect(try ring.rotate(now: start).id == 10, "one above 9, the highest id stored; ids off the wire count for nothing")
        for unread in [shortNine, notAPrekey, offTheWire] {
            #expect(holds(unread.encoded, in: store.contents), "\(unread) is still stored, byte for byte")
        }
        #expect(try storedPrekeys(store.contents).contains(withAField), "a field this build does not know survives")
        #expect(try storedPrekeys(store.contents).count == 6)
        #expect(try PrekeyRing.load(for: identity, from: store).prekeys.map(\.id) == [10, 2, 1])
    }

    @Test func retentionPrunesOnlyEntriesThisBuildReads() throws {
        // Android prunes only the records it parsed (`IdentityKeyStore.kt:197`), and mints over none it cannot parse
        // (`:136-137`): an entry this build cannot read neither counts toward the five nor is ever dropped.
        let identity = try keys(1)
        let badSeven = setting("sig", to: .bytes(fixtureBytes(64, seed: 47)), in: try stored(7, of: identity, seed: 47))
        let readable = try (1...5).map { try stored($0, of: identity, seed: 40 + $0) }
        let store = MemorySecretStore(secret: try item(identity, prekeys: [badSeven] + readable), refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(ring.prekeys.map(\.id) == [5, 4, 3, 2, 1])
        try ring.rotate(now: start)
        try ring.rotate(now: start + 1)
        #expect(ring.prekeys.map(\.id) == [9, 8, 5, 4, 3])
        #expect(holds(badSeven.encoded, in: store.contents))
        #expect(try storedPrekeys(store.contents).count == 6)
        #expect(try PrekeyRing.load(for: identity, from: store).prekeys.map(\.id) == [9, 8, 5, 4, 3])
    }

    @Test func prekeysThatAreNotOneListAreNeverMintedOver() throws {
        let identity = try keys(1)
        let held = try entries(identity.storedForm)
        let foreign = CBOR.map([CBOR.Entry(key: .text("v2"), value: .bytes([1, 2, 3]))])
        let shapes = [
            held + [CBOR.Entry(key: .text("prekeys"), value: foreign)],
            held + [CBOR.Entry(key: .text("prekeys"), value: .array([])), CBOR.Entry(key: .text("prekeys"), value: .array([]))],
        ]
        for shape in shapes {
            let bytes = CBOR.map(shape).encoded
            let store = MemorySecretStore(secret: bytes, refuses: false)
            var ring = try PrekeyRing.load(for: identity, from: store)
            #expect(ring.prekeys.isEmpty)
            #expect(throws: PrekeyRing.Failure.unreadablePrekeys) {
                try ring.rotate(now: start)
            }
            #expect(store.writes == 0)
            #expect(store.contents == bytes)
        }
    }
}
