import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The consent-gated, capped scope table (ADR 2026-11.adrq, amended 2026-11-16): accepted and unblocked peers alone, a
/// failed read keeps the table, and at most 128 peers ranked by this phone's own activity with live scopes first.
@Suite struct ScopeTableTests {
    private let relays = [SpoolRelayHandle(number: 1)]

    private func peer(_ number: Int) -> NodeId {
        TestPeer(seed: 1000 + number).nodeId
    }

    private func keys(_ number: Int) -> ScopeKeys {
        let id = [UInt8](repeating: 0xA5, count: 28) + withUnsafeBytes(of: UInt32(truncatingIfNeeded: number).bigEndian, Array.init)
        guard let keys = ScopeKeys(id: id, sealKey: fixtureBytes(32, seed: 1), nonceKey: fixtureBytes(32, seed: 2)) else {
            preconditionFailure("32 bytes each")
        }
        return keys
    }

    private func scopes(_ peer: NodeId, _ number: Int, retiring: Bool = false) -> RatchetSessions.DMScopes {
        RatchetSessions.DMScopes(peerId: peer, live: keys(number), retiring: retiring ? keys(10_000 + number) : nil)
    }

    private func table(
        _ dmScopes: [RatchetSessions.DMScopes]?, accepted: Set<NodeId>?, blocked: Set<NodeId>? = [], recent: [NodeId: Int64] = [:],
        from current: ScopeTable = ScopeTable()
    ) -> ScopeTable.Update {
        current.updated(
            dmScopes: dmScopes, accepted: accepted, blocked: blocked, recent: recent, relays: relays)
    }

    private func peers(_ update: ScopeTable.Update) -> [NodeId] {
        guard case .table(let table) = update else {
            return []
        }
        return table.scopes.map(\.peer)
    }

    @Test func aConfirmedButUnacceptedPeerHasNoScope() {
        // A session is confirmed for every entry `dmScopes` answers; only consent puts its scopes in the table.
        #expect(peers(table([scopes(peer(1), 1)], accepted: [])).isEmpty)
        #expect(peers(table([scopes(peer(1), 1)], accepted: [peer(1)])) == [peer(1)])
    }

    @Test func aPeerSeenOnlyInAGroupHasNone() {
        // A group's member reaches `accepted` only through a DM thread, a verification or our own writing: the group's
        // senders are not part of it.
        let groupOnly = peer(2)
        #expect(peers(table([scopes(peer(1), 1), scopes(groupOnly, 2)], accepted: [peer(1)])) == [peer(1)])
    }

    @Test func aBlockRemovesAnAcceptedPeersScopesBothOfThem() {
        let both = [scopes(peer(1), 1, retiring: true), scopes(peer(2), 2)]
        guard case .table(let current) = table(both, accepted: [peer(1), peer(2)]) else {
            Issue.record("a table")
            return
        }
        #expect(current.scopes.count == 3)
        #expect(peers(table(both, accepted: [peer(1), peer(2)], blocked: [peer(1)], from: current)) == [peer(2)])
    }

    @Test func aReadThatFailedKeepsTheTable() {
        guard case .table(let current) = table([scopes(peer(1), 1)], accepted: [peer(1)]) else {
            Issue.record("a table")
            return
        }
        #expect(table(nil, accepted: [peer(1)], from: current) == .unchanged)
        #expect(table([], accepted: nil, from: current) == .unchanged)
        #expect(table([], accepted: [], blocked: nil, from: current) == .unchanged)
        #expect(table([scopes(peer(1), 1)], accepted: [peer(1)], from: current) == .unchanged, "nothing moved")
    }

    @Test func capPlusOnePeersKeepsTheCapWithLiveScopesFirst() throws {
        let all = (0...ScopeTable.maxPeers).map { scopes(peer($0), $0, retiring: $0 < 4) }
        let accepted = Set(all.map(\.peerId))
        let recent = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.peerId, Int64($0)) })
        guard case .table(let capped) = table(all, accepted: accepted, recent: recent) else {
            Issue.record("a table")
            return
        }
        #expect(Set(capped.scopes.map(\.peer)).count == ScopeTable.maxPeers)
        #expect(!capped.scopes.contains { $0.peer == peer(0) }, "the least recent peer goes")
        let retiringAt = capped.scopes.firstIndex(where: \.retiring)
        let firstRetiring = try #require(retiringAt)
        let liveFirst = capped.scopes[firstRetiring...].allSatisfy(\.retiring)
        #expect(liveFirst, "live scopes first")
    }

    @Test func rankingReadsOurOwnActivityNeverAPeersSentAt() {
        // Two peers, the cap one: the one this phone was active with last stays, whoever's frames claim to be newer.
        let all = (0...ScopeTable.maxPeers).map { scopes(peer($0), $0) }
        var recent = Dictionary(uniqueKeysWithValues: all.map { ($0.peerId, Int64(100)) })
        recent[peer(7)] = 50
        let kept = peers(table(all, accepted: Set(all.map(\.peerId)), recent: recent))
        #expect(kept.count == ScopeTable.maxPeers && !kept.contains(peer(7)))
        #expect(kept.first.flatMap { recent[$0] } == 100)
    }
}

/// The relay's hourly pull budget and its garbage fault (``SpoolIntake``).
@Suite struct SpoolIntakeTests {
    @Test func theHoursRoomShrinksWithChargesGrowsWithRefundsAndComesBackOnlyWithTheHour() {
        var intake = SpoolIntake()
        #expect(intake.room(now: 0) == SpoolIntake.maxPulledBytes)
        intake.charge(bytes: SpoolIntake.maxPulledBytes, now: 10)
        #expect(intake.room(now: 20) == 0)
        intake.refund(bytes: 1000)
        #expect(intake.room(now: 30) == 1000)
        intake.refund(bytes: .max)
        #expect(intake.room(now: 30) == SpoolIntake.maxPulledBytes, "a refund never goes below nothing")
        intake.charge(bytes: .max, now: 40)
        intake.charge(bytes: .max, now: 40)
        #expect(intake.room(now: 50) == 0)
        #expect(intake.room(now: 40 + SpoolIntake.windowMilliseconds) == SpoolIntake.maxPulledBytes)
    }

    @Test func aRelayWhoseServesTheSpoolGarbledIsFaultedAndTheHoursBytesStand() {
        var intake = SpoolIntake()
        intake.charge(bytes: 4096, now: 0)
        for _ in 0..<SpoolIntake.faultAfterFailures {
            _ = intake.judged(spoolFault: false, now: 0)
        }
        for _ in 0..<SpoolIntake.faultAfterFailures {
            let faulted = intake.judged(spoolFault: true, now: 0)
            #expect(!faulted)
        }
        let faulted = intake.judged(spoolFault: true, now: 0)
        #expect(faulted, "one more failure than blobs that hashed true")
        #expect(intake.failed == 0, "a fault starts the count over")
        #expect(intake.bytes == 4096, "and never the hour's bytes")
    }

    @Test func aClockAtEitherEndNeverTraps() {
        var intake = SpoolIntake()
        _ = intake.room(now: .min)
        _ = intake.room(now: .max)
        _ = intake.judged(spoolFault: true, now: .min)
        let late = intake.room(now: .max)
        #expect(late == SpoolIntake.maxPulledBytes)
    }
}
