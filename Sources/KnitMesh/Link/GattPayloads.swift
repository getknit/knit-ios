public import KnitWire

/// Whose GATT payload a radio reads, when, and what each read found. A radio that finds peers whose advert carries
/// only the `0xFE30` UUID, as an iPhone's does (``Radio/dialsGattPeers``), keeps one of these, so KnitBLE and
/// KnitBlueZ read on the same rules and only the reading itself differs (ADR 2026-09.xzpt).
///
/// - **Once per address, while it holds.** The value changes only with the peer's PSM, so what one read found is the
///   payload of every advert from that address until the radio forgets it, which it does when any of three things
///   happens (the paired change `gatt-peers`' payload lifetime, knit-next ADR 2026-09.kwq2):
///   1. A dial to the address fails before its channel opens: a peer that restarted listens on a new PSM.
///   2. A HELLO on a link to the address names another node (``helloNamed(_:at:)``): a new node took the address,
///      as every knit-peer on one adapter does. A refusal carries no HELLO, and keeps the payload.
///   3. The address goes unheard for ``Configuration/quietMilliseconds`` of scanning while no link to it is up
///      (``forgetQuiet(now:linked:)``). Without it, a node above us at a reused address is never dialed, so rule 1
///      never fires, and a new node there is sighted as the old one for good.
///
///   One case stays open: a node that changes identity at an address that never goes quiet, where the old node sorts
///   above us and the new one below a peer that waits to be dialed. Nobody dials, so it lasts until the address
///   rotates or goes quiet. The radio also forgets an address its stack forgets.
/// - **One at a time.** Every read is a connection the controller must make, and a second waits for the first.
/// - **Tried again later.** A read that fails waits ``Configuration/retryMilliseconds``. A peer that answers but
///   serves no payload waits ``Configuration/strangerRetryMilliseconds``: `0xFE30` is not Knit's alone, and a
///   stranger's device should not be connected to twice a minute.
public struct GattPayloads: Sendable {
    /// The reads' tunables.
    public struct Configuration: Sendable {
        /// How long one read may take, its connection included: Android's connect watchdog (`CONNECT_TIMEOUT_MS`).
        public var readTimeoutMilliseconds: Int64
        /// How long a peer whose read failed waits before it is read again.
        public var retryMilliseconds: Int64
        /// How long a peer that serves no Knit payload waits before it is read again.
        public var strangerRetryMilliseconds: Int64
        /// How long an address may go unheard, counting only time the scan runs, before its payload and its wait are
        /// forgotten, while no link to it is up.
        public var quietMilliseconds: Int64

        /// Half a minute after a failure, ten minutes after a stranger, and a minute of quiet, unless told otherwise.
        public init(
            readTimeoutMilliseconds: Int64 = 12_000,
            retryMilliseconds: Int64 = 30_000,
            strangerRetryMilliseconds: Int64 = 600_000,
            quietMilliseconds: Int64 = 60_000
        ) {
            self.readTimeoutMilliseconds = readTimeoutMilliseconds
            self.retryMilliseconds = retryMilliseconds
            self.strangerRetryMilliseconds = strangerRetryMilliseconds
            self.quietMilliseconds = quietMilliseconds
        }
    }

    /// How a read ended.
    public enum Outcome: Sendable, Equatable {
        /// The characteristic held a payload.
        case read(AdvertPayload)
        /// No connection, no answer or an error, which a later read may not meet.
        case failed
        /// The peer answered, but serves no Knit payload.
        case stranger
    }

    /// The read in progress.
    public struct Read: Sendable, Equatable {
        /// Whose payload it reads.
        public let address: RadioAddress
        /// When it must have ended, on the monotonic clock.
        public let deadline: Int64
    }

    /// The tunables.
    public let configuration: Configuration
    /// The read in progress, if any.
    public private(set) var current: Read?
    private var payloads: [RadioAddress: AdvertPayload] = [:]
    private var retryAt: [RadioAddress: Int64] = [:]
    /// When each address was last heard, on the scan clock.
    private var lastHeard: [RadioAddress: Int64] = [:]
    /// Scan time run up before the scan now running, and when that scan started on the monotonic clock.
    private var scannedBefore: Int64 = 0
    private var scanningSince: Int64?

    /// Nothing read yet.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The payload `address` served, if a read found one.
    public func payload(of address: RadioAddress) -> AdvertPayload? {
        payloads[address]
    }

    /// Starts reading `address`, and answers `true`, when nothing else is being read, it has no payload yet, and it
    /// is not waiting to be tried again.
    public mutating func begin(_ address: RadioAddress, now: Int64) -> Bool {
        retryAt = retryAt.filter { $0.value > now }
        guard current == nil, payloads[address] == nil, retryAt[address] == nil else {
            return false
        }
        current = Read(address: address, deadline: now + configuration.readTimeoutMilliseconds)
        return true
    }

    /// The read of `address` ended. An outcome for any other address answers a read already given up on, and is
    /// ignored.
    public mutating func finish(_ address: RadioAddress, _ outcome: Outcome, now: Int64) {
        guard current?.address == address else {
            return
        }
        current = nil
        switch outcome {
        case .read(let payload):
            payloads[address] = payload
            lastHeard[address] = scanTime(now: now)
        case .failed:
            retryAt[address] = now + configuration.retryMilliseconds
        case .stranger:
            retryAt[address] = now + configuration.strangerRetryMilliseconds
        }
    }

    /// Ends the read in progress without learning anything and without a wait: the radio went down under it.
    public mutating func cancel() {
        current = nil
    }

    /// Forgets what `address` served, and any wait before its next read: a dial to it failed, a HELLO there named
    /// another node, it went quiet, or the radio lost it. A read of it in progress runs on, since it is fetching the
    /// payload afresh.
    public mutating func forget(_ address: RadioAddress) {
        payloads[address] = nil
        retryAt[address] = nil
    }

    // MARK: The payload's lifetime

    /// Rule 2: the HELLO on a link to `address` named `node`, the dialer's on a link we accepted or the reply on one we
    /// dialed. A payload there that names another node is forgotten, and the answer says whether one was.
    public mutating func helloNamed(_ node: NodeId, at address: RadioAddress) -> Bool {
        guard let payload = payloads[address], payload.nodeId != node else {
            return false
        }
        forget(address)
        return true
    }

    /// The scan started at `now`, so time counts towards quiet again.
    public mutating func scanStarted(now: Int64) {
        if scanningSince == nil {
            scanningSince = now
        }
    }

    /// The scan stopped at `now`; time while it is off does not count, since nothing could have been heard.
    public mutating func scanStopped(now: Int64) {
        if let since = scanningSince {
            scannedBefore += max(0, now - since)
        }
        scanningSince = nil
    }

    /// The scan time at `now`: how long the scan has run, all told.
    public func scanTime(now: Int64) -> Int64 {
        scannedBefore + (scanningSince.map { max(0, now - $0) } ?? 0)
    }

    /// An advert from `address`, which lists only the `0xFE30` UUID, was heard at `now`.
    public mutating func heard(_ address: RadioAddress, now: Int64) {
        lastHeard[address] = scanTime(now: now)
    }

    /// Rule 3: forgets the payload of every address unheard for ``Configuration/quietMilliseconds`` of scanning, and
    /// answers those, in order. Heard means an advert, the read that found the payload, or a link. An address in
    /// `linked`, which a link or a read holds, is never quiet: it counts as heard now, so its minute starts when the
    /// link ends, since a peripheral stops advertising while it is connected. A stranger keeps its wait: it holds no
    /// payload, and its ten minutes are what spare a device that is not Knit's (knit-next's `GattPayloads.scanned`).
    public mutating func forgetQuiet(now: Int64, linked: Set<RadioAddress>) -> [RadioAddress] {
        let scanned = scanTime(now: now)
        for address in linked {
            lastHeard[address] = scanned
        }
        let quiet = lastHeard.filter { scanned - $0.value >= configuration.quietMilliseconds }.keys
        var forgotten: [RadioAddress] = []
        for address in quiet.sorted(by: { $0.rawValue < $1.rawValue }) {
            lastHeard[address] = nil
            if payloads[address] != nil {
                forget(address)
                forgotten.append(address)
            }
        }
        return forgotten
    }
}
