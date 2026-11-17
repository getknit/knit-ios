import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What the daemon suite holds on every run, with or without a daemon (ADR 2026-11.adrq, P5): it dials this machine's
/// loopback alone, and no `ws://` address the plane takes carries a token.
@Suite struct SpoolDaemonAddressTests {
    @Test func theSuiteRefusesADaemonOffThisMachinesLoopback() {
        #expect(
            SpoolDaemon.refused.isEmpty, "\(SpoolDaemon.refused) name a daemon off this machine's loopback; the suite dials 127.0.0.1 alone"
        )
        for text in [
            "ws://192.168.1.5:9470/spool/v1", "ws://127.0.0.2:9470/spool/v1", "wss://127.0.0.1:9470/spool/v1", "ws://127.0.0.1/spool/v1",
        ] {
            #expect(SpoolTestSockets.Target(text) == nil, "\(text) refused")
        }
        #expect(SpoolTestSockets.Target("ws://127.0.0.1:9470/spool/v1?k=t")?.path == "/spool/v1?k=t")
    }

    /// The plane takes no `ws://` address with a `k=` token in any build, so the private relay's case dials the test socket
    /// raw, outside the factory: a token waits for a TLS relay.
    @Test func thePlaneTakesNoTokenOverCleartext() {
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1?k=x", allowCleartext: true) == nil)
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1", allowCleartext: true) != nil)
    }
}

/// The plane against the reference daemon (ADR 2026-11.adrq, P5), `scripts/check.sh spool` alone: two ``Mesh``es with no
/// radio link between them, over the test socket, at the daemon's `SPOOL_POW_BITS=8`. Skipped unless `KNIT_SPOOL_URL` names a
/// daemon on this machine's loopback; the private relay, the second relay and the 24-bit case each need their own variable.
@Suite(
    .serialized, .timeLimit(.minutes(10)),
    .enabled(if: SpoolDaemon.url != nil, "KNIT_SPOOL_URL names no daemon on this machine's loopback; scripts/check.sh spool sets it")
)
struct SpoolDaemonTests {
    private static var url: String { SpoolDaemon.url ?? "" }

    /// Text and ✓✓ both ways through the daemon, every fold agreeing, and the daemon's proof of work met: one search per
    /// scope, day and bits on each side.
    @Test func textAndTheDoubleTickGoBothWaysAtTheDaemonsProofOfWork() async throws {
        let rig = try await SpoolDaemonRig.make(relays: [Self.url])
        await rig.run(4)
        let toBob = try await rig.send(0, 1, "over the daemon")
        let toAlice = try await rig.send(1, 0, "and back")
        let delivered = await rig.until {
            rig.holds(1, toBob) && rig.holds(0, toAlice) && rig.lab[0].stores.messages.message(toBob)?.delivered == true
                && rig.lab[1].stores.messages.message(toAlice)?.delivered == true
        }
        #expect(delivered, "both delivered, and both double ticks came back")
        let scope = try #require(await rig.scopes(0).first?.id)
        #expect(await rig.scopes(1).first?.id == scope, "both derive the one scope")
        await rig.run(2)
        let folds = (await rig[0].spoolFold(scope, on: SpoolDaemonRig.relay), await rig[1].spoolFold(scope, on: SpoolDaemonRig.relay))
        #expect(folds.0 != nil && folds.0 == folds.1, "both folds agree")
        for index in 0..<2 {
            let status = await rig[index].spoolStatus
            #expect(status.counts["minerFound"] ?? 0 >= 1, "the daemon's stamp was mined: \(status.counts)")
            #expect(status.counts["minerRuns"] == status.counts["minerFound"], "one search per value: \(status.counts)")
            #expect(status.relays.first?.counts["dropFaults"] == 0 && status.relays.first?.state == "open", "\(status)")
        }
    }

    /// A DM that reaches Bob through the daemon goes onto his radio link to a third node, which the relay never reaches.
    @Test func aDMTheDaemonCarriesIsBridgedOntoARadioLink() async throws {
        let rig = try await SpoolDaemonRig.make(relays: [Self.url])
        await rig.run(4)
        let channel = ChannelID(50)
        let carol = SpoolEngineLabTests.carol
        await rig[1].process(.accepted(channel))
        let hello = LinkRecord(.hello, payload: Hello(nodeId: carol.nodeId.string, capabilities: 0xFFF).payload).encoded ?? []
        await rig[1].process(.received(channel, hello))
        #expect(await rig[1].neighbors.map(\.nodeId) == [carol.nodeId], "carol is linked to bob by radio")
        let toBob = try await rig.send(0, 1, "bridge me")
        #expect(await rig.until { rig.holds(1, toBob) }, "bob has it from the daemon")
        // The router schedules a relay after its flood delay, on the mesh's clock.
        let bridged = await rig.until(steps: 6) {
            rig.radios[1].frames(on: channel).contains { (try? RelayEnvelope(decoding: $0.signed).id) == toBob }
        }
        #expect(bridged, "bob put it on carol's link")
        #expect(await rig[1].spoolStatus.counts["bridged"] ?? 0 >= 1)
    }

    /// The peer's reset through the daemon, pushed into the old scope as Android pushes it: Bob adopts it, the old scope
    /// retires, the old era's DM opens, and his answer lands under the new scope.
    @Test func aPeersResetThroughTheDaemonIsAdopted() async throws {
        let rig = try await SpoolDaemonRig.make(relays: [Self.url])
        await rig.run(4)
        let old = try #require(await rig.scopes(1).first)
        await rig[0].pauseSpool()
        let oldEra = try await rig.send(0, 1, "from the old era")
        await rig.advance(SpoolEngineLabTests.minute)
        let wall = rig.clock.wallMilliseconds()
        let before = Set(rig.lab[0].stores.custody.liveIds(now: wall))
        guard case .sent = await rig[0].sendRatchetReset(to: SpoolEngineLabTests.bob.nodeId) else {
            Issue.record("alice's reset went out")
            return
        }
        let resetId = try #require(rig.lab[0].stores.custody.liveIds(now: wall).first { !before.contains($0) })
        let injector = try await SpoolDaemonLine.open(Self.url)
        try await injector.subscribe(old.id.bytes, wall: wall)
        for id in [resetId, oldEra] {
            let carried = try #require(rig.lab[0].stores.custody.frame(id, now: wall))
            let sealed = try #require(ScopeFrames.seal(carried, into: old))
            #expect(try await injector.push(sealed.blob, into: old.id.bytes), "the daemon took the old era's frame")
        }
        let adopted = await rig.until {
            let scopes = await rig.scopes(1)
            return scopes.count == 2 && scopes.contains { $0.id == old.id && $0.retiring } && rig.holds(1, oldEra)
        }
        #expect(adopted, "the old scope retires and the old era's DM opens")
        let live = try #require(await rig.scopes(1).first { !$0.retiring })
        #expect(live.id != old.id, "the new root's scope is live")
        let answered = await rig.until(steps: 20) {
            guard let reader = try? await SpoolDaemonLine.open(Self.url),
                let digest = try? await reader.subscribe(live.id.bytes, wall: rig.clock.wallMilliseconds())
            else {
                return false
            }
            return digest.count >= 1
        }
        #expect(answered, "bob's answer lands under the new scope")
        #expect(rig.lab[1].engine.ratchet.floors(for: SpoolEngineLabTests.alice.nodeId).undecryptableIds == 0, "no era evidence")
    }

    /// The Kotlin vectors' blob, pushed raw, comes back byte for byte and opens here; a Swift seal comes back byte for byte.
    @Test func aKotlinSealOpensHereAndASwiftSealComesBackByteForByte() async throws {
        let id = SpoolVectors.bytes("Derivations", "dmScopeId")
        let sealKey = SpoolVectors.bytes("Derivations", "dmSealKey")
        let keys = try #require(ScopeKeys(id: id, sealKey: sealKey, nonceKey: SpoolVectors.bytes("Derivations", "dmNonceKey")))
        let kotlin = SpoolVectors.bytes("Seal", "blob")
        let swift = try #require(
            ScopeCrypto.seal(keys, sig: SpoolVectors.fixture(64, seed: 31), signed: SpoolVectors.fixture(200, seed: 32)))
        let line = try await SpoolDaemonLine.open(Self.url)
        try await line.subscribe(keys.id, wall: Int64(Date().timeIntervalSince1970 * 1000))
        for blob in [kotlin, swift.blob] {
            _ = try await line.push(blob, into: keys.id)
        }
        let ids = [SpoolVectors.bytes("Seal", "blobId"), swift.blobId]
        #expect(Set(try await line.list(keys.id)).isSuperset(of: ids), "the daemon lists both")
        let served = try await line.pull(ids, from: keys.id)
        #expect(served[ids[0]] == kotlin && served[ids[1]] == swift.blob, "both come back byte for byte")
        let kotlinServed = try #require(served[ids[0]])
        let opened = try #require(ScopeCrypto.open(keys, blobId: ids[0], blob: kotlinServed))
        #expect(opened.sig == SpoolVectors.bytes("Inputs", "sig") && opened.signed == SpoolVectors.bytes("Inputs", "signed"))
    }

    /// A private relay closes 4001 on a socket without its token and says `hello` on one with it. Dialled raw: the plane's
    /// `ws://` addresses carry no token.
    @Test(.enabled(if: SpoolDaemon.privateURL != nil && SpoolDaemon.token != nil, "KNIT_SPOOL_PRIVATE_URL and KNIT_SPOOL_TOKEN unset"))
    func aPrivateRelayClosesWithoutItsTokenAndSaysHelloWithIt() async throws {
        let base = try #require(SpoolDaemon.privateURL)
        guard case .opened(let refused) = await SpoolTestSockets.dial(raw: base) else {
            Issue.record("the upgrade was refused")
            return
        }
        #expect(await refused.receive() == .closed(SpoolSocketEnd(.closed, code: SpoolCloseCode.auth)))
        let token = try #require(SpoolDaemon.token)
        guard case .opened(let admitted) = await SpoolTestSockets.dial(raw: base + "?k=" + token) else {
            Issue.record("the upgrade with the token was refused")
            return
        }
        defer { admitted.close(code: SpoolCloseCode.normal) }
        guard case .binary(let bytes) = await admitted.receive(), case .hello? = SpoolRecord(decoding: bytes) else {
            Issue.record("no hello")
            return
        }
    }

    /// Two daemons asked for the same scope: one search serves both relays, charged to one of them, each within its share.
    @Test(.enabled(if: SpoolDaemon.secondURL != nil, "KNIT_SPOOL_URL_2 unset"))
    func twoRelaysAskingTheSameScopesSpendWithinTheirShares() async throws {
        let rig = try await SpoolDaemonRig.make(relays: [Self.url, try #require(SpoolDaemon.secondURL)])
        await rig.run(6)
        let toBob = try await rig.send(0, 1, "over two relays")
        #expect(await rig.until { rig.holds(1, toBob) && rig.lab[0].stores.messages.message(toBob)?.delivered == true })
        for index in 0..<2 {
            let status = await rig[index].spoolStatus
            #expect(status.relays.count == 2 && status.relays.allSatisfy { $0.state == "open" }, "\(status)")
            #expect(status.counts["minerRuns"] == 1, "one search for the scope's value across both relays: \(status.counts)")
            let spent = await rig[index].spoolSpent
            #expect(spent.relays.allSatisfy { $0 <= SpoolMinerBudget.relayCap } && spent.engine <= SpoolMinerBudget.engineCap)
            #expect(spent.relays.reduce(0, +) == spent.engine, "each counter charged to one relay")
        }
    }
}

/// The opt-in heavy case of `scripts/check.sh spool` (ADR 2026-11.adrq, P4b2's owed check): a daemon at `SPOOL_POW_BITS=24`,
/// dialled only when `KNIT_SPOOL_HEAVY=1` and `KNIT_SPOOL_HEAVY_URL` names it.
@Suite(.timeLimit(.minutes(30)), .enabled(if: SpoolDaemon.heavyURL != nil, "KNIT_SPOOL_HEAVY=1 with KNIT_SPOOL_HEAVY_URL unset"))
struct SpoolDaemonHeavyTests {
    /// Opt-in (`KNIT_SPOOL_HEAVY=1`): six scopes at 24 bits. `status` shows at most one search per scope, day and bits, and at
    /// most 2^29 counters spent in 24 h.
    @Test func manyScopesAtTwentyFourBitsSearchOncePerValueWithinTheBudget() async throws {
        let peers = 6
        let rig = try await SpoolDaemonRig.make(relays: [try #require(SpoolDaemon.heavyURL)], peers: peers, online: [0])
        #expect(await rig.scopes(0).count == peers)
        let mined = await rig.until(steps: 2000) {
            await rig[0].spoolStatus.counts["minerFound"] ?? 0 >= peers
        }
        let status = await rig[0].spoolStatus
        #expect(mined, "every scope's stamp was found: \(status.counts)")
        #expect(status.counts["minerRuns"] ?? 0 <= peers, "at most one search per value: \(status.counts)")
        #expect(status.counts["minerSpent"] ?? 0 <= Int(SpoolMinerBudget.engineCap), "at most 2^29 counters: \(status.counts)")
    }
}

extension Mesh {
    /// The miner's spend in the window: each relay's and the engine's.
    var spoolSpent: (relays: [Int64], engine: Int64) {
        let now = engine.clock.monotonicMilliseconds()
        let budget = spool.miner.budget
        return (spool.relays.keys.sorted().map { budget.spent(relay: $0, now: now) }, budget.spent(now: now))
    }
}
