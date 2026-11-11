import KnitCrypto
import KnitStore
import KnitWire

/// Our own presence keys (ADR 2026-11.prsp, "Our own keys"): minted, rotated and sealed to our linked direct contacts, the
/// send half of knit-next's `PresenceKeyEngine` (`mesh/PresenceKeyEngine.kt` at `cad69c77b`) on this engine's one actor.
///
/// **One pass, in this order** (``feedPresenceKeys()``, which also lists the contacts' keys):
/// 1. One store unit settles the direct contacts, `due` and the rows it asks for, the leavers' stored keys and the departed
///    set. A mint writes its generation to the identity's item before the row that uses it (``PrekeyRing/setPresenceLastGeneration(_:)``),
///    and a write there that throws fails the mint.
/// 2. Once it commits, our key and the departed set are published (``publishOwnKeys(_:)``).
/// 3. Then each owed peer gets one outermost ``sealControl(_:to:in:plan:)``: sealed, the ratchet settles, the
///    ledger records it, then it goes over the proven link; anything else records and sends nothing.
///
/// Hooks only mark the pass owed (``notePresenceKeyInputsChanged()``, ``noteOwnPresenceKeyPassOwed()``); none seals or
/// publishes inside a unit its caller opened.
///
/// **The ledger** of what each linked contact was last sent, the generations and the root the seal committed, lives in
/// memory (`sent`, `PresenceKeyEngine.kt:174`): a restart sends again. It outlives a link, so a relink with nothing changed
/// sends nothing, and the session's first pass trims it to the direct contacts. A pass compares each owed peer's keys and
/// the root its session holds now with it, so the heal's pass, which runs whatever the revision says, is what resends after
/// a reset of the peer's: this port has no hook for a root change.
///
/// **Never logs a key, a tag or a root tag.** The per-decision trail goes to the log only where
/// ``MeshConfiguration/logsPresenceKeyTrail`` asks (a debug build, knit-peer); a release build counts (``PresenceKeyCounts``).
extension MeshEngine {
    /// The most `due` steps one pass applies: more than any chain the policy names (`MAX_STEPS`, `:662`).
    static let ownKeySteps = 6
    /// The shortest and longest wait between a link coming up and its pass (`LINK_UP_DELAY_MIN_MS`, `_MAX_MS`, `:658-659`).
    static let presenceLinkUpDelay: ClosedRange<Int64> = 2000...20_000
    /// How long our keys' settle sits out after a unit that held one failed.
    static let ownSettleRetryMilliseconds: Int64 = 60_000
    /// How long after a ctl 11 was queued its link may end and have lost it: the write-stall watch's bound, its stall and
    /// one check, past which a link that still stood would have been closed for holding it (``WriteStallWatch``).
    static var presenceLostSendMilliseconds: Int64 {
        let watch = WriteStallWatch.Configuration()
        return watch.stallMilliseconds + watch.checkEveryMilliseconds
    }

    // MARK: Triggers

    /// Marks our own keys' pass owed, whatever the listing's revision says: the heal, a link-up's delayed pass, a mark the
    /// advertiser asks after, and a session's start.
    func noteOwnPresenceKeyPassOwed() {
        presenceKeyFeed.ownPassOwed = true
    }

    /// A link to `peer` came up: its pass runs 2 to 20 s on (`presenceLinkUpDelayMs`, `MeshManager.kt:444-447`), on the
    /// monotonic clock, from the injected generator, which draws no key. A peer already waiting keeps its deadline. A build
    /// that sends no keys of its own owes a link nothing.
    func schedulePresenceLinkUp(_ peer: NodeId) {
        // Each link of the peer's is a new one to the ledger, which names the link a ctl 11 went out on.
        presenceKeyFeed.linkSequence[peer, default: 0] += 1
        guard configuration.sendsOwnPresenceKeys, presenceKeyFeed.linkUps[peer] == nil else {
            return
        }
        let span = UInt64(Self.presenceLinkUpDelay.upperBound - Self.presenceLinkUpDelay.lowerBound + 1)
        let delay = Self.presenceLinkUpDelay.lowerBound + Int64(random.next(upperBound: span))
        presenceKeyFeed.linkUps[peer] = clock.monotonicMilliseconds() + delay
    }

    /// `peer`'s last link went: its delayed pass is dropped, and what it was sent is kept, so a relink with nothing changed
    /// sends nothing (`onLinkDepart`, `:358-360`). But a ctl 11 queued on this very link within
    /// ``presenceLostSendMilliseconds`` may have died in its outbox: that record goes, so the next link's pass sends again.
    /// A copy that did arrive is an equal generation, a no-op to the peer, for one ratchet step.
    func cancelPresenceLinkUp(_ peer: NodeId) {
        presenceKeyFeed.linkUps[peer] = nil
        guard let sent = presenceKeyFeed.sent[peer], sent.link == presenceKeyFeed.linkSequence[peer] else {
            return
        }
        if clock.monotonicMilliseconds() - sent.queuedAt < Self.presenceLostSendMilliseconds {
            presenceKeyFeed.sent[peer] = nil
        }
    }

    /// Marks the pass owed once the settle's sit-out after a failed unit ran out at `now`.
    func fireOwnSettleRetry(now: Int64) {
        guard let retry = presenceKeyFeed.ownSettleRetryAt, retry <= now else {
            return
        }
        presenceKeyFeed.ownSettleRetryAt = nil
        noteOwnPresenceKeyPassOwed()
    }

    /// Marks the pass owed when a delayed link-up pass fell due at `now`.
    func firePresenceLinkUps(now: Int64) {
        let due = presenceKeyFeed.linkUps.filter { $0.value <= now }.map(\.key)
        guard !due.isEmpty else {
            return
        }
        for peer in due {
            presenceKeyFeed.linkUps[peer] = nil
        }
        noteOwnPresenceKeyPassOwed()
    }

    /// The next delayed link-up pass, or the end of the settle's sit-out, on the monotonic clock.
    var nextPresenceLinkUp: Int64? {
        (Array(presenceKeyFeed.linkUps.values) + [presenceKeyFeed.ownSettleRetryAt].compactMap(\.self)).min()
    }

    /// Whether a stored profile carrying `capabilities` asks for a pass (`asksForKeys`, `PresenceKeyEngine.kt:378`): we send
    /// our keys and it reads tags. Nothing is remembered per id: a second such profile costs a pass and seals nothing.
    func asksForPresenceKeys(_ capabilities: Int64?) -> Bool {
        configuration.sendsOwnPresenceKeys && capabilities.map { Capabilities(rawValue: $0).contains(.blindAdvert) } == true
    }

    /// The advertiser asks for one pass under our key `generation`, its mark having moved past the contact window's lead:
    /// once per generation.
    func askPresenceMarkPass(_ generation: Int64) {
        guard presenceKeyFeed.markPasses.insert(generation).inserted else {
            return
        }
        noteOwnPresenceKeyPassOwed()
    }

    /// Writes the advertiser's mark under our key `generation` (``PresenceKeyStore/writeMark(_:of:)``), counted.
    func writePresenceMark(_ mark: PresenceMark, of generation: Int64) -> PresenceMarkWrite {
        let written = stores.presenceKeys.writeMark(mark, of: generation)
        presenceKeyFeed.counts.markWrites += 1
        switch written {
        case .durable:
            presenceKeyFeed.counts.marksDurable += 1
        case .refused:
            presenceKeyFeed.counts.markRefused += 1
        case .notFull:
            presenceKeyFeed.counts.markNotFull += 1
        case .insideUnit, .failed:
            presenceKeyFeed.counts.markFailed += 1
        }
        return written
    }

    /// The readers the radio is handed once (``PresenceKeySource``), each reaching this engine weakly.
    func presenceKeySource() -> PresenceKeySource {
        PresenceKeySource(
            ownKey: { [weak self] in self?.presenceKeyFeed.published },
            hearsTagNext: { [weak self] peer in
                guard let feed = self?.presenceKeyFeed else {
                    return false
                }
                return PresenceKeyPolicy.hearsTagNext(peer, blocked: feed.blocked, departed: feed.departed)
            },
            askMarkPass: { [weak self] generation in self?.askPresenceMarkPass(generation) },
            readMark: { [weak self] generation in self?.stores.presenceKeys.mark(of: generation) },
            writeMark: { [weak self] mark, generation in self?.writePresenceMark(mark, of: generation) ?? .failed }
        )
    }

    /// Clamps our presence keys' last generation to the clock when a reinstall is found and it sits more than a year
    /// ahead (`onRestore`'s `clampRestored`, `PresenceKeyEngine.kt:296-306` at knit-next `cad69c77b`; ADR 2026-11.prsp):
    /// the same reinstall ``syncPrekey(atStart:)`` finds, prekeys kept over a profile never published, so the start calls
    /// it first. Only there: every session starts again after a reinstall, so a lower generation is a new era to every peer,
    /// while a clamp at any other start would hand a peer a lower generation under a root it still holds. A store that
    /// cannot answer clamps nothing.
    func clampPresenceGenerationAtReinstall() {
        guard let ring = prekeyRing, ring.newest != nil, stores.ownProfile.loadIfReadable()?.publishedAt == 0 else {
            return
        }
        let now = clock.wallMilliseconds()
        do {
            if try ring.clampPresenceLastGeneration(now: now, aheadMilliseconds: PresenceKeyPolicy.clampAheadMilliseconds) != nil {
                log.log(.info, "mesh clamped the presence key generation to the clock after a reinstall")
            }
        } catch {
            log.log(.warning, "mesh left the presence key generation as it was: \(error)")
        }
    }

    // MARK: The settle, inside the pass's unit

    /// Applies ``PresenceKeyPolicy/due(rows:direct:now:clockAdvanceAllowed:)`` until nothing is due, inside the pass's unit
    /// (`settle`, `:527-538`), each step against the rows as the unit holds them and `direct`, the unit's own read. A clock
    /// or mark advance allows no second one in the same pass; the day's floor between passes is the caller's.
    func settleOwnKeys(direct: Set<NodeId>, now: Int64, clockAdvanceAllowed: Bool) -> OwnKeySettle {
        var settle = OwnKeySettle()
        var allowed = clockAdvanceAllowed
        for _ in 0..<Self.ownKeySteps {
            let rows = stores.presenceKeys.ownKeys()
            let due = PresenceKeyPolicy.due(rows: rows, direct: direct, now: now, clockAdvanceAllowed: allowed)
            if due == .nothing {
                settle.reachedNone = true
                return settle
            }
            let change: OwnKeyChange?
            do {
                change = try ownKeyChange(for: due, rows: rows, direct: direct, now: now)
            } catch {
                settle.mintFailed = error
                return settle
            }
            guard let change else {
                // No generation left to mint (`nextGeneration`'s overflow): nothing changed, and nothing is due that settles.
                settle.exhausted = true
                return settle
            }
            stores.presenceKeys.applyOwn(inserted: change.inserted, updated: change.updated, keep: change.keep)
            if case .advance(let cause) = due, cause != .weekly {
                allowed = false
                settle.clockAdvanced = true
            }
            settle.steps.append(due)
            settle.minted += change.inserted.count
        }
        return settle
    }

    /// The writes `due` asks for, or `nil` when a generation could not be minted (`changeFor`, `:568-604`).
    private func ownKeyChange(
        for due: PresenceKeyPolicy.Due, rows: [OwnPresenceKeyRecord], direct: Set<NodeId>, now: Int64
    ) throws(OwnKeyMintError) -> OwnKeyChange? {
        let keys = PresenceKeyPolicy.keysOf(rows)
        let held = Set(rows.map(\.generation))
        switch due {
        case .mint, .fresh:
            // With no current key there is nothing to keep; on a shrink the next key may be held by whoever left and goes,
            // while the current one stays as the previous key, never aired again.
            return try freshOwnPair(keys, rows: rows, now: now, direct: direct)
        case .advance:
            // The next key becomes the current one and a new next key is minted; with no next key, a fresh pair.
            guard var promoted = keys.next else {
                return try freshOwnPair(keys, rows: rows, now: now, direct: direct)
            }
            guard let next = try mintOwnKey(rows: rows, now: now, activatedAt: nil, audience: direct) else {
                return nil
            }
            promoted.activatedAt = now
            let keep = Set([keys.current?.generation, promoted.generation, next.generation].compactMap(\.self))
            return OwnKeyChange(inserted: [next], updated: [promoted], keep: keep)
        case .mintNext:
            return try mintOwnKey(rows: rows, now: now, activatedAt: nil, audience: direct).map { next in
                OwnKeyChange(inserted: [next], updated: [], keep: held.union([next.generation]))
            }
        case .grow, .nothing:
            // The settle stops at nothing-due before it asks, so only a grow moves anything here.
            var updated: [OwnPresenceKeyRecord] = []
            if case .grow(let toNext, let toCurrent) = due {
                if var next = keys.next {
                    next.audience.formUnion(toNext)
                    updated.append(next)
                }
                if var current = keys.current, !toCurrent.isEmpty {
                    current.audience.formUnion(toCurrent)
                    updated.append(current)
                }
            }
            return OwnKeyChange(inserted: [], updated: updated, keep: held)
        }
    }

    /// A new current key and a new next one, the old current kept as the previous key (none on a first mint)
    /// (`freshPair`, `:622-630`).
    private func freshOwnPair(
        _ keys: PresenceKeyPolicy.Keys, rows: [OwnPresenceKeyRecord], now: Int64, direct: Set<NodeId>
    ) throws(OwnKeyMintError) -> OwnKeyChange? {
        guard let current = try mintOwnKey(rows: rows, now: now, activatedAt: now, audience: direct) else {
            return nil
        }
        // The second mint reads the generation the first just wrote.
        guard let next = try mintOwnKey(rows: rows + [current], now: now, activatedAt: nil, audience: direct) else {
            return nil
        }
        let keep = Set([keys.current?.generation, current.generation, next.generation].compactMap(\.self))
        return OwnKeyChange(inserted: [current, next], updated: [], keep: keep)
    }

    /// A new key of the next generation, that generation written to the identity's item before it is used (`mint`,
    /// `:633-645`): `max(last + 1, now)`, over the item's last and every row's, so a row a lost item left behind is never
    /// collided with. Its bytes come from the system's generator. `nil` when the add overflows; a throw when the item cannot
    /// be read or written, or there is none.
    private func mintOwnKey(
        rows: [OwnPresenceKeyRecord], now: Int64, activatedAt: Int64?, audience: Set<NodeId>
    ) throws(OwnKeyMintError) -> OwnPresenceKeyRecord? {
        guard let ring = prekeyRing else {
            throw .noItem
        }
        let stored: Int64
        do {
            stored = try ring.presenceLastGeneration()
        } catch {
            throw .item(error)
        }
        let last = max(stored, rows.map(\.generation).max() ?? 0)
        guard let generation = PresenceKeyPolicy.nextGeneration(last: last, now: now) else {
            log.log(.warning, "mesh presence key generation would overflow; nothing minted")
            return nil
        }
        do {
            try ring.setPresenceLastGeneration(generation)
        } catch {
            throw .item(error)
        }
        return OwnPresenceKeyRecord(
            generation: generation, key: mintPresenceKey(), mintedAt: now, activatedAt: activatedAt, audience: audience)
    }
}

/// What one pass's settle of our own keys came to, inside its unit.
internal struct OwnKeySettle {
    /// Whether it reached nothing-due.
    var reachedNone = false
    /// A mint the identity's item could not record, which publishes nothing new.
    var mintFailed: OwnKeyMintError?
    /// Whether a generation could not be minted at all.
    var exhausted = false
    /// Whether the settle sat out this pass, after a failed unit: nothing new is published or sent.
    var deferred = false
    /// Whether a clock or mark advance ran, which starts the day's floor once the unit commits.
    var clockAdvanced = false
    /// The steps applied, in order.
    var steps: [PresenceKeyPolicy.Due] = []
    /// The generations minted.
    var minted = 0
}

/// One rotation's writes: new generations, moved ones, and the generations kept (`Change`, `:541-545`).
internal struct OwnKeyChange {
    let inserted: [OwnPresenceKeyRecord]
    let updated: [OwnPresenceKeyRecord]
    let keep: Set<Int64>
}

/// Why a mint recorded nothing.
internal enum OwnKeyMintError: Error, Equatable {
    /// This node keeps no identity's item to record a generation in (a demo, a test).
    case noItem
    /// The item could not be read or written now.
    case item(PrekeyRing.Failure)
}
