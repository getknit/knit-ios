import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// Our presence keys' last generation in the identity's item (ADR 2026-11.prsp, "Where each piece is stored"): written the
/// way `PrekeyRing.Item` is written, read with every other entry kept byte for byte, never read as 0 when the store cannot
/// answer, and clamped to the clock only when asked (`clampRestored`, `PresenceKeyPolicyTest.kt:129-137` at knit-next
/// `cad69c77b`).
@Suite struct PrekeyRingPresenceGenerationTests {
    private let start: Int64 = 1_756_200_000_000
    private let year: Int64 = 365 * 86_400_000

    private func keys(_ seed: Int) throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 1)))
    }

    private func value(_ key: String, in bytes: [UInt8]?) throws -> CBOR? {
        guard case .map(let entries) = try CBOR.decode(try #require(bytes)) else {
            Issue.record("the item is not a map")
            return nil
        }
        return entries.last { $0.key == .text(key) }?.value
    }

    @Test func theLastGenerationIsKeptBesideThePrekeysAndTheAnsweredInitsAndSurvivesAReload() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(try ring.presenceLastGeneration() == 0, "none recorded yet")
        try ring.rotate(now: start)
        try ring.keepAnswered(fixtureBytes(32, seed: 40), from: try keys(10).nodeId, now: start)
        let prekeys = try value("prekeys", in: store.contents)
        let answered = try value("answered", in: store.contents)

        try ring.setPresenceLastGeneration(start + 5)
        #expect(try ring.presenceLastGeneration() == start + 5)
        #expect(try value("prekeys", in: store.contents) == prekeys, "the prekeys byte for byte")
        #expect(try value("answered", in: store.contents) == answered, "the answered inits byte for byte")
        #expect(IdentityKeys(storedForm: try #require(store.contents))?.nodeId == identity.nodeId)

        let reinstalled = try PrekeyRing.load(for: identity, from: store)
        #expect(try reinstalled.presenceLastGeneration() == start + 5)
        // A rotation writes it back as it was stored.
        var rotated = reinstalled
        try rotated.rotate(now: start + PrekeyRing.rotationMilliseconds)
        #expect(try rotated.presenceLastGeneration() == start + 5)
    }

    @Test func aStoreThatCannotAnswerIsNeverReadAsNoGeneration() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        let ring = try PrekeyRing.load(for: identity, from: store)
        try ring.setPresenceLastGeneration(start)
        store.refuses = true
        #expect(throws: PrekeyRing.Failure.self) { try ring.presenceLastGeneration() }
        #expect(throws: PrekeyRing.Failure.self) { try ring.setPresenceLastGeneration(start + 1) }
        store.refuses = false
        store.refusesWrites = true
        #expect(throws: PrekeyRing.Failure.self) { try ring.setPresenceLastGeneration(start + 1) }
        store.refusesWrites = false
        store.dropsWrites = true
        #expect(throws: PrekeyRing.Failure.readBack) { try ring.setPresenceLastGeneration(start + 1) }
        store.dropsWrites = false
        #expect(try ring.presenceLastGeneration() == start, "nothing a failure touched")
    }

    @Test func anotherIdentitysItemOrAValueThatIsNotOneIntegerIsRefused() throws {
        let identity = try keys(1)
        let other = MemorySecretStore(secret: try keys(5).storedForm, refuses: false)
        let foreign = try PrekeyRing.load(for: identity, from: other)
        #expect(throws: PrekeyRing.Failure.identityReplaced) { try foreign.presenceLastGeneration() }
        #expect(throws: PrekeyRing.Failure.identityReplaced) { try foreign.setPresenceLastGeneration(start) }

        guard case .map(var entries) = try CBOR.decode(identity.storedForm) else {
            Issue.record("the stored form is not a map")
            return
        }
        entries.append(CBOR.Entry(key: .text("presenceLast"), value: .bytes([1])))
        let damaged = MemorySecretStore(secret: CBOR.map(entries).encoded, refuses: false)
        let ring = try PrekeyRing.load(for: identity, from: damaged)
        #expect(throws: PrekeyRing.Failure.unreadablePresenceGeneration) { try ring.presenceLastGeneration() }
    }

    @Test func aGenerationMoreThanAYearAheadIsClampedToTheClockWhenAsked() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        let ring = try PrekeyRing.load(for: identity, from: store)
        try ring.setPresenceLastGeneration(start + year)
        #expect(try ring.clampPresenceLastGeneration(now: start, aheadMilliseconds: year) == nil)
        #expect(try ring.presenceLastGeneration() == start + year)
        try ring.setPresenceLastGeneration(start + year + 1)
        #expect(try ring.clampPresenceLastGeneration(now: start, aheadMilliseconds: year) == start)
        #expect(try ring.presenceLastGeneration() == start)
        // A clock so far ahead the bound overflows clamps nothing; one far behind clamps the largest generation.
        try ring.setPresenceLastGeneration(.max)
        #expect(try ring.clampPresenceLastGeneration(now: .max - 1, aheadMilliseconds: year) == nil)
        #expect(try ring.clampPresenceLastGeneration(now: 5, aheadMilliseconds: year) == 5)
    }
}
