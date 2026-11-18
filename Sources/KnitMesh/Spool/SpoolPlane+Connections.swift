import KnitWire

/// The connections (ADR 2026-11.adrq, P4b1): relays added and removed, pause and resume, each dial and its token, the
/// socket's posts, the sends one at a time, the inbound budget, and the one path every session ends by.
extension SpoolPlane {
    // MARK: Relays

    /// Carries `relay` from now on, dialled at `url`, and dials it at once unless paused, or once the `Retry-After` its
    /// handle's last refused dial named has passed (``askedFloors``). Refused past ``maxRelays``, and for a handle already
    /// carried.
    mutating func add(_ relay: SpoolRelayHandle, url: AcceptedSpoolURL, engine: MeshEngine) -> Bool {
        guard relays[relay] == nil, relays.count < Self.maxRelays else {
            return false
        }
        var heal = ScopeHeal(relay: relay, me: me)
        heal.adopt(table.scopes)
        var state = Relay(url: url, heal: heal)
        let now = engine.clock.monotonicMilliseconds()
        pruneAskedFloors(now: now)
        state.link.nextDialAt = max(now, askedFloors[relay] ?? now)
        relays[relay] = state
        markTableDirty()
        refreshTable(engine: engine)
        dialDue(engine: engine)
        return true
    }

    /// Drops `relay`: its session ends, its socket closes, and its heal goes, every stamp it was mining cancelled. A relay
    /// added again under the same handle starts a fresh heal, and no old token matches it.
    mutating func remove(_ relay: SpoolRelayHandle, engine: MeshEngine) {
        end(relay, .removed, keepToken: false, engine: engine)
        guard let gone = relays.removeValue(forKey: relay) else {
            return
        }
        for request in gone.heal.mining.values {
            mining.append(.cancel(request))
        }
    }

    /// Ends every session and dial, and dials nothing until ``resume(engine:)``. Every heal stays as it is: a pause is no
    /// failure, and only a process start or a removal makes a fresh heal (this port's rule).
    mutating func pause(engine: MeshEngine) {
        paused = true
        // The running search stops at its next check; its requests stay, and the resume carries it on (P4b2).
        miner.pause()
        for relay in relays.keys.sorted() {
            end(relay, .paused, keepToken: false, engine: engine)
            relays[relay]?.link.nextDialAt = nil
        }
    }

    /// Out of a pause, dials every relay at once, its failure count reset, unless the relay asked for later: the
    /// `Retry-After` of its last refused dial (``askedFloors``) or the rest of 30 s after a session that ended early
    /// (``SpoolLink/earlyFloorAt``). Then lets the miner run again in this turn. A resume of a plane that is not paused does
    /// nothing (P6): a second `resumeSpool()` must not zero a backoff and dial a relay deep in it at once, and the miner,
    /// paused and resumed only with the plane, is already running.
    mutating func resume(engine: MeshEngine) {
        guard paused else {
            return
        }
        paused = false
        let now = engine.clock.monotonicMilliseconds()
        pruneAskedFloors(now: now)
        for relay in relays.keys {
            var due = now
            if let asked = askedFloors[relay] {
                due = max(due, asked)
            }
            if let early = relays[relay]?.link.earlyFloorAt {
                due = max(due, early)
            }
            relays[relay]?.link.failures = 0
            relays[relay]?.link.nextDialAt = due
        }
        dialDue(engine: engine)
        deliver(miner.resume(now: SpoolNow(monotonic: now, wall: engine.clock.wallMilliseconds())), engine: engine)
    }

    // MARK: The socket's posts

    /// The dial under `token` opened. Answers `false` when the token is over, and the caller closes the socket. A session
    /// already in place for the relay ends first, so two never overlap.
    mutating func opened(_ relay: SpoolRelayHandle, token: SpoolConnectionToken, engine: MeshEngine) -> Bool {
        guard let link = relays[relay]?.link, link.token == token else {
            return false
        }
        if relays[relay]?.session != nil {
            end(relay, .replaced, keepToken: true, engine: engine)
        }
        refreshTable(engine: engine)
        let now = engine.clock.monotonicMilliseconds()
        relays[relay]?.link.phase = .open(token)
        relays[relay]?.link.openedAt = now
        if let rounds = relays[relay]?.heal.counts.roundsCompared {
            relays[relay]?.link.roundsAtOpen = rounds
        }
        relays[relay]?.link.inbound = SpoolInboundBudget(now: now)
        relays[relay]?.link.drops = SpoolDropWindow()
        relays[relay]?.link.readerParked = false
        relays[relay]?.link.counts.sessions += 1
        relays[relay]?.session = SpoolSession(openedAt: now)
        run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed)), nil)
        return true
    }

    /// The dial under `token` failed: a failure for the backoff, floored by the spool's `Retry-After` when it gave one, and
    /// that floor kept for a resume and a re-add (``askedFloors``).
    ///
    /// A refusal that lands after a pause or the open deadline already ended its dial is no failure (the end was not the
    /// relay's), but its `Retry-After` still stands while `token` is the last dial issued to the relay (P6): a pause between
    /// a 503 and its post would otherwise lose it. A later dial, or a relay removed and added again, makes the token stale,
    /// and a stale post is dropped.
    mutating func dialFailed(_ relay: SpoolRelayHandle, token: SpoolConnectionToken, _ failure: SpoolDialFailure, engine: MeshEngine) {
        guard var link = relays[relay]?.link else {
            return
        }
        let now = engine.clock.monotonicMilliseconds()
        let floor = failure.retryAfter?.milliseconds
        guard case .dialing(token, _) = link.phase else {
            if link.lastDialToken == token {
                let asked = noteAskedFloor(relay, floor, now: now)
                // Only the open deadline leaves a redial set here; a pause leaves none, and the resume reads the floor.
                if let asked {
                    relays[relay]?.link.nextDialAt = link.nextDialAt.map { max($0, asked) }
                }
            }
            return
        }
        link.phase = .idle
        link.counts.dialFailures += 1
        link.counts.unreached += 1
        link.failures += 1
        link.nextDialAt = redialAt(failures: link.failures, floor: floor, engine: engine)
        relays[relay]?.link = link
        noteAskedFloor(relay, floor, now: now)
    }

    /// One message off the socket under `token`, posted once the reader's last post returned. Answers what the reader does
    /// next: read on, wait for the inbound budget, or stop.
    mutating func receive(
        _ message: SpoolSocketMessage, from relay: SpoolRelayHandle, token: SpoolConnectionToken, engine: MeshEngine
    ) -> ReaderNext {
        guard let link = relays[relay]?.link, case .open(token) = link.phase else {
            return .stop
        }
        let now = engine.clock.monotonicMilliseconds()
        let size: Int
        switch message {
        case .closed(let end):
            socketClosed(relay, token: token, end, engine: engine)
            return .stop
        case .text(let count):
            size = count
            relays[relay]?.link.counts.textDropped += 1
        case .binary(let bytes):
            size = bytes.count
        }
        let charged = min(size, SpoolRecordLayer.maxInboundRecord + 1)
        let room = relays[relay]?.link.inbound.charge(bytes: charged, now: now) == true
        var dropped = true
        var counted = true
        if case .binary(let bytes) = message {
            let before = relays[relay]?.droppedRecords
            let unknownBefore = relays[relay]?.unknownRecords
            refreshTable(engine: engine)
            run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { _, session, _ in session.receive(bytes) }
            dropped = relays[relay]?.droppedRecords != before
            counted = relays[relay]?.unknownRecords == unknownBefore
        }
        guard relays[relay]?.link.token == token else {
            return .stop
        }
        if dropped, relays[relay]?.link.drops.note(bytes: charged, counted: counted, now: now) == true {
            relays[relay]?.link.counts.dropFaults += 1
            end(relay, .fault(.dropped), keepToken: false, engine: engine)
            return .stop
        }
        guard room else {
            relays[relay]?.link.readerParked = true
            relays[relay]?.link.counts.inboundDeferred += 1
            return .park
        }
        return .next
    }

    /// The socket under `token` closed, whoever closed it.
    mutating func socketClosed(_ relay: SpoolRelayHandle, token: SpoolConnectionToken, _ end: SpoolSocketEnd, engine: MeshEngine) {
        guard relays[relay]?.link.token == token else {
            return
        }
        self.end(relay, .socket(end), keepToken: false, engine: engine)
    }

    /// The send under `token` finished: the next goes, and pushes held for the queue go on once it is under its cap. A send
    /// that failed is the socket's end.
    mutating func sent(_ relay: SpoolRelayHandle, token: SpoolConnectionToken, ok: Bool, engine: MeshEngine) {
        // The table first, as every input reads it: a scope that left takes its held pushes with it before they go on.
        refreshTable(engine: engine)
        guard var link = relays[relay]?.link, case .open(token) = link.phase, let size = link.sending else {
            return
        }
        guard ok else {
            relays[relay]?.link.counts.sendFailures += 1
            end(relay, .sendFailed, keepToken: false, engine: engine)
            return
        }
        link.sending = nil
        link.queuedBytes = max(link.queuedBytes - size, 0)
        link.stallFrom = link.queuedBytes > 0 ? engine.clock.monotonicMilliseconds() : nil
        relays[relay]?.link = link
        if link.queuedBytes < SpoolLink.maxQueuedBytes {
            run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { heal, session, now in
                heal.outboundDrained(&session, now: now)
            }
        }
    }

    /// What ``Mesh`` should do with the sockets, in order: each open relay's next record when none is in flight, then dials,
    /// closes and resumed readers.
    mutating func takeActions() -> [SocketAction] {
        for relay in relays.keys.sorted() {
            guard var state = relays[relay], case .open(let token) = state.link.phase, state.link.sending == nil,
                !state.outgoing.isEmpty
            else {
                continue
            }
            let bytes = state.outgoing.removeFirst()
            state.link.sending = bytes.count
            relays[relay] = state
            actions.append(.send(relay, token, bytes))
        }
        defer { actions.removeAll() }
        return actions
    }

    // MARK: Timers

    /// Dials every idle relay whose wait is over, unless paused.
    mutating func dialDue(engine: MeshEngine) {
        guard !paused else {
            return
        }
        let now = engine.clock.monotonicMilliseconds()
        for relay in relays.keys.sorted() {
            guard var state = relays[relay], state.link.phase == .idle, let due = state.link.nextDialAt, now >= due else {
                continue
            }
            let token = SpoolConnectionToken(value: nextToken)
            nextToken += 1
            state.link.phase = .dialing(token, openBy: SpoolSession.later(now, by: SpoolLink.openMilliseconds))
            state.link.nextDialAt = nil
            state.link.lastDialToken = token
            state.link.counts.dials += 1
            relays[relay] = state
            actions.append(.dial(relay, token, state.url))
        }
    }

    /// A dial past its open deadline, bytes queued past the write stall, and a reader whose budget came back.
    mutating func linkTimers(_ relay: SpoolRelayHandle, _ current: SpoolLink, engine: MeshEngine) {
        var link = current
        let now = engine.clock.monotonicMilliseconds()
        switch link.phase {
        case .dialing(let token, let openBy) where now >= openBy:
            link.phase = .idle
            link.counts.dialTimeouts += 1
            link.counts.unreached += 1
            link.failures += 1
            link.nextDialAt = redialAt(failures: link.failures, floor: nil, engine: engine)
            relays[relay]?.link = link
            actions.append(.close(relay, token, code: SpoolCloseCode.normal))
        case .open(let token):
            if let stall = link.stallDeadline, now >= stall {
                relays[relay]?.link.counts.writeStalls += 1
                end(relay, .writeStall, keepToken: false, engine: engine)
                return
            }
            if link.readerParked, link.inbound.hasRoom(now: now) {
                link.readerParked = false
                relays[relay]?.link = link
                actions.append(.resumeReader(relay, token))
            }
        default:
            break
        }
    }

    // MARK: The one end

    /// Ends `relay`'s dial or session for `cause`: a session runs its close through the heal in this turn, the queue is
    /// cleared, and the socket's task is told to close. `keepToken` leaves the link's token in place, for a second open on it.
    mutating func end(_ relay: SpoolRelayHandle, _ cause: SpoolSessionEnd, keepToken: Bool, engine: MeshEngine) {
        guard let state = relays[relay] else {
            return
        }
        if state.session != nil {
            run(relay, engine: engine, cause: cause) { _, session, _ in session.socketClosed() }
        } else if case .dialing(let token, _) = state.link.phase {
            // Only a pause or a removal ends a dial this way; the redial is the resume's.
            relays[relay]?.link.phase = .idle
            actions.append(.close(relay, token, code: SpoolCloseCode.normal))
        }
        if keepToken, let token = state.link.token {
            relays[relay]?.link.phase = .open(token)
            actions.removeAll { $0 == .close(relay, token, code: SpoolCloseCode.normal) }
        }
    }

    /// Tears down a session that closed in this turn: the heal already heard `.ended`. Counts it reached or not, clears the
    /// queue and the bounds, schedules the redial unless paused or removed, and tells the socket's task to close.
    mutating func finish(_ state: inout Relay, _ cause: SpoolSessionEnd, engine: MeshEngine) {
        let now = engine.clock.monotonicMilliseconds()
        let token = state.link.token
        state.session = nil
        state.outgoing.removeAll()
        let code = state.faultClose ?? SpoolCloseCode.normal
        state.faultClose = nil
        let reached = state.link.reached(cause, rounds: state.heal.counts.roundsCompared, now: now)
        let early = state.link.earlyEndFloor(now: now)
        var link = state.link
        link.phase = .idle
        link.queuedBytes = 0
        link.sending = nil
        link.stallFrom = nil
        link.readerParked = false
        link.openedAt = nil
        switch cause {
        case .paused, .removed, .replaced:
            break
        default:
            if reached {
                link.counts.reached += 1
                link.failures = 0
            } else {
                link.counts.unreached += 1
                link.failures += 1
            }
            link.nextDialAt = redialAt(failures: link.failures, floor: early, engine: engine)
            link.earlyFloorAt = early.map { SpoolSession.later(now, by: $0) }
        }
        state.link = link
        if let token {
            actions.append(.close(state.heal.relay, token, code: code))
        }
    }

    // MARK: Asked-for floors

    /// Keeps `relay`'s `Retry-After` of `floor` milliseconds from `now` in ``askedFloors``, or forgets its last one when this
    /// refusal named none: the floor is the last refusal's word, never the longest of them. Answers the floor kept. Entries
    /// whose time has passed go first; past ``maxRelays`` entries, those of relays no longer carried go too, so the map
    /// stays bounded however often relays are removed and added.
    @discardableResult
    mutating func noteAskedFloor(_ relay: SpoolRelayHandle, _ floor: Int64?, now: Int64) -> Int64? {
        pruneAskedFloors(now: now)
        let asked = floor.map { SpoolSession.later(now, by: $0) }
        askedFloors[relay] = asked
        if askedFloors.count > Self.maxRelays {
            askedFloors = askedFloors.filter { relays[$0.key] != nil }
        }
        return asked
    }

    /// Drops every asked-for floor whose time has passed at `now`.
    mutating func pruneAskedFloors(now: Int64) {
        askedFloors = askedFloors.filter { $0.value > now }
    }

    /// When the next dial goes after `failures` unreached sessions in a row, floored by a `Retry-After`.
    private func redialAt(failures: Int, floor: Int64?, engine: MeshEngine) -> Int64 {
        let delay = SpoolBackoff.delay(failures: failures, retryAfterMilliseconds: floor, using: &engine.random)
        return SpoolSession.later(engine.clock.monotonicMilliseconds(), by: delay)
    }

    /// Queues `bytes` for the socket: the stall clock starts when the queue was empty.
    mutating func queue(_ bytes: [UInt8], on state: inout Relay, now: Int64) {
        state.outgoing.append(bytes)
        state.link.queuedBytes += bytes.count
        if state.link.stallFrom == nil {
            state.link.stallFrom = now
        }
    }
}
