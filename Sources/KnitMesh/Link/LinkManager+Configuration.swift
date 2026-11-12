public import KnitWire

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
        /// (A1's `REPLACE_MIN_HOLD_MS`). An unproven HELLO is unauthenticated, so this bounds how often a device that
        /// claims the id of a peer that cannot prove itself can cut its link. A proven link is replaced only by a proof.
        public var replaceMinHoldMilliseconds: Int64
        /// How long after the radio closed a proven link a dialer proving the same id is admitted though our order says we
        /// dial it (``RelinkWindow``): iOS ends a link when the same device connects to it again, and the iPhone redials
        /// over the reader's connection within a second. 30 s covers the redialer's 8 to 12 s backoff and a dial's 12 s
        /// connect timeout. 0 never admits.
        public var relinkWindowMilliseconds: Int64
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
        /// AND-2). 12 s of dwell and 12 s of head start leave about 6 s inside MVP item 2's 30 s for the first sighting
        /// and the dial, which took 4.7 s to a screen-off Pixel 3. A 15 s head start put those links at 29.6 to 32.0 s
        /// (ADR 2026-10.6eyf).
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
        /// The most of a peer's own AVATAR push to keep, and of an ATTACHMENT fetched only as a profile photo
        /// (``acceptFiles(_:resumable:photoOnly:)``): ``FileIntake/maxAvatarBytes`` unless a test says otherwise. Both
        /// platforms' photos are 256-pixel JPEGs of a few tens of KiB, so only a photo no honest build makes reaches it.
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
        /// A test's seam (ADR 2026-11.sv5t): takes ``Capabilities/blindAdvert`` out of our HELLO only, and
        /// ``Capabilities/linkSeal`` with it (a build from before the reader predates the seal), as such a build would send,
        /// so a scripted blinding peer's `RefuseLegacy` (`BleAdmissionPolicy.kt:115`) can be met, as Android's lab withholds
        /// a capability (`MeshManager.withheldCapabilities`). The app never sets it. It shapes our HELLO alone: a stand-in's
        /// dials still open sealed toward a flagged advert, so a test writes the stand-in's HELLO by hand (``ourHello(addressing:)``),
        /// and one that dials through promotion sets ``LinkManager/sealSwitch`` to `.off` too, as Android v2.11.0 plays it.
        public var withholdsBlindAdvert: Bool
        /// Whether this build may air a rotating tag instead of its id (Android's `BLIND_ADVERT`; ADR 2026-11.prsp), the build
        /// gate: true in every debug build's factory and in knit-peer, false in release, which then has no switch. While it
        /// holds, ``LinkManager/setBlinding(_:)`` turns the runtime switch on and off.
        public var blindsAdvert: Bool
        /// The runtime switch at construction (``LinkManager/setBlinding(_:)``): a debug build's stored `-blind` choice or its
        /// default, knit-peer's `--blind`. It never sets the gate, so a process started with it off can still be turned on
        /// from the bridge (ADR 2026-11.prsp, "Two gates").
        public var blindSwitchOn: Bool
        /// The notification that says the wall clock was set, which `Mesh` hands the links as ``LinkManager/wallClockChanged()``:
        /// `nil` for the system's `NSSystemClockDidChange`. A test names its own, so its post reaches no other mesh in the
        /// process.
        public var clockChangeName: String?

        /// knit-next's values unless told otherwise.
        public init(
            helloTimeoutMilliseconds: Int64 = 5000,
            connectTimeoutMilliseconds: Int64 = 12_000,
            advertDebounceMilliseconds: Int64 = 1500,
            maxWriteBytes: Int = 8192,
            unsightedLinkRssi: Double = -90,
            absentLinkRssi: Double = -127,
            replaceMinHoldMilliseconds: Int64 = 30_000,
            relinkWindowMilliseconds: Int64 = 30_000,
            ringIntervalMilliseconds: Int64 = 5000,
            seekWakeBudget: Int = 8,
            seekWakeMilliseconds: Int64 = 10_000,
            seekSpellResetMilliseconds: Int64 = 30_000,
            headStartMilliseconds: Int64 = 12_000,
            lateDeadlineGraceMilliseconds: Int64 = 3000,
            fileChunkBytes: Int = 16_384,
            filePaceBudgetBytesPerSecond: Int64 = 4096,
            feedWindow: Bool = true,
            maxAvatarFileBytes: Int = FileIntake.maxAvatarBytes,
            maxBufferedFileBytes: Int = 16_777_216,
            promotion: PromotionPolicy.Configuration = PromotionPolicy.Configuration(),
            backoff: ConnectBackoff.Configuration = ConnectBackoff.Configuration(),
            presence: PresenceTracker.Configuration = PresenceTracker.Configuration(),
            withholdsBlindAdvert: Bool = false,
            blindsAdvert: Bool = false,
            blindSwitchOn: Bool = true,
            clockChangeName: String? = nil
        ) {
            self.helloTimeoutMilliseconds = helloTimeoutMilliseconds
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.advertDebounceMilliseconds = advertDebounceMilliseconds
            self.maxWriteBytes = maxWriteBytes
            self.unsightedLinkRssi = unsightedLinkRssi
            self.absentLinkRssi = absentLinkRssi
            self.replaceMinHoldMilliseconds = replaceMinHoldMilliseconds
            self.relinkWindowMilliseconds = relinkWindowMilliseconds
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
            self.withholdsBlindAdvert = withholdsBlindAdvert
            self.blindsAdvert = blindsAdvert
            self.blindSwitchOn = blindSwitchOn
            self.clockChangeName = clockChangeName
        }
    }
}
