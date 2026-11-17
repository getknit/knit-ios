public import KnitCrypto
public import KnitWire

/// The seam `FuzzSpoolSession` drives (ADR 2026-11.adrq, P4b1): two relays' ``SpoolSession`` and ``ScopeHeal`` on one table,
/// played by a script of arbitrary bytes at arbitrary `Int64` clocks. Every record reaches both connections, and the
/// harness's own `sub`, `list`, `pull` and `push` go on the first; closes, stamp searches and every output are carried back
/// into the heals as the plane carries them, and every ask goes through one ``SpoolMiner`` (P4b2), so the two relays share
/// its values, whose runner the script plays: a search that finds within one check, one that runs out, one stopped at a
/// check, and pauses and resumes. It checks after every step:
/// - nothing traps, and a `Retry-After` read from the script's head is no floor or one inside 0…60 s;
/// - a scope's claims stay at most ``SpoolSession/maxClaimsPerScope`` plus the blobs in flight;
/// - one step's outputs stay bounded;
/// - every search in `mining` was asked for and not yet answered or cancelled, so `mining[scope]` is cleared only by its own
///   serial's answer or the heal's own cancel (the invariant ``ScopeHeal/mining`` documents);
/// - every request the miner holds is one the heal waits on, and each ends exactly once: the miner answers only a serial
///   asked and not cancelled, and the heal takes every answer;
/// - every found answer, from a run or the cache, is a stamp for the request's scope, day and bits;
/// - the budget's engine, relay and peer records never pass their caps.
@_spi(Fuzz)
public enum SpoolSessionFuzz {
    /// The most outputs one step may drain: a record is at most 128 KiB, so a step's events are bounded by what it read.
    static let maxOutputsPerStep = SpoolRecordLayer.maxPinnedFrames + SpoolRecordLayer.maxPinnedFrames + Int(UInt8.max)

    /// Plays `script` over the harness's fixed members and four scopes of fixed keys, after reading its head as a
    /// `Retry-After` header, which is held to 0…60 s or is no floor. Answers how many steps it played.
    @discardableResult
    public static func run(_ script: [UInt8]) -> Int {
        let retry = SpoolRetryAfter(header: script.prefix(SpoolRetryAfter.keptBytes + SpoolRetryAfter.keptBytes)).milliseconds
        // A floor past its range.
        precondition(retry.map { (0...SpoolBackoff.maxRetryAfterMilliseconds).contains($0) } != false)
        let nodes = [Fixture.me, Fixture.peer].compactMap { NodeId(bytes: [UInt8](repeating: $0, count: NodeId.byteCount)) }
        let keys = (UInt8(0)..<Fixture.scopes).compactMap { index in
            ScopeKeys(id: Player.filled(index), sealKey: Player.filled(Fixture.seal), nonceKey: Player.filled(Fixture.nonce))
        }
        return zip(nodes.prefix(1), nodes.dropFirst()).reduce(0) { _, pair in run(script, me: pair.0, peer: pair.1, keys: keys) }
    }

    /// Plays `script` as `me`, sharing a scope of each of `keys` with `peer`; the last retires. A test passes keys a frame
    /// of its own seals under, so the heal's candidates and their settlements run too.
    @discardableResult
    public static func run(_ script: [UInt8], me: NodeId, peer: NodeId, keys: [ScopeKeys]) -> Int {
        let scopes = keys.enumerated().compactMap { index, key in
            let retiring = index == keys.count - 1
            return SpoolScope.of(key, peer: peer, retiring: retiring, retiringUntil: retiring ? Fixture.drainEnd : nil)
        }
        guard !scopes.isEmpty else {
            return 0
        }
        var player = Player(script, me: me, scopes: scopes)
        return player.play()
    }

    /// What a script's op byte asks, in byte order.
    private enum Step: CaseIterable {
        case receive
        case tick
        case subscribe
        case listAndPull
        case push
        case close
        case reopen
        case answer
        case round
        case outbound
        case readopt
        case pause
    }

    /// The fixed keys the harness's scopes and nodes are made of.
    private enum Fixture {
        static let idBytes = SpoolRecordLayer.idByteCount
        static let peer: UInt8 = 0x42
        static let me: UInt8 = 0x24
        static let seal: UInt8 = 0x51
        static let nonce: UInt8 = 0x52
        static let scopes: UInt8 = 4
        static let byteBits = 8
        static let maxPulled = 4
        /// When the retiring scope's drain ends, on the script's wall clock.
        static let drainEnd: Int64 = 1_000_000
        /// The runner's outcomes: found within a check, exhausted, stopped.
        static let outcomes: UInt8 = 3
        /// A stopped search's `tried` is a whole number of checks, 65,536 counters each.
        static let checkShift: Int64 = 16
        /// The relays sharing the table, and how far apart their serials start.
        static let relays = 2
        static let serialShift: Int64 = 40
    }
}

extension SpoolSessionFuzz {
    private struct Player {
        var bytes: ArraySlice<UInt8>
        /// Two relays carrying the same table, each its heal and its connection. Every record the script writes reaches
        /// both connections, so both heals ask the miner for the same values; the script's own requests go on the first.
        var sessions: [SpoolSession?] = [nil, nil]
        var heals: [ScopeHeal]
        /// The searches asked for and not yet answered or cancelled, by serial.
        var asked: [Int64: SpoolMiningRequest] = [:]
        var miner = SpoolMiner()
        /// The job the runner holds.
        var job: SpoolMinerJob?
        var clock: Int64 = 0
        let scopes: [SpoolScope]

        init(_ script: [UInt8], me: NodeId, scopes: [SpoolScope]) {
            bytes = ArraySlice(script)
            self.scopes = scopes
            heals = (1...Fixture.relays).map { number in
                var heal = ScopeHeal(relay: SpoolRelayHandle(number: number), me: me)
                // Serials per relay far apart, as the plane's one counter keeps them unique.
                heal.nextSerial = Int64(number) << Fixture.serialShift
                heal.adopt(scopes)
                return heal
            }
            miner.adopt(scopes)
        }

        var now: SpoolNow { SpoolNow(monotonic: clock, wall: clock) }

        mutating func play() -> Int {
            sessions = sessions.map { _ in SpoolSession(openedAt: clock) }
            deliver(miner.resume(now: now))
            var steps = 0
            while let op = bytes.popFirst() {
                step(op)
                carry()
                check()
                steps += 1
            }
            return steps
        }

        static func filled(_ byte: UInt8) -> [UInt8] {
            [UInt8](repeating: byte, count: Fixture.idBytes)
        }

        mutating func step(_ byte: UInt8) {
            switch Step.allCases[Int(byte) % Step.allCases.count] {
            case .receive:
                receive()
            case .tick:
                tick()
            case .subscribe:
                let subs = scopes.prefix(Int(take()) % (scopes.count + 1)).map { scope in
                    ScopeSub(scope: scope.id.bytes, bounds: ScopeFrames.bounds)
                }
                _ = sessions[0]?.subscribe(Array(subs), now: clock)
            case .listAndPull:
                let scope = pick()
                _ = sessions[0]?.list(scope, now: clock)
                let ids = (0..<Int(take()) % Fixture.maxPulled).compactMap { _ in SpoolID(Self.filled(take())) }
                _ = sessions[0]?.pull(scope, ids, now: clock)
            case .push:
                let data = Array(bytes.prefix(Int(take())))
                bytes = bytes.dropFirst(data.count)
                let scope = pick()
                if let blobId = SpoolID(ScopeCrypto.blobId(of: data)) {
                    _ = sessions[0]?.push(scope, blobId: blobId, data: data, pow: nil, now: clock)
                }
            case .close:
                close()
            case .reopen:
                sessions = sessions.map { $0 ?? SpoolSession(openedAt: clock) }
            case .answer:
                answer(take())
            case .round:
                let custody: ScopeHeal.Custody = take() & 1 == 0 ? .unreadable : .frames([])
                withSession(0) { heal, session, now in heal.roundStarted(custody, session: &session, now: now) }
            case .readopt:
                readopt(Array(scopes.prefix(Int(take()) % (scopes.count + 1))))
            case .outbound:
                heals[0].outboundFull = take() & 1 == 0
                withSession(0) { heal, session, now in heal.outboundDrained(&session, now: now) }
            case .pause:
                togglePause()
            }
        }

        /// One record off the script, to both connections.
        mutating func receive() {
            let count = Int(take()) << Fixture.byteBits | Int(take())
            let record = Array(bytes.prefix(count))
            bytes = bytes.dropFirst(record.count)
            for index in sessions.indices {
                sessions[index]?.receive(record)
            }
        }

        /// Moves the clock to the script's next `Int64` and runs both relays' timers.
        mutating func tick() {
            clock = takeInt64()
            for index in sessions.indices {
                sessions[index]?.tick(now: clock)
                withSession(index) { heal, session, now in heal.tick(session: &session, now: now) }
            }
        }

        /// Both connections close, and their heals hear it.
        mutating func close() {
            for index in sessions.indices {
                sessions[index]?.socketClosed()
            }
            carry()
            sessions = sessions.map { _ in nil }
        }

        /// The table loses the scopes past `kept` and gets them back, as the plane hands every heal and the miner each
        /// table: a search for one that left is cancelled while the miner's table lacks it.
        mutating func readopt(_ kept: [SpoolScope]) {
            for index in heals.indices {
                heals[index].adopt(kept)
            }
            miner.adopt(kept)
            carry()
            for index in heals.indices {
                heals[index].adopt(scopes)
            }
            miner.adopt(scopes)
        }

        /// The runner ends the job it holds, as `outcome` picks: a real search stopped at its second check, which finds a
        /// stamp at low bits, one that ran out, or one stopped at a check.
        mutating func answer(_ outcome: UInt8) {
            guard let held = job else {
                return
            }
            job = nil
            let need = SpoolPow.maxTries - held.from
            let search: SpoolPow.Search
            switch outcome % Fixture.outcomes {
            case 0:
                var checks = 0
                search = SpoolPow.mine(scopeId: held.scope.bytes, day: held.day, bits: held.bits, from: held.from) {
                    checks += 1
                    return checks > 1
                }
            case 1:
                search = .exhausted(tried: need)
            default:
                search = .cancelled(tried: min(Int64(take()) << Fixture.checkShift, need))
            }
            deliver(miner.ended(run: held.run, search, now: now))
        }

        /// Pauses the miner, or resumes it, as the plane's pause and resume do.
        mutating func togglePause() {
            if miner.paused {
                deliver(miner.resume(now: now))
            } else {
                miner.pause()
            }
        }

        /// Hands each answer to its relay's heal, with or without a session.
        mutating func deliver(_ answers: [SpoolMiner.Answer]) {
            for answer in answers {
                let request = answer.request
                // An answer for a serial nobody waits on, or a second one, would fail here.
                precondition(asked.removeValue(forKey: request.serial) == request)
                if case .found(let counter, _) = answer.answer {
                    // A found answer that is no stamp for its request would fail here.
                    precondition(SpoolPow.verify(scopeId: request.scope.bytes, day: request.day, n: counter, bits: request.bits))
                }
                let index = request.relay.number - 1
                let took = heals[index].stampMined(request, answer.answer, session: &sessions[index], now: now)
                // An answer the heal did not wait on would fail here.
                precondition(took)
            }
        }

        /// Takes the miner's actions: a start hands the runner its job.
        mutating func takeActions() {
            for case .start(let started) in miner.takeActions() {
                job = started
            }
        }

        mutating func withSession(_ index: Int, _ body: (inout ScopeHeal, inout SpoolSession, SpoolNow) -> Void) {
            guard var open = sessions[index] else {
                return
            }
            body(&heals[index], &open, now)
            sessions[index] = open
        }

        /// Carries each relay's session outputs into its heal, and the heals' asks through the miner, until quiet.
        mutating func carry() {
            var steps = 0
            var quiet = false
            while !quiet {
                quiet = true
                var asks: [SpoolPlane.Mining] = []
                for index in heals.indices {
                    quiet = drain(index, into: &asks) && quiet
                }
                // As the plane does once the heals' turns returned: the asks go to the miner, its answers at once to the heals.
                let answers = miner.take(asks, now: now)
                quiet = quiet && answers.isEmpty
                deliver(answers)
                steps += 1
                // The heals and the sessions never went quiet would fail here.
                precondition(steps < Self.maxOutputsPerStep)
            }
            takeActions()
        }

        /// One pass of relay `index`: its session's events into its heal, its heal's asks into `asks`, its candidates settled.
        /// Answers whether nothing moved.
        mutating func drain(_ index: Int, into asks: inout [SpoolPlane.Mining]) -> Bool {
            var quiet = true
            let outputs = sessions[index]?.drain() ?? []
            // One step drained too much would fail here.
            precondition(outputs.count <= Self.maxOutputsPerStep)
            for case .event(let event) in outputs {
                quiet = false
                withSession(index) { heal, session, now in heal.handle(event, session: &session, now: now) }
            }
            for output in heals[index].drain() {
                quiet = false
                switch output {
                case .mine(let request):
                    asked[request.serial] = request
                    asks.append(.mine(request))
                case .cancelMining(let request):
                    asked[request.serial] = nil
                    asks.append(.cancel(request))
                case .candidate(let candidate):
                    let settlement = settlements[Int(take()) % settlements.count]
                    withSession(index) { heal, session, now in heal.settle(candidate, settlement, session: &session, now: now) }
                }
            }
            return quiet
        }

        func check() {
            let mining = heals.flatMap(\.mining.values)
            // A search mining that nobody asked for, or one asked and lost would fail here.
            precondition(Set(mining) == Set(asked.values) && mining.count == asked.count)
            // A request the miner holds that no heal waits on would fail here.
            precondition(Set(miner.requests.keys) == Set(asked.keys))
            let budget = miner.budget
            let hour = SpoolMinerBudget.hour(clock)
            // A share past its cap would fail here.
            precondition(budget.engine.spent(at: hour) <= SpoolMinerBudget.engineCap)
            precondition(budget.relays.values.allSatisfy { $0.spent(at: hour) <= SpoolMinerBudget.relayCap })
            precondition(budget.peers.values.allSatisfy { $0.spent(at: hour) <= SpoolMinerBudget.peerCap })
            for session in sessions.compactMap(\.self) {
                for scope in scopes {
                    let inFlight = session.pending.values.filter { $0.scope == scope.id }.reduce(0) { $0 + $1.unserved.count }
                    // Claims past the bound would fail here.
                    precondition(session.claimCount(scope.id) <= SpoolSession.maxClaimsPerScope + inFlight + 1)
                }
            }
        }

        mutating func pick() -> SpoolID {
            scopes[Int(take()) % scopes.count].id
        }

        /// The next byte, or 0 once the script ran out.
        mutating func take() -> UInt8 {
            bytes.popFirst() ?? 0
        }

        mutating func takeInt64() -> Int64 {
            (0..<MemoryLayout<Int64>.size).reduce(Int64(0)) { value, _ in value << Fixture.byteBits | Int64(take()) }
        }

        static let maxOutputsPerStep = SpoolSessionFuzz.maxOutputsPerStep
        let settlements: [ScopeHeal.Settlement] = [
            .notTaken, .unopenable, .refusedByCarry, .delivered(keptLive: true), .delivered(keptLive: false),
        ]
    }
}
