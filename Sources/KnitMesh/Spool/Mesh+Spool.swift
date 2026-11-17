public import KnitWire

/// The spool's sockets (ADR 2026-11.adrq, P4b1): one task per dial that opens the socket, reads it and posts every message
/// into this actor under the dial's token, and one task per send. The decisions are ``SpoolPlane``'s; this side only carries
/// its ``SpoolPlane/SocketAction``s out and the socket's answers in, then settles.
///
/// - A relay is dialled only when it has no task: a dial the plane asks for while the last task is still ending waits for
///   it, so two dials to one relay never overlap.
/// - The reader calls ``SpoolSocket/receive()`` only after its last post returned, and waits on a continuation this actor
///   resumes when the plane says the inbound budget came back, or a close ends it.
/// - At most one send is in flight per relay.
/// - A stamp search the plane asks for waits in ``spoolMiningQueue`` until a runner takes it (a later phase); the plane's
///   cancel takes it out.
extension Mesh {
    /// One relay's task, its socket once open, and its reader's wait.
    struct SpoolTask {
        let token: SpoolConnectionToken
        var task: Task<Void, Never>?
        var socket: (any SpoolSocket)?
        var parked: CheckedContinuation<Bool, Never>?
        /// A resume that came before the reader parked.
        var resumeOwed = false
        var ended = false
    }

    /// Every relay's task, and the dials waiting for the last task to end.
    struct SpoolTasks {
        var running: [SpoolRelayHandle: SpoolTask] = [:]
        var waitingDials: [SpoolRelayHandle: (token: SpoolConnectionToken, url: AcceptedSpoolURL)] = [:]
    }

    // MARK: The app's side

    /// Carries the relay at `url` under `handle` from now on, and dials it while the mesh runs and the spool is not paused.
    /// Refused past eight relays, for a handle already carried, and on a mesh made with no socket factory.
    @discardableResult
    public func addSpoolRelay(_ handle: SpoolRelayHandle, url: AcceptedSpoolURL) -> Bool {
        guard spoolSockets != nil else {
            return false
        }
        defer { settle() }
        return spool.add(handle, url: url, engine: engine)
    }

    /// Drops the relay `handle`: its session ends, its socket closes and its heal goes. Turning the plane off, or a consent
    /// withdrawn, removes every relay rather than pausing.
    public func removeSpoolRelay(_ handle: SpoolRelayHandle) {
        spool.remove(handle, engine: engine)
        settle()
    }

    /// Ends every relay's session and dials none until ``resumeSpool()``, keeping every heal: what the app does when its
    /// scene leaves the foreground.
    public func pauseSpool() {
        spoolWanted = false
        spool.pause(engine: engine)
        settle()
    }

    /// Dials every relay at once, failure counts reset, while the mesh runs.
    public func resumeSpool() {
        spoolWanted = true
        if isRunning {
            spool.resume(engine: engine)
        }
        settle()
    }

    /// The spool plane as `status` shows it: relays by handle and counts.
    public var spoolStatus: SpoolStatus { spool.status(inbound: engine.spoolInbound.counts) }

    /// The plane's next deadline, and the redial of `relay` while it has no session.
    /// Read by the tests alone, through `@testable`, which `swiftlint analyze` (Sources only) does not see.
    var spoolDeadline: Int64? { spool.nextDeadline } // swiftlint:disable:this unused_declaration
    func spoolRedial(_ relay: SpoolRelayHandle) -> Int64? { // swiftlint:disable:this unused_declaration
        spool.relays[relay]?.link.nextDialAt
    }

    // MARK: The tasks' posts

    func spoolDialFailed(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, _ failure: SpoolDialFailure) {
        spool.dialFailed(relay, token: token, failure, engine: engine)
        settle()
    }

    /// The dial under `token` opened `socket`. Answers `false` when the token is over; the task then closes it.
    func spoolOpened(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, _ socket: any SpoolSocket) -> Bool {
        guard spoolTasks.running[relay]?.token == token, spool.opened(relay, token: token, engine: engine) else {
            return false
        }
        spoolTasks.running[relay]?.socket = socket
        settle()
        return true
    }

    func spoolReceived(_ message: SpoolSocketMessage, _ relay: SpoolRelayHandle, _ token: SpoolConnectionToken) -> SpoolPlane.ReaderNext {
        let next = spool.receive(message, from: relay, token: token, engine: engine)
        settle()
        return next
    }

    /// The reader waits for the inbound budget. Answers whether to read on.
    func spoolParkReader(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken) async -> Bool {
        guard let entry = spoolTasks.running[relay], entry.token == token, !entry.ended else {
            return false
        }
        if entry.resumeOwed {
            spoolTasks.running[relay]?.resumeOwed = false
            return true
        }
        return await withCheckedContinuation { continuation in
            spoolTasks.running[relay]?.parked = continuation
        }
    }

    func spoolSent(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, ok: Bool) {
        spool.sent(relay, token: token, ok: ok, engine: engine)
        settle()
    }

    /// The task under `token` is over: a dial that waited for it goes now.
    func spoolTaskEnded(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken) {
        if spoolTasks.running[relay]?.token == token {
            spoolTasks.running[relay] = nil
        }
        if spoolTasks.running[relay] == nil, let waiting = spoolTasks.waitingDials.removeValue(forKey: relay) {
            dialSpool(relay, waiting.token, waiting.url)
        }
        settle()
    }

    /// A stamp search ended: what the runner calls with what it found, or `nil` when it ran out of tries.
    /// P4b2's miner calls it; until then the tests alone do, through `@testable`, which `swiftlint analyze` does not see.
    func spoolStampMined(_ request: SpoolMiningRequest, counter: Int64?) { // swiftlint:disable:this unused_declaration
        spoolMiningQueue.remove(request)
        spool.stampMined(request, counter: counter, engine: engine)
        settle()
    }

    // MARK: Carrying the plane's asks

    /// Carries out what the plane asked since the last turn, queues its stamp searches, and writes its log lines. ``settle()``
    /// calls it after every input.
    func serviceSpool() {
        for ask in spool.takeMining() {
            switch ask {
            case .mine(let request):
                spoolMiningQueue.insert(request)
            case .cancel(let request):
                spoolMiningQueue.remove(request)
            }
        }
        // A close can make another (a send that finds no socket ends its session), so carry until none is left.
        var actions = spool.takeActions()
        while !actions.isEmpty {
            for action in actions {
                carry(action)
            }
            actions = spool.takeActions()
        }
        for line in spool.logLines(inbound: engine.spoolInbound.counts, now: engine.clock.monotonicMilliseconds()) {
            engine.log.log(.warning, line)
        }
    }

    private func carry(_ action: SpoolPlane.SocketAction) {
        switch action {
        case .dial(let relay, let token, let url):
            if spoolTasks.running[relay] == nil {
                dialSpool(relay, token, url)
            } else {
                spoolTasks.waitingDials[relay] = (token, url)
            }
        case .send(let relay, let token, let bytes):
            sendSpool(bytes, relay, token)
        case .close(let relay, let token, let code):
            closeSpool(relay, token, code: code)
        case .resumeReader(let relay, let token):
            resumeSpoolReader(relay, token)
        }
    }

    /// Only a mesh with a socket factory carries a relay (``addSpoolRelay(_:url:)``), so one is always here.
    private func dialSpool(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, _ url: AcceptedSpoolURL) {
        if let factory = spoolSockets {
            launch(relay, token, url, through: factory)
        }
    }

    private func launch(
        _ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, _ url: AcceptedSpoolURL, through factory: any SpoolSocketFactory
    ) {
        var entry = SpoolTask(token: token)
        entry.task = Task { [weak self] in
            let dial = await factory.open(url)
            let socket: any SpoolSocket
            switch dial {
            case .failed(let failure):
                await self?.spoolDialFailed(relay, token, failure)
                await self?.spoolTaskEnded(relay, token)
                return
            case .opened(let opened):
                socket = opened
            }
            guard await self?.spoolOpened(relay, token, socket) == true else {
                socket.close(code: SpoolCloseCode.normal)
                await self?.spoolTaskEnded(relay, token)
                return
            }
            var reading = true
            while reading {
                let message = await socket.receive()
                // A mesh that went away answers nil, which stops the reader as `.stop` does.
                switch await self?.spoolReceived(message, relay, token) {
                case .next:
                    break
                case .park:
                    reading = await self?.spoolParkReader(relay, token) == true
                case .stop, nil:
                    reading = false
                }
            }
            await self?.spoolTaskEnded(relay, token)
        }
        spoolTasks.running[relay] = entry
    }

    private func sendSpool(_ bytes: [UInt8], _ relay: SpoolRelayHandle, _ token: SpoolConnectionToken) {
        // The plane sends only on a session this actor saw open, so the socket is here; were it not, the send would never
        // finish and the write stall would end the session.
        if let entry = spoolTasks.running[relay], entry.token == token, let socket = entry.socket {
            Task { [weak self] in
                let ok = await socket.send(bytes)
                await self?.spoolSent(relay, token, ok: ok)
            }
        }
    }

    private func closeSpool(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken, code: Int) {
        if spoolTasks.waitingDials[relay]?.token == token {
            spoolTasks.waitingDials[relay] = nil
        }
        if var entry = spoolTasks.running[relay], entry.token == token {
            entry.ended = true
            entry.task?.cancel()
            entry.socket?.close(code: code)
            entry.parked?.resume(returning: false)
            entry.parked = nil
            spoolTasks.running[relay] = entry
        }
    }

    /// A resume that comes before the reader parks is owed to it.
    func resumeSpoolReader(_ relay: SpoolRelayHandle, _ token: SpoolConnectionToken) {
        guard spoolTasks.running[relay]?.token == token else {
            return
        }
        spoolTasks.running[relay]?.resumeOwed = true
        if let parked = spoolTasks.running[relay]?.parked {
            spoolTasks.running[relay]?.parked = nil
            spoolTasks.running[relay]?.resumeOwed = false
            parked.resume(returning: true)
        }
    }

    /// Ends every task when the actor goes: their posts find nothing, and a parked reader stops.
    nonisolated static func release(_ tasks: SpoolTasks) {
        for entry in tasks.running.values {
            entry.task?.cancel()
            entry.socket?.close(code: SpoolCloseCode.goingAway)
            entry.parked?.resume(returning: false)
        }
    }
}
