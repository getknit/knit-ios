import KnitCrypto
import KnitStore
import KnitWire

@testable import KnitMesh

/// A session and a heal driven record by record, with no spool: the test answers each request itself.
internal struct HealBench {
    var session: SpoolSession
    var heal: ScopeHeal
    var now = SpoolNow(monotonic: 0, wall: ScopeFixture.wall)
    var sent: [SpoolRecord] = []
    var candidates: [ScopeCandidate] = []

    init(
        limits: SpoolLimits? = FakeSpool.defaultLimits, scopes: [SpoolScope] = [ScopeFixture.scope(for: ScopeFixture.alice)],
        anchor: UInt64? = 7
    ) {
        session = SpoolSessionFixture.ready(SpoolSessionFixture.hello(limits: limits))
        heal = ScopeHeal(relay: SpoolRelayHandle(number: 1), me: ScopeFixture.alice.nodeId)
        heal.adopt(scopes)
        heal.handle(.connected, session: &session, now: now)
        flush()
        for scope in scopes {
            if let anchor {
                receive(SpoolSessionFixture.digest(scope.id, value: ScopeCrypto.digestBytes(anchor), count: 1))
            }
        }
    }

    mutating func receive(_ bytes: [UInt8]) {
        session.receive(bytes)
        flush()
    }

    mutating func flush() {
        var outputs = session.drain()
        while !outputs.isEmpty {
            flush(outputs)
            outputs = session.drain()
        }
    }

    private mutating func flush(_ outputs: [SpoolSessionOutput]) {
        for output in outputs {
            switch output {
            case .send(let bytes):
                if let record = SpoolRecord(decoding: bytes) {
                    sent.append(record)
                }
            case .event(let event):
                heal.handle(event, session: &session, now: now)
                for case .candidate(let candidate) in heal.drain() {
                    candidates.append(candidate)
                }
            case .close:
                break
            }
        }
    }

    mutating func round(_ frames: [TestFrame]) {
        heal.roundStarted(.frames(frames.map(ScopeFixture.carried)), session: &session, now: now)
        flush()
    }

    /// The last request of `kind` sent: its `q`.
    func last(_ kind: String) -> Int64? {
        sent.reversed().lazy.compactMap { record -> Int64? in
            switch (kind, record) {
            case ("list", .list(let list)):
                list.request
            case ("pull", .pull(let pull)):
                pull.request
            case ("push", .push(let push)):
                push.request
            default:
                nil
            }
        }.first
    }

    func pushedIds() -> [SpoolID] {
        sent.compactMap { record in
            guard case .push(let push) = record else {
                return nil
            }
            return SpoolID(push.blobId)
        }
    }

    func pulledIds() -> [SpoolID] {
        sent.flatMap { record -> [SpoolID] in
            guard case .pull(let pull) = record else {
                return []
            }
            return pull.blobIds.compactMap(SpoolID.init)
        }
    }

    func listing(_ request: Int64, live: [SpoolID], tombstones: [SpoolID] = []) -> [UInt8] {
        SpoolList(
            request: request,
            scope: ScopeFixture.scope(for: ScopeFixture.alice).id.bytes,
            blobIds: live.map(\.bytes),
            tombstones: tombstones.isEmpty ? nil : tombstones.map(\.bytes)
        ).encoded
    }
}
