public import KnitWire

/// Whose GATT payload a radio reads, when, and what each read found. A radio that finds peers whose advert carries
/// only the `0xFE30` UUID, as an iPhone's does (``Radio/dialsGattPeers``), keeps one of these, so KnitBLE and
/// KnitBlueZ read on the same rules and only the reading itself differs (ADR 2026-09.xzpt).
///
/// - **Once per address.** The value changes only with the peer's PSM, so what one read found is the payload of
///   every advert after it, until a dial to the peer fails: a peer that restarted listens on a new PSM, and is read
///   again. The radio forgets an address its stack forgets.
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

        /// Half a minute after a failure, ten minutes after a stranger, unless told otherwise.
        public init(
            readTimeoutMilliseconds: Int64 = 12_000,
            retryMilliseconds: Int64 = 30_000,
            strangerRetryMilliseconds: Int64 = 600_000
        ) {
            self.readTimeoutMilliseconds = readTimeoutMilliseconds
            self.retryMilliseconds = retryMilliseconds
            self.strangerRetryMilliseconds = strangerRetryMilliseconds
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

    /// Forgets what `address` served, and any wait before its next read: a dial to it failed, or the radio lost it.
    /// A read of it in progress runs on, since it is fetching the payload afresh.
    public mutating func forget(_ address: RadioAddress) {
        payloads[address] = nil
        retryAt[address] = nil
    }
}
