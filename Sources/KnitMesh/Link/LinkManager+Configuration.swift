/// The link layer's tunables, apart from the manager so that its body stays the state machine itself.
extension LinkManager {
    /// The link layer's tunables.
    public struct Configuration: Sendable {
        /// How long a HELLO may take, each way (`ACCEPT_HELLO_TIMEOUT_MS`).
        public var helloTimeoutMilliseconds: Int64
        /// How long a dial may take to open (`CONNECT_TIMEOUT_MS`).
        public var connectTimeoutMilliseconds: Int64
        /// How long a custody change waits before it re-advertises, so a burst costs one advert
        /// (`CUE_READVERTISE_DEBOUNCE_MS`).
        public var advertDebounceMilliseconds: Int64
        /// The largest single write: Android caps its own at 8 KiB.
        public var maxWriteBytes: Int
        /// What a link scores for eviction while its peer has not once been sighted since the link came up (every
        /// inbound iPhone): the promotion floor, as A1 has it, not −127.
        public var unsightedLinkRssi: Double
        /// What a link scores once its peer, sighted during the link, has left presence: shed first, as on Android.
        public var absentLinkRssi: Double
        /// How old a held link must be before a second dial from the same unsighted peer may replace it
        /// (A1's `REPLACE_MIN_HOLD_MS`). The HELLO is unauthenticated, so this bounds how often a device that
        /// claims the peer's id can cut its link.
        public var replaceMinHoldMilliseconds: Int64
        /// How often a link's doorbell rings, at most, while frames go out on it. A ring wakes a suspended iPhone for
        /// about 9 s (iOS 27), so ringing at most every 5 s, and once more after the last frame of a burst, has every
        /// frame read within about 5 s of reaching the link. 0 never rings.
        public var ringIntervalMilliseconds: Int64
        /// How many wakes one spell of seeking may spend with no link before it stops until the front (ADR 2026-10.mueg).
        /// Each match of a scan for Knit's UUID resumes a suspended iPhone for about 10 s, and near five phones that kept
        /// Knit running three quarters of the time (P8's scan-filter check).
        public var seekWakeBudget: Int
        /// How long one wake lasts: a sighting this long after the current wake began starts another, since iOS resumes a
        /// suspended app for about 10 s at a time.
        public var seekWakeMilliseconds: Int64
        /// How long past the ordinary dwell a node at the front that serves the doorbell waits for a flagged peer above
        /// it to dial first, before it dials that peer itself (``LinkManager/givesHeadStart``, interop-audit finding
        /// AND-2). 12 s of dwell and 15 s of head start leave about 3 s of a dial inside MVP item 2's 30 s.
        public var headStartMilliseconds: Int64
        /// How long a link must have held for its loss to start a fresh spell of seeking. One that flapped carries the
        /// spell's wakes on, so a peer that links and drops cannot keep a lonely iPhone awake.
        public var seekSpellResetMilliseconds: Int64
        /// How much longer a dial or HELLO may take when its deadline passed while iOS had the app suspended: on resume,
        /// the timer and what the radio reported meanwhile reach the link manager in no fixed order.
        public var lateDeadlineGraceMilliseconds: Int64
        /// The most bytes one FILE_CHUNK carries: Android's `FILE_CHUNK_BYTES` (`LinkFraming.kt:85`).
        public var fileChunkBytes: Int
        /// How fast files stream when no window clocks them, over every link together: Android's
        /// `BLE_PACE_BYTES_PER_SEC` (`CodedPhyPolicy.kt:311`), split evenly among the links feeding at that pace, each
        /// chunk two seconds of a link's share (knit-next ADR 2026-10.8jwn). Each chunk waits its own share of a second
        /// after the last, so a resumed app never bursts to catch up. 0 does not pace.
        public var filePaceBudgetBytesPerSecond: Int64
        /// Whether a file is clocked by its receiver's reports (``FeedWindow``, knit-next ADR 2026-10.5buf) when the
        /// peer's HELLO carries ``Capabilities/blobHave``, and whether a file streaming in is reported at the window's
        /// cadence: Android's `BLE_FEED_WINDOW`. Off, files go at the pace and are reported every two seconds.
        public var feedWindow: Bool
        /// The most of a peer's own AVATAR push to keep. Android's photos are 256-pixel JPEGs of a few tens of KiB and
        /// it caps none but the 8 MiB file (ADR 2026-10.nh55), so this only stops a peer filling memory with a "photo".
        public var maxAvatarFileBytes: Int
        /// The most bytes of partial files kept at once across every link, so six links each streaming 8 MiB cannot
        /// hold 48 MiB in a suspended app.
        public var maxBufferedFileBytes: Int
        /// Whom to link.
        public var promotion: PromotionPolicy.Configuration
        /// How long to wait after failures.
        public var backoff: ConnectBackoff.Configuration
        /// How sightings smooth and linger.
        public var presence: PresenceTracker.Configuration

        /// knit-next's values unless told otherwise.
        public init(
            helloTimeoutMilliseconds: Int64 = 5000,
            connectTimeoutMilliseconds: Int64 = 12_000,
            advertDebounceMilliseconds: Int64 = 1500,
            maxWriteBytes: Int = 8192,
            unsightedLinkRssi: Double = -90,
            absentLinkRssi: Double = -127,
            replaceMinHoldMilliseconds: Int64 = 30_000,
            ringIntervalMilliseconds: Int64 = 5000,
            seekWakeBudget: Int = 8,
            seekWakeMilliseconds: Int64 = 10_000,
            seekSpellResetMilliseconds: Int64 = 30_000,
            headStartMilliseconds: Int64 = 15_000,
            lateDeadlineGraceMilliseconds: Int64 = 3000,
            fileChunkBytes: Int = 16_384,
            filePaceBudgetBytesPerSecond: Int64 = 4096,
            feedWindow: Bool = true,
            maxAvatarFileBytes: Int = 1_048_576,
            maxBufferedFileBytes: Int = 16_777_216,
            promotion: PromotionPolicy.Configuration = PromotionPolicy.Configuration(),
            backoff: ConnectBackoff.Configuration = ConnectBackoff.Configuration(),
            presence: PresenceTracker.Configuration = PresenceTracker.Configuration()
        ) {
            self.helloTimeoutMilliseconds = helloTimeoutMilliseconds
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.advertDebounceMilliseconds = advertDebounceMilliseconds
            self.maxWriteBytes = maxWriteBytes
            self.unsightedLinkRssi = unsightedLinkRssi
            self.absentLinkRssi = absentLinkRssi
            self.replaceMinHoldMilliseconds = replaceMinHoldMilliseconds
            self.ringIntervalMilliseconds = ringIntervalMilliseconds
            self.seekWakeBudget = seekWakeBudget
            self.seekWakeMilliseconds = seekWakeMilliseconds
            self.seekSpellResetMilliseconds = seekSpellResetMilliseconds
            self.headStartMilliseconds = headStartMilliseconds
            self.lateDeadlineGraceMilliseconds = lateDeadlineGraceMilliseconds
            self.fileChunkBytes = fileChunkBytes
            self.filePaceBudgetBytesPerSecond = filePaceBudgetBytesPerSecond
            self.feedWindow = feedWindow
            self.maxAvatarFileBytes = maxAvatarFileBytes
            self.maxBufferedFileBytes = maxBufferedFileBytes
            self.promotion = promotion
            self.backoff = backoff
            self.presence = presence
        }
    }
}
