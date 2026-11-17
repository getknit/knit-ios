import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Stamps searched for once, outside the tests, for scopes of one repeated byte on ``day``: the smallest counter at
/// the bits named, and the bits it actually has.
enum MinerVector {
    static let day: Int64 = 20_000
    /// Scope `0x07…`: the first 24-bit stamp.
    static let deep = (scope: UInt8(7), counter: Int64(51_850_472), bits: 24)
    /// Scope `0x08…`: the first 20-bit stamp.
    static let twenty = (scope: UInt8(8), counter: Int64(3_357_486), bits: 20)
    /// Scope `0x09…`: the first 16-bit stamp, which has 17.
    static let sixteen = (scope: UInt8(9), counter: Int64(76_166), bits: 17)
}

/// A miner over a table of `scopes`, each a scope of one repeated byte shared with the peer of the same byte, unpaused.
struct MinerBench {
    var miner = SpoolMiner()
    var now = SpoolNow(monotonic: 0, wall: MinerVector.day * SpoolPow.dayMilliseconds + 3_600_000)
    var nextSerial: Int64 = 1
    var answers: [SpoolMiner.Answer] = []
    var asked: [Int64: SpoolMiningRequest] = [:]

    init(_ scopes: [UInt8], peers: [UInt8]? = nil) {
        adopt(scopes, peers: peers)
        record(miner.resume(now: now))
    }

    mutating func adopt(_ scopes: [UInt8], peers: [UInt8]? = nil) {
        let owners = peers ?? scopes
        miner.adopt(zip(scopes, owners).compactMap { scope, peer in Self.scope(scope, peer: peer) })
    }

    static func id(_ byte: UInt8) -> SpoolID {
        guard let id = SpoolID([UInt8](repeating: byte, count: 32)) else {
            preconditionFailure("32 bytes")
        }
        return id
    }

    static func peer(_ byte: UInt8) -> NodeId {
        guard let peer = NodeId(bytes: [UInt8](repeating: byte, count: NodeId.byteCount)) else {
            preconditionFailure("a node id's bytes")
        }
        return peer
    }

    static func scope(_ byte: UInt8, peer: UInt8) -> SpoolScope? {
        let filled = [UInt8](repeating: byte, count: 32)
        return ScopeKeys(id: filled, sealKey: filled, nonceKey: filled).flatMap { keys in
            SpoolScope.of(keys, peer: Self.peer(peer), retiring: false, retiringUntil: nil)
        }
    }

    /// A request for `scope` at `bits` from `relay`, under the next serial.
    mutating func request(_ scope: UInt8, bits: Int, relay: Int = 1, day: Int64 = MinerVector.day) -> SpoolMiningRequest {
        defer { nextSerial += 1 }
        return SpoolMiningRequest(
            serial: nextSerial, relay: SpoolRelayHandle(number: relay), scope: Self.id(scope), day: day, bits: bits)
    }

    /// Asks `requests` in one batch.
    mutating func ask(_ requests: [SpoolMiningRequest]) {
        for request in requests {
            asked[request.serial] = request
        }
        record(miner.take(requests.map(SpoolPlane.Mining.mine), now: now))
    }

    mutating func cancel(_ request: SpoolMiningRequest) {
        asked[request.serial] = nil
        record(miner.take([.cancel(request)], now: now))
    }

    /// Ends the running job with `search`. Answers the job.
    @discardableResult
    mutating func end(_ search: SpoolPow.Search) -> SpoolMinerJob? {
        guard let job = miner.running?.job else {
            return nil
        }
        record(miner.ended(run: job.run, search, now: now))
        return job
    }

    mutating func advance(_ milliseconds: Int64) {
        now = SpoolNow(monotonic: now.monotonic + milliseconds, wall: now.wall + milliseconds)
    }

    /// Every answer is for a request asked and not cancelled, and only once; every found one is a stamp for it.
    mutating func record(_ given: [SpoolMiner.Answer]) {
        for answer in given {
            #expect(asked.removeValue(forKey: answer.request.serial) == answer.request, "one answer per asked serial")
            if case .found(let counter, let bits) = answer.answer {
                let request = answer.request
                #expect(SpoolPow.verify(scopeId: request.scope.bytes, day: request.day, n: counter, bits: request.bits))
                #expect(bits >= request.bits)
            }
        }
        answers += given
    }

    func answer(_ request: SpoolMiningRequest) -> SpoolStampAnswer? {
        answers.first { $0.request == request }?.answer
    }

    mutating func starts() -> [SpoolMinerJob] {
        miner.takeActions().compactMap { action in if case .start(let job) = action { job } else { nil } }
    }
}
