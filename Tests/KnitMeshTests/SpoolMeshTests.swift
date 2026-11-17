import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Two ``Mesh``es over test sockets and ``FakeSpool`` (ADR 2026-11.adrq, P4b1): the socket tasks, pause and resume, the
/// bounds, a block with a live relay, and the log oracle. No radio link.
@Suite struct SpoolMeshTests {
    static let alice = SpoolEngineLabTests.alice
    static let bob = SpoolEngineLabTests.bob
    static let nodes = [alice.nodeId.string, bob.nodeId.string]

    /// Test 1: text and ✓✓ both ways through the socket tasks, and the fold equals the spool's digest.
    @Test func textAndTheDoubleTickGoBothWaysThroughTheSockets() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        let toBob = try await rig.send(0, 1, "over the socket")
        let toAlice = try await rig.send(1, 0, "and back")
        await rig.run(12)
        #expect(rig.holds(1, toBob) && rig.holds(0, toAlice), "both delivered")
        #expect(rig.lab[0].stores.messages.message(toBob)?.delivered == true, "the double tick came back")
        #expect(rig.pairIds(0) == rig.pairIds(1), "both custodies hold the same live ids")
        let folds = await rig.folds()
        #expect(folds.alice == folds.spool && folds.bob == folds.spool, "every fold is the spool's digest")
        #expect(rig.net.overlappingReceives == 0, "one record in flight per connection")
        for index in 0..<2 {
            let status = await rig[index].spoolStatus
            #expect(status.relays.first?.state == "open" && status.relays.first?.counts["sessions"] == 1)
        }
    }

    /// Test 2: a dropped relay, the clock past the 60 s tick: the timer fires a bounded number of times before the redial,
    /// and the plane's deadline is the redial.
    @Test func aDroppedRelayWakesOnlyForItsRedial() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        rig.net.refuse(Array(repeating: SpoolDialFailure(.unreachable), count: 100))
        rig.net.dropAll(code: SpoolCloseCode.abuse)
        await rig.settle()
        for _ in 0..<4 {
            let redial = try #require(await rig[0].spoolRedial(SpoolMeshRig.relay))
            #expect(await rig[0].spoolDeadline == redial, "the redial alone")
            let firings = await rig[0].timerFirings
            await rig.advance(redial - rig.clock.monotonicMilliseconds())
            #expect(await rig[0].timerFirings - firings <= 3, "a bounded number of wakes")
        }
        rig.clock.advance(ScopeHeal.tickMilliseconds)
        await rig.settle()
        #expect(await rig[0].spoolDeadline == (await rig[0].spoolRedial(SpoolMeshRig.relay)), "past the tick, still the redial")
    }

    /// Tests 4 and 5: Alice pauses while Bob sends, and the two pause out of phase for 20 cycles: both deliver once, ✓✓ comes
    /// back, folds equal the digest, custodies agree, and the spool serves no more than the unique bytes and a pull a cycle.
    @Test func pausesOutOfPhaseConvergeAndDeliverOnce() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        await rig[0].pauseSpool()
        var ids: [String] = []
        for index in 0..<5 {
            ids.append(try await rig.send(1, 0, "while alice is away \(index)"))
        }
        await rig.run(2)
        #expect(ids.allSatisfy { !rig.holds(0, $0) })
        rig.net.forgetSent()
        await rig[0].resumeSpool()
        await rig.run(6)
        #expect(ids.allSatisfy { rig.holds(0, $0) }, "every DM arrived on the resume")
        #expect(ids.allSatisfy { rig.lab[1].stores.messages.message($0)?.delivered == true }, "and its double tick came back")
        let lists = rig.net.sent(by: 0).count { if case .list = $0 { true } else { false } }
        #expect(lists <= 2, "at most a listing per scope after the resume, and one for the tick")

        let served = rig.spool.servedBytes
        let cycles = 20
        for cycle in 0..<cycles {
            let pausing = cycle % 2
            await rig[pausing].pauseSpool()
            ids.append(try await rig.send(1 - pausing, pausing, "cycle \(cycle)"))
            await rig.run(1)
            await rig[pausing].resumeSpool()
            await rig.run(2)
        }
        await rig.run(12)
        #expect(ids.allSatisfy { rig.holds(0, $0) || rig.holds(1, $0) })
        #expect(rig.pairIds(0) == rig.pairIds(1), "both custodies hold the same live ids")
        let folds = await rig.folds()
        #expect(folds.alice == folds.spool && folds.bob == folds.spool)
        let unique = rig.spool.scopes.values.reduce(0) { $0 + $1.live.reduce(0) { $0 + $1.data.count } }
        let largest = rig.spool.scopes.values.flatMap(\.live).map(\.data.count).max() ?? 0
        #expect(rig.spool.servedBytes - served <= unique + cycles * largest, "the unique bytes and a pull a cycle")
        for index in 0..<2 {
            let rows = rig.lab.radio.thread(index, with: 1 - index)
            #expect(Set(rows).count == rows.count, "nothing delivered twice")
        }
    }

    /// Test 7: a flood of junk keeps one record in flight a connection, defers the reader, and a send posted mid-flood goes.
    /// Test 7, with the drop bound: the flood defers the reader, then ends each connection once it dropped more than the
    /// window keeps, as an unreached session whose redial follows the backoff.
    @Test func aFloodOfJunkKeepsOneRecordInFlightAndDefersTheReader() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        let started = rig.clock.monotonicMilliseconds()
        rig.net.flood([0xA0, 0x00, 0x01], count: 10_000)
        await rig[0].process(.state(.off))
        let radio = await rig[0].radioState
        #expect(rig.net.queued > 0 && radio == .off, "a radio event mid-flood is handled before the flood drains")
        let toBob = try await rig.send(0, 1, "mid flood")
        var redials: [Int64?] = [nil, nil]
        for _ in 0..<200 where rig.net.queued > 0 {
            await rig.rawAdvance(SpoolInboundBudget.refillMilliseconds)
            for index in 0..<2 where redials[index] == nil {
                let status = await rig[index].spoolStatus.relays.first
                if status?.counts["dropFaults"] ?? 0 > 0 {
                    #expect(status?.failures == 1, "the drop fault is an unreached session")
                    redials[index] = await rig[index].spoolRedial(SpoolMeshRig.relay)
                }
            }
        }
        for redial in redials {
            let wait = try #require(redial, "each connection ended at the drop bound") - rig.clock.monotonicMilliseconds()
            #expect(wait >= SpoolBackoff.waitMilliseconds(failures: 1) - SpoolInboundBudget.refillMilliseconds, "on the curve")
        }
        #expect(rig.net.queued == 0, "the flood drained")
        await rig.run(6)
        #expect(rig.holds(1, toBob), "the send posted mid-flood went once the readers caught up")
        #expect(rig.net.overlappingReceives == 0, "one record in flight a connection")
        var deferred = 0
        var dropped = 0
        for index in 0..<2 {
            let counts = await rig[index].spoolStatus.relays.first?.counts ?? [:]
            deferred += counts["inboundDeferred"] ?? 0
            dropped += counts["dropped.undecodable"] ?? 0
        }
        #expect(deferred >= 2, "the reader waited for the budget")
        #expect(dropped == rig.net.floodDelivered && dropped > 0, "every junk record read was counted")
        #expect(dropped <= 2 * (SpoolDropWindow.maxRecords + 1), "no connection read past the drop bound")
        let elapsed = rig.clock.monotonicMilliseconds() - started
        for index in 0..<2 {
            SpoolLogOracle.check(rig.allLines(index), nodes: Self.nodes, elapsed: elapsed)
        }
    }

    /// Test 8's `neverReads` and `forgetsAfterPush`.
    @Test func aSpoolThatNeverReadsStallsAndOneThatForgetsCostsAtMostTheBudget() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        rig.net.neverReads = true
        _ = try await rig.send(0, 1, "into the void")
        await rig.run(8)
        let counts = await rig[0].spoolStatus.relays.first?.counts ?? [:]
        #expect(counts["writeStalls"] ?? 0 >= 1, "the stall closed the session")
        #expect((counts["queuedBytes"] ?? 0) <= SpoolLink.maxQueuedBytes)
        #expect(await rig[0].spoolStatus.relays.first?.failures ?? 0 >= 1, "as unreached")
        SpoolLogOracle.check(rig.allLines(0), nodes: Self.nodes)
    }

    /// Test 10: a block with a live relay and a failing block store: no `sub`, `pull` or stamp for the peer's scope in its
    /// turn, nor after.
    @Test func aBlockWithALiveRelayStopsThePeersScopeInItsTurn() async throws {
        let failable = FailableStores()
        let rig = try await SpoolMeshRig.make(bobStores: failable.stores)
        await rig.run(4)
        let scope = try #require(rig.spoolScope())
        #expect(await rig[1].spoolScopes == [scope])
        failable.blocks.failsReads = true
        rig.net.forgetSent()
        await rig[1].block(Self.alice.nodeId)
        #expect(await rig[1].spoolScopes.isEmpty, "the block's turn dropped the scope")
        _ = try await rig.send(0, 1, "after the block")
        await rig.run(14)
        let named = rig.net.sent(by: 1).filter { record in
            switch record {
            case .sub(let sub):
                sub.subs.contains { $0.scope == scope.bytes }
            case .pull(let pull):
                pull.scope == scope.bytes
            case .list(let list):
                list.scope == scope.bytes
            case .push(let push):
                push.scope == scope.bytes
            default:
                false
            }
        }
        #expect(named.isEmpty, "nothing for the blocked peer's scope")
        #expect(await rig[1].spool.miner.requests.isEmpty)
    }

    /// Tests 9 and 13: refused dials with a relay address that carries a token and user info's lookalike, relay text full of
    /// what must never be logged, and the log oracle on every line.
    @Test func theLogNamesNoAddressNoScopeAndNoRelayText() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        // A spool's own text: an address with user info and a token, and 64 hex characters, in a code and a message. A close
        // frame's reason has no place in `SpoolSocketEnd`, so the socket drops it before the plane.
        let relayText = "wss://u@a.b/?k=" + String(repeating: "ab", count: 32)
        let err = SpoolErr(code: relayText, message: relayText)
        rig.net.withSpool { spool in
            for connection in spool.sockets.keys {
                spool.emit(err, to: connection)
                spool.inject([0xFF, 0x00], into: connection)
            }
        }
        rig.net.refuse([
            SpoolDialFailure(.http, status: 503, retryAfter: SpoolRetryAfter(header: Array("+5".utf8))),
            SpoolDialFailure(.tls),
        ])
        rig.net.dropAll()
        await rig.run(30, every: SpoolBackoff.maxRetryAfterMilliseconds)
        let url = try #require(
            AcceptedSpoolURL("wss://lab.spool.test/spool/v1?k=" + String(repeating: "cd", count: 32), allowCleartext: false))
        #expect(await rig[0].addSpoolRelay(SpoolRelayHandle(number: 2), url: url))
        await rig.run(6, every: SpoolBackoff.maxRetryAfterMilliseconds)
        for index in 0..<2 {
            let lines = rig.spoolLines(index)
            #expect(!lines.isEmpty, "the spool logged its counts")
            SpoolLogOracle.check(rig.allLines(index), nodes: Self.nodes)
        }
    }
}

/// What a captured log must hold to (ADR 2026-11.adrq, P4b1): no address, token, user info or 64-hex run on any line; no
/// node id on a spool line; and, given how long the log ran, at most one spool line per kind per interval.
enum SpoolLogOracle {
    static func check(
        _ lines: [String], nodes: [String], elapsed: Int64? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for line in lines {
            let head = String(line.prefix(60))
            #expect(!hasHexRun(line, SpoolRecordLayer.idByteCount * 2), "no 64-hex run: \(head)", sourceLocation: sourceLocation)
            #expect(!line.contains("wss://") && !line.contains("ws://"), "no address: \(head)", sourceLocation: sourceLocation)
            #expect(!line.contains("k="), "no token: \(head)", sourceLocation: sourceLocation)
            #expect(!hasUserInfo(line), "no user info: \(head)", sourceLocation: sourceLocation)
            if line.contains("spool") {
                #expect(!nodes.contains { line.contains($0) }, "no node id on a spool line: \(head)", sourceLocation: sourceLocation)
            }
        }
        guard let elapsed else {
            return
        }
        var kinds: [String: Int] = [:]
        for line in lines where line.contains("spool") && line.contains(":") {
            kinds[String(line.prefix { $0 != ":" }), default: 0] += 1
        }
        let allowed = Int(elapsed / SpoolLogBook.intervalMilliseconds) + 1
        for (kind, count) in kinds {
            #expect(count <= allowed, "\(kind): \(count) lines in \(elapsed) ms", sourceLocation: sourceLocation)
        }
    }

    private static func hasHexRun(_ line: String, _ length: Int) -> Bool {
        var run = 0
        for scalar in line.unicodeScalars {
            run = scalar.properties.isASCIIHexDigit ? run + 1 : 0
            if run >= length {
                return true
            }
        }
        return false
    }

    /// Whether an `@` follows a `://` before the authority ends.
    private static func hasUserInfo(_ line: String) -> Bool {
        let parts = line.split(separator: "://", omittingEmptySubsequences: false).dropFirst()
        return parts.contains { part in part.prefix { $0 != "/" && $0 != " " && $0 != "?" }.contains("@") }
    }
}
