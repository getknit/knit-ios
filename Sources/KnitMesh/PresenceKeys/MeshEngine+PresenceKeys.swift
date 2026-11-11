import KnitCrypto
import KnitStore
import KnitWire

/// The presence keys' receive side (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): a ctl 11 is filed for its sender inside
/// the ratchet open that delivered it (`applyPresenceKey` and `notePresenceKey`, `mesh/InboundPipeline.kt:1959-1995` at
/// knit-next `cad69c77b`), and the direct contacts' keys are listed to the radio through ``MeshTransport/listPresenceKeys(_:)``
/// (`MeshManager.feedPresenceKeys`, `MeshManager.kt:1414-1426`), a leaver's deleted as they go (`PresenceKeyEngine.dropLeavers`,
/// `PresenceKeyEngine.kt:506-521`). The same pass settles and sends our own keys (`MeshEngine+OwnPresenceKeys.swift`, ADR
/// 2026-11.prsp).
///
/// A key is stored from any sender with a peer row who is not us, with no direct-contact, relay or link check, as on
/// Android: the listing is the gate, so a stranger's key is held, never listed, until the user accepts them, and goes at the
/// next session's first pass if they never do.
///
/// Nothing here writes a key, a tag, or a sweep's moment to a log line (xp6d's 2026-11-04 amendment): the receive line
/// carries counts, and the sweeps count only.
extension MeshEngine {
    /// Files `payload`, a ctl 11 from `sender`, inside the open's unit, under the era the open committed (`applyPresenceKey`,
    /// `InboundPipeline.kt:1959-1974`), and answers the verdict for after the commit, or `nil` for a ctl 11 with no key.
    /// The sender is the verified one the open ran for, never the envelope's text. A refusal writes nothing and leaves the
    /// open to commit; only a store's failure fails the unit.
    func applyPresenceKey(_ payload: PresenceKeyPayload?, from sender: NodeId, under: OpenedUnder) -> PresenceKeyPolicy.Verdict? {
        guard let payload else {
            return nil
        }
        guard let offered = PresenceKeyPolicy.keysIn(payload) else {
            return .refused(.malformed)
        }
        guard sender != nodeId, stores.peers.peer(sender) != nil else {
            return .refused(.unknownSender)
        }
        let held = stores.presenceKeys.keys(of: sender).map(\.held)
        let verdict = PresenceKeyPolicy.receive(held: held, frame: offered, openedTag: under.rootTag, active: under.active)
        if case .store(let rows, _, _) = verdict {
            stores.presenceKeys.replaceKeys(of: sender, with: rows, now: clock.wallMilliseconds())
        }
        return verdict
    }

    /// Counts what ``applyPresenceKey(_:from:under:)`` decided, once its unit committed (`notePresenceKey`,
    /// `InboundPipeline.kt:1977-1995`). Counts only, never a key, a tag or a generation beside the sender; the id and sender
    /// of a refused one go to the debug line every drop writes.
    func notePresenceKey(_ verdict: PresenceKeyPolicy.Verdict, _ envelope: RelayEnvelope) {
        switch verdict {
        case .store(let rows, let replaced, let added):
            if replaced {
                presenceKeyFeed.counts.replaced += 1
            } else {
                presenceKeyFeed.counts.stored += 1
            }
            notePresenceKeyInputsChanged()
            log.log(.info, "mesh presence key: \(added) stored\(replaced ? " (a new era)" : ""), \(rows.count) held")
        case .refused(let why):
            drop(.presenceKeyRefused, envelope)
            log.log(.info, "mesh presence key refused: \(why)")
        case .noOp:
            break
        }
    }

    /// What the presence keys' receive side did so far (ADR 2026-11.sv5t).
    public var presenceKeyCounts: PresenceKeyCounts { presenceKeyFeed.counts }

    /// Marks the listing's inputs as moved, so the next ``feedPresenceKeys()`` reads it again: a key stored, an accept, a
    /// verify or un-verify, a block or unblock, a block that followed new keys, a card added, our own DM, a session's start.
    func notePresenceKeyInputsChanged() {
        presenceKeyFeed.revision += 1
    }

    /// Starts a session's feed, as ``Mesh/start()`` does at every start, a restart after a stop included (an engine's first
    /// session starts with it): its first pass deletes the keys of everyone who is not a direct contact, since one who left
    /// while the mesh was stopped is in no set it can read leavers from (`dropLeavers`' `before == null`,
    /// `PresenceKeyEngine.kt:511-512`), and trims what we sent to the direct contacts. Our published key and the departed
    /// and blocked sets go back to `nil` until that pass commits (`beginSession`, `:253-260`), so a block
    /// made while the mesh was stopped is a fresh pair before the radio sees any key. Before the radio starts.
    func startPresenceKeySession() {
        presenceKeyFeed.lastDirect = nil
        presenceKeyFeed.departed = nil
        presenceKeyFeed.blocked = nil
        presenceKeyFeed.published = nil
        presenceKeyFeed.counts.ownGeneration = nil
        transport.ownPresenceKeyChanged(nil)
        noteOwnPresenceKeyPassOwed()
        notePresenceKeyInputsChanged()
    }

    /// One pass of the presence keys (``Mesh`` calls it after every entry, as it re-reads the digest cue), when anything that
    /// could change the listing moved since the last, or our own keys' pass is owed (the heal, a link-up's delayed pass, a
    /// mark, a session's start):
    /// 1. One store unit reads the direct contacts, deletes the leavers' stored keys (at a session's first pass every
    ///    non-contact's), reads each contact's keys, newest first, at most three, and settles our own keys
    ///    (``settleOwnKeys(direct:now:clockAdvanceAllowed:)``).
    /// 2. Nothing is deleted, listed, published, sent or remembered unless it commits: outside one a failing read answers
    ///    nobody, and a first pass would delete every key and list none, which Android, remembering what it sent each
    ///    contact per root, would not resend for up to a week. After a failure the last direct set, the last listing and
    ///    our published key stand, and the next call tries again.
    /// 3. Once it commits: the listing goes whole to ``MeshTransport/listPresenceKeys(_:)``, which bounds a contact's churn
    ///    itself, when the revision moved; our key and the departed set are published (``publishOwnKeys(_:)``); then
    ///    each linked contact is sent what it is owed (``sendOwedPresenceKeys(rows:direct:)``).
    ///
    /// The leavers are counted, never logged in a release build (xp6d's 2026-11-04 amendment: a dated sweep says when the
    /// user blocked someone).
    public func feedPresenceKeys() {
        let revision = presenceKeyFeed.revision
        let listingDue = presenceKeyFeed.listed != revision
        // The day's floor reads the monotonic clock, which keeps running while the phone sleeps (`SystemClock`'s
        // `ContinuousClock`, Android's `elapsedRealtime`): a process restart allows one advance.
        let elapsed = clock.monotonicMilliseconds()
        // While our keys' settle sits out, an owed pass waits for its deadline and opens no unit unless the listing is due.
        let sittingOut = presenceKeyFeed.ownSettleRetryAt.map { elapsed < $0 } ?? false
        guard listingDue || (presenceKeyFeed.ownPassOwed && !sittingOut) else {
            return
        }
        let before = presenceKeyFeed.lastDirect
        let now = clock.wallMilliseconds()
        let clockAdvanceAllowed = presenceKeyFeed.lastClockAdvanceAt.map { elapsed - $0 >= PresenceKeyPolicy.dayMilliseconds } ?? true
        // A unit that failed with our keys' settle in it may have written the identity's item for rows it never kept: the
        // settle sits out a minute after one, so a store that keeps failing costs the Keychain no write at every settle.
        let settlesOwn = configuration.sendsOwnPresenceKeys && !sittingOut
        let unit = stores.transactor.atomically { () -> PresenceKeyFeed.Pass? in
            let direct = directContacts()
            let leavers = before.map { $0.subtracting(direct) } ?? Set(stores.presenceKeys.peersWithKeys()).subtracting(direct)
            stores.presenceKeys.deleteKeys(of: leavers)
            let listing = stores.presenceKeys.keys(of: direct).mapValues { keys in
                keys.prefix(PresenceKeyPolicy.peerGenerations).map(\.held.key)
            }
            let own =
                settlesOwn
                ? settleOwnKeys(direct: direct, now: now, clockAdvanceAllowed: clockAdvanceAllowed)
                : OwnKeySettle(reachedNone: !configuration.sendsOwnPresenceKeys, deferred: configuration.sendsOwnPresenceKeys)
            return PresenceKeyFeed.Pass(
                direct: direct,
                leavers: leavers,
                listing: listing,
                own: own,
                rows: stores.presenceKeys.ownKeys(),
                blocked: blockedForTagNext()
            )
        }
        guard case .committed(let pass) = unit else {
            if settlesOwn {
                presenceKeyFeed.ownSettleRetryAt = elapsed + Self.ownSettleRetryMilliseconds
            }
            // Once per revision: a store that keeps failing is retried at every settle, and says so once.
            if presenceKeyFeed.warned != revision {
                presenceKeyFeed.warned = revision
                log.log(.warning, "mesh presence key listing skipped: a store failed")
            }
            return
        }
        actOnPresenceKeyPass(pass, firstOfSession: before == nil, listing: listingDue ? revision : nil, elapsed: elapsed)
    }

    /// What a committed pass leaves for after its unit: the memory it moves, the listing when `listing` names the revision
    /// it was due for, our key published, and the seals owed.
    private func actOnPresenceKeyPass(_ pass: PresenceKeyFeed.Pass, firstOfSession: Bool, listing: Int?, elapsed: Int64) {
        if firstOfSession {
            // A session's first pass forgets what it sent anyone no longer a direct contact (`dropLeavers`, `:509-511`).
            presenceKeyFeed.sent = presenceKeyFeed.sent.filter { pass.direct.contains($0.key) }
        }
        for leaver in pass.leavers {
            presenceKeyFeed.sent[leaver] = nil
        }
        presenceKeyFeed.lastDirect = pass.direct
        if let listing {
            presenceKeyFeed.listed = listing
        }
        // A settle sat out leaves our keys' pass owed, for the first settle past the wait.
        presenceKeyFeed.ownPassOwed = pass.own.deferred
        presenceKeyFeed.ownSettleRetryAt = pass.own.deferred ? presenceKeyFeed.ownSettleRetryAt : nil
        presenceKeyFeed.counts.leavers += pass.leavers.count
        if pass.own.clockAdvanced {
            presenceKeyFeed.lastClockAdvanceAt = elapsed
        }
        notePresenceKeyPass(pass)
        if listing != nil {
            presenceKeyFeed.lastListing = pass.listing
            transport.listPresenceKeys(pass.listing)
        }
        publishOwnKeys(pass)
        if pass.own.mintFailed == nil, !pass.own.deferred {
            sendOwedPresenceKeys(rows: pass.rows, direct: pass.direct)
        }
    }

    /// Counts what a committed pass did, and writes its trail where the configuration asks: counts and generations, never a
    /// key or a tag.
    private func notePresenceKeyPass(_ pass: PresenceKeyFeed.Pass) {
        presenceKeyFeed.counts.rotations += pass.own.minted > 0 ? 1 : 0
        // A node that keeps no identity's item (a demo, a test) mints nothing, and has nothing to say about it.
        if let failed = pass.own.mintFailed, failed != .noItem {
            presenceKeyFeed.counts.mintsFailed += 1
            log.log(.warning, "mesh presence key not minted: \(failed)")
        }
        if !pass.leavers.isEmpty {
            presenceKeyTrail("mesh presence keys of \(pass.leavers.count) former direct contacts deleted")
        }
        if pass.own.minted > 0, let current = PresenceKeyPolicy.keysOf(pass.rows).current?.generation {
            presenceKeyTrail("mesh presence key \(pass.own.steps.map { "\($0)" }.joined(separator: ", ")): current g=\(current)")
        }
        presenceKeyTrail(
            "mesh presence key pass: \(pass.direct.count) direct contacts, \(pass.own.reachedNone ? "settled" : "unsettled")")
    }

    /// Everyone `TAG_NEXT` must not reach for a block (`tagNextBlocked`, `MeshManager.kt`): every node id blocked, and every
    /// direct-contact candidate or linked peer whose pinned device tag is. Read inside the pass's unit.
    private func blockedForTagNext() -> Set<NodeId> {
        let known = Acquaintances(reading: self)
        let candidates = DirectContacts.candidates(accepted: known.accepted, verified: known.verified, authored: known.authored)
        let tagged = candidates.union(transport.neighbors.map(\.nodeId)).filter { peer in
            stores.peers.peer(peer)?.deviceTag.map(stores.blocks.isBlocked(deviceTag:)) == true
        }
        return stores.blocks.blockedNodeIds().union(tagged)
    }

    /// Unlists `peer`, whom the user just blocked, at once, and every listed peer whose row carries the device tag the block
    /// covers: the last listing pushed, less them, with no store read the removal needs, so a store that keeps failing
    /// (one damaged row fails every feed's unit) never leaves a blocked contact's tag resolving by key. A drop applies at
    /// once in the link manager (``KeyChurnLimiter``). Their keys go at the next feed that commits, which still counts them
    /// as leavers. Nothing is logged.
    func unlistBlocked(_ peer: NodeId, deviceTag: String?) {
        // Our own key goes at once too, and `TAG_NEXT` refuses them, whatever the store does (ADR 2026-11.prsp).
        withdrawOwnKey(from: [peer])
        guard var listing = presenceKeyFeed.lastListing else {
            return
        }
        // A row read outside a unit answers nothing when it fails, which only leaves a peer listed until the next feed.
        let tagged = deviceTag.map { tag in
            Set(listing.keys.filter { stores.peers.peer($0)?.deviceTag.map(ExactKey.init) == ExactKey(tag) })
        }
        let gone = (tagged ?? []).union([peer])
        guard !gone.isDisjoint(with: listing.keys) else {
            return
        }
        for id in gone {
            listing[id] = nil
        }
        presenceKeyFeed.lastListing = listing
        transport.listPresenceKeys(listing)
    }
}

/// The era a DM ratchet frame opened under, as its open committed it (`RatchetSessions.OpenedUnder`,
/// `RatchetSessions.kt:251-254` at knit-next `cad69c77b`): read from the open's own delta inside its unit, never from a later
/// read of the session.
internal struct OpenedUnder: Equatable {
    /// The tag of the root that opened the frame.
    let rootTag: Int64
    /// Whether that is the root the session holds once the open commits (the pz9g predicate).
    let active: Bool

    /// The era `delta` committed (``KnitCrypto/RatchetEngine/OpenDelta/openedUnderActiveRoot``).
    init(_ delta: RatchetEngine.OpenDelta) {
        self.init(rootTag: delta.openedRootTag, active: delta.openedUnderActiveRoot)
    }

    /// The era under the root tagged `rootTag`, `active` or not.
    init(rootTag: Int64, active: Bool) {
        self.rootTag = rootTag
        self.active = active
    }
}

/// What the presence key feed keeps in memory between passes (``MeshEngine/feedPresenceKeys()``).
internal struct PresenceKeyFeed {
    /// One pass that committed.
    struct Pass {
        /// The direct contacts it read.
        let direct: Set<NodeId>
        /// Who left the direct contacts, whose keys it deleted.
        let leavers: Set<NodeId>
        /// Each direct contact's keys, newest first.
        let listing: [NodeId: [PresenceKey]]
        /// What its settle of our own keys came to.
        let own: OwnKeySettle
        /// Our own key rows once it settled.
        let rows: [OwnPresenceKeyRecord]
        /// Everyone a block keeps from `TAG_NEXT`.
        let blocked: Set<NodeId>
    }

    /// What a peer was last sealed: the generations handed over and the tag of the root the seal committed (`Sent`, `:166-169`),
    /// and the link it was queued on and when, on the monotonic clock.
    struct SentKeys: Equatable {
        let generations: [Int64]
        let rootTag: Int64
        /// The peer's link it was queued on, `nil` for a link the engine was never told of.
        let link: Int?
        let queuedAt: Int64
    }

    /// Moves whenever the listing's inputs may have.
    var revision = 0
    /// The revision last listed, or `nil` before the first listing.
    var listed: Int?
    /// The direct contacts the last committed pass read, or `nil` before a session's first pass.
    var lastDirect: Set<NodeId>?
    /// The listing last pushed, which a block unlists from at once (``MeshEngine/unlistBlocked(_:deviceTag:)``), or `nil`
    /// before the first.
    var lastListing: [NodeId: [PresenceKey]]?
    /// The revision whose failure was last logged.
    var warned: Int?
    /// What the presence keys did so far.
    var counts = PresenceKeyCounts()

    /// Whether our own keys' pass is owed whatever the revision says.
    var ownPassOwed = false
    /// Our key as the radio was last handed it.
    var published: OwnPresenceKey?
    /// Who left one of our keys' audiences while a kept generation was live, or `nil` before this session's pass read it.
    var departed: Set<NodeId>?
    /// Everyone a block keeps from `TAG_NEXT`, or `nil` before this session's pass read it.
    var blocked: Set<NodeId>?
    /// When the last clock or mark advance committed, on the monotonic clock, or `nil` since the process started.
    var lastClockAdvanceAt: Int64?
    /// What each peer was last sealed, in memory: a restart sends again.
    var sent: [NodeId: SentKeys] = [:]
    /// The delayed link-up passes owed, by peer, on the monotonic clock.
    var linkUps: [NodeId: Int64] = [:]
    /// The generations whose mark already asked for a pass.
    var markPasses: Set<Int64> = []
    /// When our keys' settle may run again after a unit that held one failed, on the monotonic clock, or `nil`.
    var ownSettleRetryAt: Int64?
    /// Each peer's links so far, counted at each link-up.
    var linkSequence: [NodeId: Int] = [:]
}

/// What the presence keys did so far (Android's `onPresenceKeyStored`, `onPresenceKeyReplaced`, `onPresenceKeySent`,
/// `onPresenceKeyRotated` and the mark's counters; a refusal is a ``DropReason/presenceKeyRefused``). Counts and our own
/// current generation only, with no time, no key and no peer.
public struct PresenceKeyCounts: Sendable, Equatable {
    /// Frames whose keys were added to their sender's era, or stored with nothing held.
    public internal(set) var stored = 0
    /// Frames whose keys replaced every key held for their sender: a new era.
    public internal(set) var replaced = 0
    /// Peers who left the direct contacts, or were found not to be one at a session's first pass, and whose keys went.
    public internal(set) var leavers = 0
    /// Our current key's generation as the radio was last handed it, or `nil` with none. A generation is a wall-clock
    /// millisecond value, so this dates our latest mint, a block's fresh pair included: it reaches only the debug bridge's
    /// and knit-peer's `status`, never a release log.
    public internal(set) var ownGeneration: Int64?
    /// Passes that minted one of our keys.
    public internal(set) var rotations = 0
    /// Passes whose mint the identity's item could not record.
    public internal(set) var mintsFailed = 0
    /// Ctl 11 frames of ours a proven link took.
    public internal(set) var sent = 0
    /// Ctl 11 frames sealed that found no proven link, and were forgotten to be sealed again.
    public internal(set) var sendsFailed = 0
    /// The advertiser's mark writes, those committed at `synchronous=FULL`, those refused for a key no longer current,
    /// those that would not have run at FULL, and those that failed or were asked inside a unit.
    public internal(set) var markWrites = 0
    public internal(set) var marksDurable = 0
    public internal(set) var markRefused = 0
    public internal(set) var markNotFull = 0
    public internal(set) var markFailed = 0
}
