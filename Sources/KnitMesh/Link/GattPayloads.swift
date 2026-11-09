import KnitCrypto
public import KnitWire

/// Whose GATT payload a radio reads, when, and what each read found. A radio that finds peers whose advert carries
/// only the `0xFE30` UUID, as an iPhone's does (``Radio/dialsGattPeers``), keeps one of these, so KnitBLE and
/// KnitBlueZ read on the same rules and only the reading itself differs (ADR 2026-09.xzpt).
///
/// - **Once per address, while it holds.** The value changes only with the peer's PSM, so what one read found is the
///   payload of every advert from that address until the radio forgets it, which it does when any of five things
///   happens (the paired change `gatt-peers`' payload lifetime, knit-next ADR 2026-09.kwq2):
///   1. A dial to the address fails before its channel opens: a peer that restarted listens on a new PSM.
///   2. A HELLO on a link to the address names another node (``helloNamed(_:told:announced:at:)``): a new node took the
///      address, as every knit-peer on one adapter does. A refusal carries no HELLO, and keeps the payload. A blinded
///      payload names a tag, not a node, so it is compared with the HELLO's `t` and the tag that node announced instead,
///      and goes when neither is its tag: the node rotated since the read, or airs its id now (ADR 2026-11.prsp).
///   3. The address goes unheard for ``Configuration/quietMilliseconds`` of scanning while no link to it is up
///      (``forgetQuiet(now:linked:)``). Without it, a node above us at a reused address is never dialed, so rule 1
///      never fires, and a new node there is sighted as the old one for good.
///
///   4. It holds a blinded payload and the first slot edge after the read has passed, by up to
///      ``Configuration/blindedEdgeJitterMilliseconds`` more, while no link to it is up (``forgetPastEdge(wall:linked:)``; ADR
///      2026-11.prsp). A blinding node
///      rotates its tag at the edge, and in the foreground, where its address is never quiet, rule 3 would keep the old tag
///      until the system rotates the address. So each address costs at most one read per slot. The jitter starts
///      ``Configuration/blindedEdgeSlackMilliseconds`` past the edge (an announced rotation's 30 s and 5 s more), so a writer
///      has rotated before the read again, even one whose announcement came late or whose clock runs a little behind, and
///      spreads the readers of one writer.
///   5. A plain dial to the address whose HELLO carried ``Capabilities/linkSeal`` got no reply, and the payload is clear
///      and lacks `FLAG_LINK_SEAL` (``noReply(at:)``; the `link-seal` contract, §7, revision 1): its owner may have
///      upgraded since the read, and a sealing build refuses a plain dial from one before it replies, so only a fresh read
///      lets the next dial open sealed. Once per address: busy, suspended and already-linked iPhones give no reply all the
///      time, and a payload read afresh that still lacks the flag is kept until another rule forgets the address or a read
///      finds the flag. A payload that carries the flag is never forgotten this way (revision 2): a no-reply sealed dial
///      says nothing about the flag. Nor is a blinded one (the `blind-gatt-reads` contract, §6, Android's
///      `forgetUnsealed`): it rotates and rule 4 forgets it every slot anyway.
///
///   One case stays open: a node that changes identity at an address that never goes quiet, where the old node sorts
///   above us and the new one below a peer that waits to be dialed. Nobody dials, so it lasts until the address
///   rotates or goes quiet. The radio also forgets an address its stack forgets.
/// - **One at a time.** Every read is a connection the controller must make, and a second waits for the first.
/// - **Tried again later.** A read that fails waits ``Configuration/retryMilliseconds``. A peer that answers but
///   serves no payload waits ``Configuration/strangerRetryMilliseconds``: `0xFE30` is not Knit's alone, and a
///   stranger's device should not be connected to twice a minute.
///
/// knit-next's `GattPayloads.kt` adds a budget across addresses (#154), and this type deliberately has none: no radio
/// here holds a dial back while a read runs, so a cap would only make a real iPhone wait behind strangers (ADR
/// 2026-09.xzpt, amended 2026-10-11).
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
        /// How long past the slot edge a blinded payload is kept at least (rule 4).
        public var blindedEdgeSlackMilliseconds: Int64
        /// The spread of a blinded payload's forget past that, drawn per read (rule 4).
        public var blindedEdgeJitterMilliseconds: Int64

        /// Rule 4's slack: an announced rotation lands at the later of the edge and its announcement plus
        /// ``AdvertRotation/minLeadMilliseconds``, so a forget any sooner would read the old tag again and keep it a whole slot;
        /// and ``writerClockSlackMilliseconds`` more for a writer whose clock runs a little behind.
        public static let defaultBlindedEdgeSlackMilliseconds: Int64 = AdvertRotation.minLeadMilliseconds + writerClockSlackMilliseconds
        /// How far behind a writer's clock may run and still have rotated before rule 4 reads it again.
        public static let writerClockSlackMilliseconds: Int64 = 5000

        /// Half a minute after a failure, ten minutes after a stranger, a minute of quiet, and a blinded payload forgotten
        /// 35 to 65 s past its slot's edge, unless told otherwise.
        public init(
            readTimeoutMilliseconds: Int64 = 12_000,
            retryMilliseconds: Int64 = 30_000,
            strangerRetryMilliseconds: Int64 = 600_000,
            quietMilliseconds: Int64 = 60_000,
            blindedEdgeSlackMilliseconds: Int64 = Self.defaultBlindedEdgeSlackMilliseconds,
            blindedEdgeJitterMilliseconds: Int64 = 30_000
        ) {
            self.readTimeoutMilliseconds = readTimeoutMilliseconds
            self.retryMilliseconds = retryMilliseconds
            self.strangerRetryMilliseconds = strangerRetryMilliseconds
            self.quietMilliseconds = quietMilliseconds
            self.blindedEdgeSlackMilliseconds = blindedEdgeSlackMilliseconds
            self.blindedEdgeJitterMilliseconds = blindedEdgeJitterMilliseconds
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
    /// The addresses rule 5 forgot once (``noReply(at:)``), until a read finds the flag there or another rule forgets them.
    private var forgotForNoReply: Set<RadioAddress> = []
    /// Scan time run up before the scan now running, and when that scan started on the monotonic clock.
    private var scannedBefore: Int64 = 0
    private var scanningSince: Int64?
    /// Each blinded payload's read and forget, on the wall clock (rule 4).
    private var blindedSpans: [RadioAddress: (readAt: Int64, until: Int64)] = [:]
    /// The jitter's generator: SplitMix64 from the seed the radio drew.
    private var jitterState: UInt64

    /// Nothing read yet. `jitterSeed` spreads rule 4's forgets; a radio draws it at random, so readers of one writer differ.
    public init(configuration: Configuration = Configuration(), jitterSeed: UInt64 = 0) {
        self.configuration = configuration
        jitterState = jitterSeed
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

    /// The read of `address` ended, at `now` on the monotonic clock and `wall` on the wall clock, which times a blinded
    /// payload's forget (rule 4). An outcome for any other address answers a read already given up on, and is ignored.
    public mutating func finish(_ address: RadioAddress, _ outcome: Outcome, now: Int64, wall: Int64) {
        guard current?.address == address else {
            return
        }
        current = nil
        switch outcome {
        case .read(let payload):
            payloads[address] = payload
            lastHeard[address] = scanTime(now: now)
            if payload.blinded {
                let edge = (BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds
                blindedSpans[address] = (wall, edge + configuration.blindedEdgeSlackMilliseconds + jitter())
            }
            if payload.seals {
                forgotForNoReply.remove(address)
            }
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
        blindedSpans[address] = nil
        forgotForNoReply.remove(address)
    }

    // MARK: The payload's lifetime

    /// Rule 2: the HELLO on a link to `address` named `node`, the dialer's on a link we accepted or the reply on one we
    /// dialed, and told `told` (its `t`), and `announced` is the tag that node announced to us (`TAG_NEXT`) and we hold. A
    /// clear payload there that names another node is forgotten; a blinded one whose tag is neither `told` nor `announced`
    /// too. The answer says whether one was.
    public mutating func helloNamed(_ node: NodeId, told: NodeId?, announced: NodeId?, at address: RadioAddress) -> Bool {
        guard let payload = payloads[address] else {
            return false
        }
        let names = payload.blinded ? [told, announced].contains(payload.advertised) : payload.advertised == node
        guard !names else {
            return false
        }
        forget(address)
        return true
    }

    /// Rule 4: forgets every blinded payload whose slot edge, with its slack and jitter, has passed at `wall`, or that was
    /// read at a later wall time than `wall` (the clock went back), and answers those, in order. An address in `linked`,
    /// which a link or a read holds, keeps its payload, as rule 3 keeps one: the link's own claims attribute the tag it names
    /// (`AdvertAliases`), and a radio reads no address a link holds, so the forget comes at the first check after the link
    /// ends, and the next advert there is read again, once.
    public mutating func forgetPastEdge(wall: Int64, linked: Set<RadioAddress>) -> [RadioAddress] {
        let past = blindedSpans.filter { !linked.contains($0.key) && (wall >= $0.value.until || wall < $0.value.readAt) }.keys
        let forgotten = past.sorted { $0.rawValue < $1.rawValue }
        for address in forgotten {
            forget(address)
        }
        return forgotten
    }

    /// SplitMix64's increment and mixing multipliers and shifts (Steele, Lea and Flood, 2014).
    private static let splitMixGamma: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let splitMixMultipliers: (UInt64, UInt64) = (0xBF58_476D_1CE4_E5B9, 0x94D0_49BB_1331_11EB)
    private static let splitMixShifts: (UInt64, UInt64) = (30, 27)
    private static let splitMixLastShift: UInt64 = 31

    /// A draw in `0..<blindedEdgeJitterMilliseconds` (SplitMix64).
    private mutating func jitter() -> Int64 {
        let span = UInt64(max(1, configuration.blindedEdgeJitterMilliseconds))
        jitterState &+= Self.splitMixGamma
        var mixed = jitterState
        mixed = (mixed ^ (mixed >> Self.splitMixShifts.0)) &* Self.splitMixMultipliers.0
        mixed = (mixed ^ (mixed >> Self.splitMixShifts.1)) &* Self.splitMixMultipliers.1
        mixed ^= mixed >> Self.splitMixLastShift
        return Int64(mixed % span)
    }

    /// Rule 5: our plain dial to `address`, whose HELLO carried ``Capabilities/linkSeal``, got no reply. A payload there
    /// that is clear and lacks `FLAG_LINK_SEAL` is forgotten, once per address, and the answer says whether one was; a
    /// blinded payload never is (the `blind-gatt-reads` contract, §6). The mark stays until a read there finds the flag or
    /// another rule forgets the address, so a peer that never upgraded costs one extra read, not one per dial.
    public mutating func noReply(at address: RadioAddress) -> Bool {
        guard let payload = payloads[address], !payload.blinded, !payload.seals, !forgotForNoReply.contains(address) else {
            return false
        }
        forget(address)
        forgotForNoReply.insert(address)
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
            forgotForNoReply.remove(address)
            if payloads[address] != nil {
                forget(address)
                forgotten.append(address)
            }
        }
        return forgotten
    }
}
