import KnitStore
import KnitWire

/// The holder's half of feeding one copy of a blob at a time (`BlobExchange.kt:1185-1452`, knit-next ADR 2026-10.g24x's
/// "one BT copy per blob", `e2191bb9`; ADR 2026-10.nsr7's meter and member-first parking, `79f38d3d`; and `3890f16b`).
///
/// Every link here shares one radio, and its paced feeds one budget (ADR 2026-10.xwjc), so four copies of a photo at once
/// all land at the end. One at a time, the first lands in a quarter of that, and its receiver holds it: a second source
/// for the rest. So an ask for a blob that is already being fed to someone else is parked, and served when that feed
/// ends, stalls or runs past its deadline (``FeedReading/live``), or when the ask's own copy would end first. Android's
/// other exceptions never come up: there is no Wi-Fi Aware link to ride and no Coded pace outside the split
/// (`ridesSharedBudget`), and no session-less rig, since an engine that has not started parks nothing.
extension MeshEngine {
    /// Parks `asker`'s ask for `hash`, a copy of `bytes`, when it waits behind a live feed of the blob to someone else
    /// (`parkBehindFeed`). True when parked; a re-ask while parked only refreshes it. Never for a copy the serve memo
    /// already covers. The park is kept as long as its turn is expected to take, not only the memo's 45 s: an asker held
    /// elsewhere may not query us again before the feed ends (knit-next's device cell (c), 2026-10-07: dropped 4 s
    /// before its turn, it came back 10 s late on its own).
    func parkBehindFeed(_ hash: BlobHash, for asker: NodeId, bytes: Int64, now: Int64) -> Bool {
        let addressees = addressees(of: hash)
        guard isStarted, !blobExchange.memoHolds(hash, for: asker, now: now),
            waitsBehindFeed(hash, asker: asker, bytes: bytes, to: addressees)
        else {
            return false
        }
        if blobExchange.park(hash, for: asker, bytes: bytes, now: now) {
            blobExchange.counts.asksParked += 1
            let carrier = Self.isCarrier(asker, of: addressees) ? " (carrier)" : ""
            note(["blob park \(hash.string.prefix(BlobExchange.shownHashCharacters))… for \(asker) behind a feed\(carrier)"])
        }
        _ = eta(of: hash, to: asker, now: now)
        return true
    }

    /// Whether `asker`'s copy of `bytes` waits behind the copies of `hash` fed live to other neighbours (`waitsBehindFeed`):
    /// yes while any is, however long it takes, since split budgets make two copies at once each take twice as long. The
    /// exception is an asker whose own copy, at its link's expected rate, would end before every one of them does, and
    /// only when what it saves beats what it costs the feeds already running. Each of the `n` feeds on the radio ends
    /// about own ÷ (n + 1) later, so the asker goes only when `max ETA − own × k ÷ (n + 1) > own × n ÷ (n + 1)`, with `k`
    /// the blob's feeds.
    ///
    /// Members first (`to`, the conversation's addressees): a member waits only behind members' copies and goes beside a
    /// carrier's, which is a spare; a carrier waits behind any copy and never goes beside one (knit-next's cell (d),
    /// 2026-10-07: a member parked 287 s behind a carrier's lapsed pull). Unknown addressees treat everyone as a member.
    func waitsBehindFeed(_ hash: BlobHash, asker: NodeId, bytes: Int64, to addressees: Set<NodeId>?) -> Bool {
        let carrier = Self.isCarrier(asker, of: addressees)
        let feeds = liveFeeds(of: hash, besides: asker, among: carrier ? nil : addressees)
        guard !feeds.isEmpty else {
            return false
        }
        guard !carrier, let own = ownCopyMilliseconds(to: asker, bytes: bytes) else {
            return true
        }
        let etas = feeds.compactMap(\.etaMilliseconds)
        guard etas.count == feeds.count, let longest = etas.max(), !etas.contains(where: { own >= $0 }) else {
            return true
        }
        // `k` and `n` in the rule above.
        let blobFeeds = Int64(feeds.count)
        let radioFeeds = max(Int64(transport.feedingLoad), blobFeeds)
        let saved = longest - own * blobFeeds / (radioFeeds + 1)
        let cost = own * radioFeeds / (radioFeeds + 1)
        guard saved > cost else {
            return true
        }
        let theirs = etas.map { "\($0) ms" }.joined(separator: ", ")
        let shown = hash.string.prefix(BlobExchange.shownHashCharacters)
        note(["blob beside \(shown)… → \(asker): its copy ~\(own) ms, the feeds' \(theirs); saves ~\(saved) ms for ~\(cost) ms of theirs"])
        return false
    }

    /// How long a copy of `bytes` to `peer` would take at its link's expected rate (`ownCopyMs`); `nil` when that is not
    /// known.
    private func ownCopyMilliseconds(to peer: NodeId, bytes: Int64) -> Int64? {
        let rate = transport.expectedFileRate(to: peer)
        return rate > 0 ? bytes * FeedWindow.millisecondsPerSecond / rate : nil
    }

    /// The live copies of `hash` fed to neighbours other than `asker`, only those to neighbours `among` when it is given
    /// (`liveFeeds`).
    private func liveFeeds(of hash: BlobHash, besides asker: NodeId, among: Set<NodeId>? = nil) -> [FeedReading] {
        transport.neighbors.compactMap { neighbor in
            guard neighbor.nodeId != asker, among.map({ $0.contains(neighbor.nodeId) }) ?? true else {
                return nil
            }
            return transport.fileFeed(of: hash, to: neighbor.nodeId).flatMap { $0.live ? $0 : nil }
        }
    }

    /// Whether `asker` is a carrier of a blob whose conversation is addressed to `addressees` (`isCarrier`): they are
    /// known, and it is not among them.
    private static func isCarrier(_ asker: NodeId, of addressees: Set<NodeId>?) -> Bool {
        addressees.map { !$0.contains(asker) } ?? false
    }

    /// Whom the conversation naming blob `hash` is addressed to (`MeshManager.addresseesOf`): a group's members, a DM's
    /// two ends; `nil` for the room's, or when no message we hold names it (a relay's blob, a photo).
    func addressees(of hash: BlobHash) -> Set<NodeId>? {
        guard let conversation = stores.messages.conversation(ofAttachment: hash), conversation != Conversations.nearby else {
            return nil
        }
        if Conversations.isGroup(conversation) {
            return stores.groups.group(conversation).map { Set($0.members.compactMap(NodeId.init)) }
        }
        return NodeId(conversation).map { [$0, nodeId] }
    }

    /// The ms until `asker`'s copy of `hash` should have landed, for a SENDING answer (`etaFor`, knit-next ADR
    /// 2026-10.nsr7): its own feed's ETA while its copy is on the link; parked, the soonest live feed's end plus its own
    /// copy, which the parked ask is then kept for, set at the park too, so an asker that never queries us again keeps its
    /// turn. A query from a parked asker renews its ask. `nil` when nobody can tell, and the asker waits as it did before.
    func eta(of hash: BlobHash, to asker: NodeId, now: Int64) -> Int64? {
        if let feed = transport.fileFeed(of: hash, to: asker) {
            return feed.etaMilliseconds
        }
        guard let renewed = blobExchange.renewParked(hash, for: asker, now: now),
            let wait = liveFeeds(of: hash, besides: asker).compactMap(\.etaMilliseconds).min(),
            let own = ownCopyMilliseconds(to: asker, bytes: renewed.bytes)
        else {
            return nil
        }
        let eta = wait + own
        blobExchange.keepParked(hash, for: asker, until: now + eta + BlobExchange.holdSlackMilliseconds)
        return eta
    }

    /// A link's feed changed (`feedsChanged`): it ended, its pace settled or moved, or its first report measured it. The
    /// parked asks are read again now, rather than at the next poll.
    public func fileFeedsChanged() {
        if blobExchange.hasParked {
            _ = serveParked(fromPoll: false)
        }
    }

    /// The poll over the parked asks, when it is due (`pollParked`): it sleeps as long as the last pass said, and lets
    /// itself go once nothing is parked.
    func pollParkedAsks(now: Int64) {
        guard let due = blobExchange.parkPollAt, due <= now else {
            return
        }
        blobExchange.parkPollAt = serveParked(fromPoll: true).map { now + $0 }
    }

    /// One pass over the parked asks (`serveParked`). First it drops the asks whose asker unlinked, or that nobody renewed
    /// in time. Then, for each blob, it serves the ask that goes first (``first(of:to:)``) once that ask no longer waits
    /// behind a live feed. Answers how long the poll may sleep before the next pass while anything stays parked, or `nil`
    /// when nothing does: soon while a blob has nothing live ahead of it, since its asks are served one a pass, else when
    /// the soonest feed ahead can next stall or pass its deadline.
    private func serveParked(fromPoll _: Bool) -> Int64? {
        let now = clock.monotonicMilliseconds()
        var next = BlobExchange.parkPollMaxMilliseconds
        for (hash, asks) in blobExchange.pruneParked(linked: Set(neighborIds), now: now) {
            let addressees = addressees(of: hash)
            // Never empty: the prune drops a blob whose last ask went.
            if let (asker, ask) = first(of: asks, to: addressees) {
                let rechecks = liveFeeds(of: hash, besides: asker).map { $0.recheckMilliseconds ?? BlobExchange.parkPollMilliseconds }
                next = min(next, rechecks.min() ?? BlobExchange.parkPollMilliseconds)
                if !waitsBehindFeed(hash, asker: asker, bytes: ask.bytes, to: addressees), blobExchange.takeParked(hash, for: asker) {
                    note(["blob unpark \(hash.string.prefix(BlobExchange.shownHashCharacters))… → \(asker) (waited \(now - ask.since) ms)"])
                    serveOrWant(hash, to: asker, mayPark: false)
                }
            }
        }
        guard blobExchange.hasParked else {
            return nil
        }
        return min(max(next, BlobExchange.parkPollMilliseconds), BlobExchange.parkPollMaxMilliseconds)
    }

    /// Of `asks`, the one served next (`first`): a member of `addressees` before a carrier, then the one whose link is
    /// expected to feed fastest, then the oldest.
    private func first(
        of asks: [(asker: NodeId, ask: BlobExchange.ParkedAsk)], to addressees: Set<NodeId>?
    ) -> (asker: NodeId, ask: BlobExchange.ParkedAsk)? {
        let ranked = asks.map { entry in
            (entry: entry, member: !Self.isCarrier(entry.asker, of: addressees), rate: transport.expectedFileRate(to: entry.asker))
        }
        return ranked.max { lhs, rhs in
            if lhs.member != rhs.member {
                return !lhs.member
            }
            if lhs.rate != rhs.rate {
                return lhs.rate < rhs.rate
            }
            return lhs.entry.ask.since > rhs.entry.ask.since
        }?.entry
    }
}
