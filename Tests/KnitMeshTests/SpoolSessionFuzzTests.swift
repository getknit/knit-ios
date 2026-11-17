import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@_spi(Fuzz) @testable import KnitMesh

/// `FuzzSpoolSession`'s seam run over scripted and seeded inputs, so the harness and its invariants run on every test pass
/// (ADR 2026-11.adrq, P4b1); `scripts/fuzz.sh` runs it under libFuzzer.
@Suite struct SpoolSessionFuzzTests {
    private static func record(_ bytes: [UInt8]) -> [UInt8] {
        [0, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    private static func tick(_ clock: Int64) -> [UInt8] {
        [1] + withUnsafeBytes(of: clock.bigEndian, Array.init)
    }

    private static func scope(_ index: UInt8) -> [UInt8] {
        [UInt8](repeating: index, count: 32)
    }

    /// A script that greets, subscribes every scope, anchors them, lists, pulls, pushes, asks a stamp, answers it with and
    /// without a session, closes and reopens, at clocks across the whole `Int64` range, and plays the miner's runner through
    /// a find, a run out, a stop and a pause.
    static var scripted: [UInt8] {
        let hello = SpoolHello(version: 1, limits: FakeSpool.defaultLimits, powBits: 8).encoded
        var script = record(hello) + [2, 4]
        for index in UInt8(0)..<2 {
            let digest = SpoolDigest(
                scope: scope(index), digest: [0, 0, 0, 0, 0, 0, 0, index + 1], count: 1, full: false, bounds: ScopeFrames.bounds)
            script += record(digest.encoded)
        }
        // A stamp asked and answered, then another asked and cancelled when its scope leaves the table.
        script += record(SpoolErr(code: SpoolErrorCode.pow, request: 1, scope: scope(3)).encoded) + [7, 0]
        script += record(SpoolErr(code: SpoolErrorCode.pow, request: 1, scope: scope(2)).encoded) + [10, 0]
        script += tick(10_000) + [8, 1] + [8, 0]
        let blob = [UInt8](repeating: 9, count: 40)
        let blobId = ScopeCrypto.blobId(of: blob)
        script += record(SpoolList(request: 2, scope: scope(0), blobIds: [blobId]).encoded)
        script += record(SpoolBlob(scope: scope(0), blobId: blobId, data: blob).encoded)
        script += record(SpoolEvent(scope: scope(1), blobId: blobId, data: blob).encoded)
        script += record(SpoolOk(request: 3).encoded)
        script += [3, 1, 2, 7] + [4, 40] + blob + [3, 0, 3, 5]
        script += [9, 0, 9, 1, 7, 0, 7, 1, 5, 6] + record(hello) + [2, 4]
        script += tick(.max) + tick(.min) + tick(-1) + [8, 0, 7, 1]
        // P4b2's miner: a search stopped by a pause, resumed, then run out; another found; another stopped by a cancel.
        script += tick(20_000) + record(SpoolErr(code: SpoolErrorCode.pow, request: 1, scope: scope(1)).encoded)
        script += [11, 7, 2, 1, 11, 7, 1]
        script += record(SpoolErr(code: SpoolErrorCode.pow, request: 1, scope: scope(0)).encoded) + [7, 0]
        return script
    }

    /// The runner stops a search at a check, and the miner runs it again from there until it finds the stamp.
    @Test func aStoppedSearchResumesAndFinds() {
        let hello = SpoolHello(version: 1, limits: FakeSpool.defaultLimits, powBits: 8).encoded
        let refused = SpoolErr(code: SpoolErrorCode.pow, request: 1, scope: Self.scope(3)).encoded
        let script = Self.record(hello) + [2, 4] + Self.record(refused) + [7, 2, 0, 7, 0]
        #expect(SpoolSessionFuzz.run(script) == 5)
    }

    @Test func aScriptedSessionKeepsEveryInvariant() {
        #expect(SpoolSessionFuzz.run(Self.scripted) > 10, "the script played")
        #expect(SpoolSessionFuzz.run(Array("99999999999999999999".utf8) + Self.scripted) > 10)
        #expect(SpoolSessionFuzz.run([]) == 0)
    }

    /// A frame of the pair's own, served live and pulled, reaches the heal as a candidate and is settled every way.
    @Test func candidatesAreSettledEveryWay() {
        let keys = ScopeFixture.keys()
        let scope = keys.id
        let hello = SpoolHello(version: 1, limits: FakeSpool.defaultLimits).encoded
        let digest = SpoolDigest(scope: scope, digest: [0, 0, 0, 0, 0, 0, 0, 9], count: 1, full: false, bounds: ScopeFrames.bounds)
        var script = Self.record(hello) + [2, 1] + Self.record(digest.encoded) + Self.tick(ScopeFixture.wall)
        for number in 1...5 {
            let sealed = ScopeFixture.sealed(ScopeFixture.dm(number))
            script += Self.record(SpoolEvent(scope: scope, blobId: sealed.id.bytes, data: sealed.blob).encoded) + [UInt8(number)]
        }
        script += [10, 0, 7, 0, 5]
        #expect(SpoolSessionFuzz.run(script, me: ScopeFixture.bob.nodeId, peer: ScopeFixture.alice.nodeId, keys: [keys]) > 5)
        #expect(SpoolSessionFuzz.run(script, me: ScopeFixture.bob.nodeId, peer: ScopeFixture.alice.nodeId, keys: []) == 0)
        #expect(SpoolSessionFuzz.run([0]) == 1 && SpoolSessionFuzz.run([1]) == 1 && SpoolSessionFuzz.run([7, 1]) == 1)
    }

    @Test func seededNoiseKeepsEveryInvariant() {
        var generator = SeededGenerator(seed: 77)
        let base = Self.scripted
        for _ in 0..<300 {
            var script = base
            for _ in 0..<16 {
                let at = Int(generator.next(upperBound: UInt64(script.count)))
                script[at] = UInt8(truncatingIfNeeded: generator.next())
            }
            SpoolSessionFuzz.run(script)
            SpoolSessionFuzz.run((0..<256).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
        }
    }
}
