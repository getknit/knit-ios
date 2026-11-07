import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The receive half of ``PresenceKeyPolicy`` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): `PresenceKeyPolicyTest`'s
/// receive cases ported by name (`PresenceKeyPolicyTest.kt:148-206` at knit-next `cad69c77b`), what a received key does to
/// the keys held for its sender in each era a frame can open under.
@Suite struct PresenceKeyPolicyTests {
    private static let tagA: Int64 = 0x0A0A
    private static let tagB: Int64 = -0x0B0B

    private static func bytes(_ seed: Int) -> [UInt8] {
        (0..<32).map { UInt8(truncatingIfNeeded: $0 + seed) }
    }

    /// A key of 32 bytes counting up from `seed`, which always makes one.
    private static func key(_ seed: Int) -> PresenceKey {
        guard let key = PresenceKey(bytes: bytes(seed)) else {
            preconditionFailure("32 bytes are a key")
        }
        return key
    }

    private static func held(_ generation: Int64, _ seed: Int, _ tag: Int64) -> HeldPresenceKey {
        HeldPresenceKey(generation: generation, key: key(seed), rootTag: tag)
    }

    private static func offered(_ pairs: [(Int64, Int)]) -> [PresenceKeyPolicy.Offered] {
        pairs.map { PresenceKeyPolicy.Offered(generation: $0.0, key: key($0.1)) }
    }

    private static func generations(_ verdict: PresenceKeyPolicy.Verdict) -> [Int64]? {
        guard case .store(let rows, _, _) = verdict else {
            return nil
        }
        return rows.map(\.generation)
    }

    @Test func aMalformedPayloadIsRefusedAndAWellFormedOneListsLowestFirst() {
        let keysIn = PresenceKeyPolicy.keysIn
        #expect(keysIn(PresenceKeyPayload(generation: 1, key: [UInt8](repeating: 0, count: 31))) == nil)
        #expect(keysIn(PresenceKeyPayload(generation: 0, key: Self.bytes(1))) == nil)
        #expect(keysIn(PresenceKeyPayload(generation: -1, key: Self.bytes(1))) == nil, "a `g` kotlinx wrapped past Int64.max")
        #expect(keysIn(PresenceKeyPayload(generation: 1, key: Self.bytes(1), nextGeneration: 2)) == nil)
        #expect(keysIn(PresenceKeyPayload(generation: 1, key: Self.bytes(1), nextKey: Self.bytes(2))) == nil)
        #expect(keysIn(PresenceKeyPayload(generation: 2, key: Self.bytes(1), nextGeneration: 2, nextKey: Self.bytes(2))) == nil)
        #expect(keysIn(PresenceKeyPayload(generation: 2, key: Self.bytes(1), nextGeneration: 3, nextKey: [1, 2, 3, 4, 5])) == nil)
        #expect(
            keysIn(PresenceKeyPayload(generation: 5, key: Self.bytes(1), nextGeneration: 6, nextKey: Self.bytes(2)))?.map(\.generation) == [
                5, 6,
            ])
        #expect(keysIn(PresenceKeyPayload(generation: 5, key: Self.bytes(1)))?.map(\.key) == [Self.key(1)])
    }

    @Test func theSameEraAddsANewGenerationIgnoresAnEqualOneAndRefusesAConflictOrAnOlderOne() {
        let held = [Self.held(10, 10, Self.tagA), Self.held(11, 11, Self.tagA)]
        let added = PresenceKeyPolicy.receive(held: held, frame: Self.offered([(11, 11), (12, 12)]), openedTag: Self.tagA, active: true)
        guard case .store(let rows, let replaced, let count) = added else {
            Issue.record("stored: \(added)")
            return
        }
        #expect(!replaced && count == 1)
        #expect(rows.map(\.generation) == [12, 11, 10])
        #expect(
            PresenceKeyPolicy.receive(held: held, frame: Self.offered([(10, 10), (11, 11)]), openedTag: Self.tagA, active: true) == .noOp)
        #expect(
            PresenceKeyPolicy.receive(held: held, frame: Self.offered([(11, 99)]), openedTag: Self.tagA, active: true)
                == .refused(.conflict))
        #expect(
            PresenceKeyPolicy.receive(held: held, frame: Self.offered([(9, 9)]), openedTag: Self.tagA, active: true) == .refused(.older))
    }

    @Test func aNewActiveRootReplacesEveryHeldKeyEvenWithALowerGeneration() {
        // B3: a sender restored after its clock ran ahead hands lower generations under the root its reset made.
        let held = [Self.held(500, 5, Self.tagA), Self.held(501, 6, Self.tagA)]
        let verdict = PresenceKeyPolicy.receive(held: held, frame: Self.offered([(20, 20), (21, 21)]), openedTag: Self.tagB, active: true)
        guard case .store(let rows, let replaced, let added) = verdict else {
            Issue.record("replaced: \(verdict)")
            return
        }
        #expect(replaced && added == 2)
        #expect(rows.map(\.generation) == [21, 20])
        #expect(rows.allSatisfy { $0.rootTag == Self.tagB })
    }

    @Test func aDrainNeverStartsAnEraOrMovesATag() {
        let held = [Self.held(20, 20, Self.tagB)]
        // A late frame of the old era, lower: refused, never a replacement.
        #expect(
            PresenceKeyPolicy.receive(held: held, frame: Self.offered([(10, 10)]), openedTag: Self.tagA, active: false) == .refused(.older))
        // Newer: added under the held keys' tag, not the drain's.
        let added = PresenceKeyPolicy.receive(held: held, frame: Self.offered([(30, 30)]), openedTag: Self.tagA, active: false)
        guard case .store(let rows, let replaced, _) = added else {
            Issue.record("added: \(added)")
            return
        }
        #expect(!replaced)
        #expect(rows.allSatisfy { $0.rootTag == Self.tagB })
        // An equal generation and key from the drain is the silent no-op.
        #expect(PresenceKeyPolicy.receive(held: held, frame: Self.offered([(20, 20)]), openedTag: Self.tagA, active: false) == .noOp)
    }

    @Test func aDrainOpenWithNothingHeldStoresUnderItsOwnTagAndTheNextActiveOpenReplacesIt() {
        let stored = PresenceKeyPolicy.receive(held: [], frame: Self.offered([(500, 5)]), openedTag: Self.tagA, active: false)
        guard case .store(let rows, let replaced, _) = stored else {
            Issue.record("stored: \(stored)")
            return
        }
        #expect(!replaced && rows.allSatisfy { $0.rootTag == Self.tagA })
        let next = PresenceKeyPolicy.receive(held: rows, frame: Self.offered([(20, 20)]), openedTag: Self.tagB, active: true)
        guard case .store(let after, let replacedNow, _) = next else {
            Issue.record("replaced: \(next)")
            return
        }
        #expect(replacedNow)
        #expect(after.map(\.generation) == [20])
    }

    @Test func aPeerKeepsItsThreeNewestGenerations() {
        let held = [Self.held(1, 1, Self.tagA), Self.held(2, 2, Self.tagA), Self.held(3, 3, Self.tagA)]
        let verdict = PresenceKeyPolicy.receive(held: held, frame: Self.offered([(4, 4), (5, 5)]), openedTag: Self.tagA, active: true)
        #expect(Self.generations(verdict) == [5, 4, 3])
    }

    /// Not in Kotlin's suite: an active open under the held keys' own tag is the same era, ordered key by key, never a
    /// replacement, so a skipped-key or live-chain open under the active root cannot reset what is held.
    @Test func anActiveOpenUnderTheHeldTagOrdersRatherThanReplaces() {
        let held = [Self.held(10, 10, Self.tagA)]
        #expect(
            PresenceKeyPolicy.receive(held: held, frame: Self.offered([(5, 5)]), openedTag: Self.tagA, active: true) == .refused(.older))
    }

    /// A refusal prints Android's name for it, which its refused line carries (`Refusal`, `PresenceKeyPolicy.kt:264-276`;
    /// `notePresenceKey`'s `refused: ${verdict.why}`, `InboundPipeline.kt:1990`). `UNKNOWN_SENDER` never reaches the line
    /// from a frame here (``MeshEnginePresenceKeyTests``), so its name is pinned beside the rest.
    @Test func everyRefusalPrintsAndroidsName() {
        let refusals: [PresenceKeyPolicy.Refusal] = [.malformed, .unknownSender, .conflict, .older]
        #expect(refusals.map { "\($0)" } == ["MALFORMED", "UNKNOWN_SENDER", "CONFLICT", "OLDER"])
    }

    /// Nothing the policy holds prints a key.
    @Test func noVerdictPrintsAKey() {
        let verdict = PresenceKeyPolicy.receive(held: [], frame: Self.offered([(7, 1)]), openedTag: Self.tagA, active: true)
        let printed = "\(verdict) \(String(reflecting: verdict))"
        #expect(printed.contains("g=7"))
        #expect(!printed.contains("1, 2, 3"), "no key bytes: \(printed)")
    }
}
