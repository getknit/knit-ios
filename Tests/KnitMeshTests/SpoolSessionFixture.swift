import KnitWire

@testable import KnitMesh

/// Records and ids for the spool session's suites, and a ``SpoolLine`` that wires a session to a ``FakeSpool``.
enum SpoolSessionFixture {
    /// A 32-byte id whose bytes start at `seed`.
    static func id(_ seed: Int) -> SpoolID {
        guard let id = SpoolID((0..<32).map { UInt8(truncatingIfNeeded: $0 + seed) }) else {
            preconditionFailure("32 bytes are an id")
        }
        return id
    }

    /// An id that differs from every other `numbered` one in its first two bytes, for more than 256 of them.
    static func numbered(_ number: Int) -> SpoolID {
        guard
            let id = SpoolID(
                [0xEE, UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number)] + [UInt8](repeating: 0, count: 29))
        else {
            preconditionFailure("32 bytes are an id")
        }
        return id
    }

    static let scope = id(0)
    static let other = id(1)

    /// Small limits with a two-id pull and a 4 KiB record, as `SpoolConnectionTest.serverHello` sends.
    static let smallLimits = SpoolLimits(maxBlob: 64, maxRecord: 4096, maxScopes: 8, maxPull: 2, maxFramesCap: 10, maxTtlMs: 1)

    /// The limits a hostile spool would send (`greedyLimits`).
    static let greedyLimits = SpoolLimits(
        maxBlob: 1 << 20, maxRecord: Int(Int32.max), maxScopes: 8, maxPull: Int(Int32.max), maxFramesCap: 10, maxTtlMs: 1)

    /// The bounds this build declares for a DM scope (`ScopeRegistry.DEFAULT_BOUNDS`).
    static let bounds = ScopeBounds(maxFrames: 400, ttlMs: 172_800_000, maxBlob: SpoolRecordLayer.defaultMaxBlob)

    static func hello(version: Int = 1, minimum: Int? = 1, limits: SpoolLimits? = smallLimits, powBits: Int? = 0) -> [UInt8] {
        SpoolHello(version: version, minimum: minimum, limits: limits, powBits: powBits).encoded
    }

    /// A session that has read `hello` and drained its reply.
    static func ready(_ hello: [UInt8] = hello(), now: Int64 = 0) -> SpoolSession {
        var session = SpoolSession(openedAt: now)
        session.receive(hello)
        _ = session.drain()
        return session
    }

    /// A ready session with `scopes` subscribed, the `sub` drained.
    /// A ready session with `scopes` subscribed and the `sub` drained. The `sub` is taken as answered without a digest, so
    /// a test can set its own anchor and run its own clock without the `sub` lapsing; `SpoolSessionSubTests` covers the
    /// `sub`'s own answers.
    static func subscribed(_ scopes: [SpoolID] = [scope], hello: [UInt8] = hello(), now: Int64 = 0) -> SpoolSession {
        var session = ready(hello, now: now)
        _ = session.subscribe(scopes.map { ScopeSub(scope: $0.bytes, bounds: bounds) }, now: now)
        session.subsInFlight.removeAll()
        _ = session.drain()
        return session
    }

    static func digest(_ scope: SpoolID = scope, value: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 7], count: Int = 1) -> [UInt8] {
        SpoolDigest(scope: scope.bytes, digest: value, count: count, full: false, bounds: bounds).encoded
    }

    static func blob(_ blobId: SpoolID, scope: SpoolID = scope, data: [UInt8] = [7]) -> [UInt8] {
        SpoolBlob(scope: scope.bytes, blobId: blobId.bytes, data: data).encoded
    }

    static func event(_ blobId: SpoolID, scope: SpoolID = scope, data: [UInt8] = [7]) -> [UInt8] {
        SpoolEvent(scope: scope.bytes, blobId: blobId.bytes, data: data).encoded
    }

    static func ok(_ request: Int64, missing: [SpoolID]? = nil) -> [UInt8] {
        SpoolOk(request: request, missing: missing?.map(\.bytes)).encoded
    }

    static func listing(_ request: Int64, scope: SpoolID = scope, live: [[UInt8]] = [id(5).bytes]) -> [UInt8] {
        SpoolList(request: request, scope: scope.bytes, blobIds: live).encoded
    }

    static func err(
        _ code: String, request: Int64? = nil, scope: [UInt8]? = nil, message: String? = nil, retryMs: Int64? = nil
    ) -> [UInt8] {
        SpoolErr(code: code, request: request, scope: scope, message: message, retryMs: retryMs).encoded
    }
}

extension [SpoolSessionOutput] {
    /// The events, in order.
    var events: [SpoolSessionEvent] {
        compactMap { output in
            guard case .event(let event) = output else {
                return nil
            }
            return event
        }
    }

    /// The records sent, decoded.
    var records: [SpoolRecord] {
        compactMap { output in
            guard case .send(let bytes) = output else {
                return nil
            }
            return SpoolRecord(decoding: bytes)
        }
    }

    /// The close codes asked for.
    var closes: [Int] {
        compactMap { output in
            guard case .close(let code) = output else {
                return nil
            }
            return code
        }
    }
}

/// A session wired to one connection of a ``FakeSpool``: ``pump()`` carries each side's records to the other until both
/// are quiet, keeping every event the session raised.
struct SpoolLine {
    var session: SpoolSession
    let spool: FakeSpool
    let connection: FakeSpool.Connection
    var events: [SpoolSessionEvent] = []
    var closes: [Int] = []

    init(_ spool: FakeSpool, now: Int64 = 0) {
        self.spool = spool
        connection = spool.connect()
        session = SpoolSession(openedAt: now)
        pump()
    }

    mutating func pump() {
        var quiet = false
        while !quiet {
            quiet = true
            for output in session.drain() {
                quiet = false
                switch output {
                case .send(let bytes):
                    spool.receive(bytes, from: connection)
                case .close(let code):
                    closes.append(code)
                    spool.drop(connection)
                case .event(let event):
                    events.append(event)
                }
            }
            for outgoing in spool.take(connection) {
                quiet = false
                switch outgoing {
                case .record(let bytes):
                    session.receive(bytes)
                case .close:
                    session.socketClosed()
                }
            }
        }
    }

    /// Takes the events raised since the last call.
    mutating func takeEvents() -> [SpoolSessionEvent] {
        defer { events.removeAll() }
        return events
    }
}
