import KnitWire

/// Resolves an advertised form (``AdvertOrder/Form``) to a node id (knit-next ADR 2026-11.xp6d, #285; `AdvertAliases.kt` at
/// `cad69c77b`; ADR 2026-11.sv5t). A clear advert is its own id. A blinded one names a `BlindTag`, resolved in this order
/// (`resolve`, `:363-382`):
///
/// 1. **Malformed** first: bytes without the tag prefix (``AdvertForm/hasTagPrefix(_:)``).
/// 2. **Own:** my current or previous tag (``setOwnTags(current:previous:)``), heard back or claimed by another, is never a
///    peer's (ADR 2026-11.prsp).
/// 3. **Direct contacts' expected tags** (``setKeys(_:)``, ``ExpectedTagTable``): every contact key's tags over the window
///    of this phone's wall clock, so a heard tag resolves with one hash lookup and an unknown one, a flood included, costs
///    a miss and nothing else.
/// 4. **Link claims** (``onDialed(_:dialed:told:provenId:)``, ``onTagNext(_:provenId:tag:)``): a tag a proven link told us
///    is its own.
/// 5. **Hints** (``onAnswered(_:told:provenId:)``): a tag a dialer's HELLO told us is its own.
///
/// My own tag is never a claim, a hint or an announcement either. My own clear advert is dropped by id in ``LinkManager``'s
/// sightings.
///
/// **Claims** (Kotlin's KDoc, `:27-59`, has the full reasoning):
/// - a link holds at most one claim, and so does a node id; a newer one replaces it;
/// - a claim a contact's expected tag contradicts is dropped and counted, at the claim and at every resolve;
/// - two ids claiming one tag void it for both, and it takes no claim until it would have expired, except that a claim one
///   of our own dials proved lifts a void that unproven claimants made and voids those claimants;
/// - a claim never lapses while its link is held, and lives ``Configuration/claimLifetimeMilliseconds`` past the link's end;
/// - a dialer believes the responder's `t` only when it equals the `a` it dialed, or a tag that responder announced and we
///   hold pending; a different `t` is a rotation edge, held pending;
/// - a responder's view of the dialer's `t` is a hint, one per link and per id;
/// - an announced tag (`TAG_NEXT`) is held pending until it is first heard, then becomes the link's claim; a link sends at
///   most one per ``Configuration/tagNextMinIntervalMilliseconds``;
/// - the tables are bounded: ``Configuration/maxClaims`` claims, and ``Configuration/entryCap`` announced tags and voids.
///
/// What an answer may hold off is ``BlindSightings``' and ``Suppressor``'s, where this port departs from Android for a hint.
/// Kotlin's spot check (`nextSpotCheck`, `onSpotCheck`) is unwired there and left out here.
///
/// Two clocks are injected: the monotonic clock for every expiry, and the wall clock for slots only. Links are the caller's
/// keys (`L`). ``counters`` carry counts only, never a key or a tag. Single-threaded, on the `Mesh` actor.
internal final class AdvertAliases<L: Hashable> {
    /// The tunables.
    typealias Configuration = AdvertAliasesConfiguration

    let nowClock: () -> Int64
    let wallClock: () -> Int64
    let configuration: Configuration
    let table: ExpectedTagTable
    var claims: [NodeId: Claim] = [:]
    var pending: [NodeId: Claim] = [:]
    var hints: [L: (tag: NodeId, claim: Claim)] = [:]
    var voided: [NodeId: VoidMark] = [:]
    var deadlines = DeadlineHeap<Lapse>()
    var lastTagNext: [L: Int64] = [:]
    /// Links a handshake event named and ``onLinkEnded(_:)`` has not ended: their claims and announced tags never lapse.
    var heldLinks: Set<L> = []
    var counts = Counters()
    /// My own tags, current and previous, while I blind (`ownCurrent`, `ownPrevious`, `:301-302`).
    private var ownCurrent: NodeId?
    private var ownPrevious: NodeId?

    /// A resolver reading `now` (the monotonic clock) for every expiry and `wall` for slots only.
    convenience init(now: @escaping () -> Int64, wall: @escaping () -> Int64) {
        self.init(now: now, wall: wall, configuration: Configuration())
    }

    /// A resolver on `configuration`'s tunables.
    init(now: @escaping () -> Int64, wall: @escaping () -> Int64, configuration: Configuration) {
        nowClock = now
        wallClock = wall
        self.configuration = configuration
        table = ExpectedTagTable(previousKeyMaxMilliseconds: configuration.previousKeyMaxMilliseconds)
    }

    /// The direct contacts' presence keys, replacing the whole set (``ContactKey``'s rules). Only a contact whose keys
    /// changed is listed again: up to a window's 140 HMACs per new key.
    func setKeys(_ contacts: [NodeId: ContactKey]) {
        table.setKeys(contacts, now: nowClock(), wall: wallClock())
    }

    /// My own advertised tags, so my own advert, heard back or claimed by another, is never taken for a peer (`setOwnTags`,
    /// `:338-344`). `nil` for a form that is not a tag.
    func setOwnTags(current: NodeId?, previous: NodeId?) {
        ownCurrent = current
        ownPrevious = previous
    }

    /// Whether `tag` is one of mine (`isOwn`, `:880`).
    func isOwn(_ tag: NodeId) -> Bool {
        tag == ownCurrent || tag == ownPrevious
    }

    /// Moves the expected-tag window to the wall clock now. Every entry point does this first; the wiring also calls it at
    /// each slot edge, so the re-list runs then and not inside a sighting's resolve.
    func slide() {
        table.slide(wall: wallClock())
    }

    /// The node id `form` names, or why there is none.
    func resolve(_ form: AdvertOrder.Form) -> Resolution {
        guard form.blinded else {
            return .resolved(form.advertised, .clear)
        }
        let tag = form.advertised
        guard Self.isTag(tag) else {
            counts.malformed += 1
            return .malformed
        }
        let now = nowClock()
        expire(now)
        if isOwn(tag) {
            return .own
        }
        if let keyId = keyAnswer(tag) {
            dropContradicted(tag, keyId)
            counts.resolvedByKey += 1
            return .resolved(keyId, .key)
        }
        // An announced tag heard for the first time becomes its link's claim.
        promotePending(tag, now: now)
        if let answer = linkAnswer(tag) {
            return .resolved(answer)
        }
        counts.unresolved += 1
        return .unresolved
    }

    /// The dialer's side of a handshake on `link`: I dialed `dialed`, the responder's HELLO told `told` (its `t`; `nil` when
    /// absent) and proved `provenId` (`onDialed`, `:392-421`). Records `told` as the link's claim only when it equals the tag
    /// dialed, or is a tag `provenId` announced and we hold pending; never when a contact's expected tag names the dialed
    /// tag's owner as another id. A dialed tag with a different `told` is a rotation edge: `told` is held pending, as a
    /// `TAG_NEXT` would be.
    @discardableResult
    func onDialed(_ link: L, dialed: AdvertOrder.Form, told: NodeId?, provenId: NodeId) -> ClaimOutcome {
        let now = nowClock()
        expire(now)
        heldLinks.insert(link)
        onDialProved(dialed, provenId: provenId)
        guard dialed.blinded, Self.isTag(dialed.advertised), let told, told != provenId else {
            return ignored()
        }
        let dialedTag = dialed.advertised
        let announced = told != dialedTag && pending[told]?.nodeId == provenId
        if let keyId = keyAnswer(dialedTag) {
            return agreement(keyId, provenId)
        }
        if told != dialedTag, !announced {
            return onTagNext(link, provenId: provenId, tag: told)
        }
        let outcome = record(link, tag: told, nodeId: provenId, now: now, dialProven: !announced)
        if announced, outcome.settles {
            pending[told] = nil
        }
        return outcome
    }

    /// The responder's side: the dialer on `link` proved `provenId` and its HELLO told `told` (`onAnswered`, `:428-443`).
    /// Held as the link's hint, one per link and per id, unless a contact's expected tag names another id or the tag is
    /// void. A told form equal to the id, a clear dialer's, is nothing to hold.
    @discardableResult
    func onAnswered(_ link: L, told: NodeId?, provenId: NodeId) -> ClaimOutcome {
        let now = nowClock()
        expire(now)
        heldLinks.insert(link)
        guard let tag = told, tag != provenId, !isOwn(tag), Self.isTag(tag) else {
            return ignored()
        }
        if voided[tag] != nil {
            return contested()
        }
        if let keyId = keyAnswer(tag) {
            return agreement(keyId, provenId)
        }
        hints = hints.filter { $0.value.claim.nodeId != provenId }
        hints[link] = (tag, Claim(link: link, nodeId: provenId, expiresAt: .max, dialProven: false))
        return .hinted
    }

    /// A dial to `dialed` proved `provenId` (`onDialProved`, `:454-467`). Every hint, announced tag or claim naming another
    /// id for that tag that no dial of ours proved is a lie, so the links and ids that made it lose all of theirs, a void
    /// those claimants made is lifted, and the tag stays open for its owner's claim. A claim another dial to the same tag
    /// proved is a contest instead. A contact's expected tag naming another id outranks the proof: nothing is voided and
    /// the replay is counted (``Counters/keyProofMismatches``). True when anything was voided or lifted.
    @discardableResult
    func onDialProved(_ dialed: AdvertOrder.Form, provenId: NodeId) -> Bool {
        guard dialed.blinded, Self.isTag(dialed.advertised) else {
            return false
        }
        let tag = dialed.advertised
        let now = nowClock()
        expire(now)
        if let keyId = keyAnswer(tag), keyId != provenId {
            counts.keyProofMismatches += 1
            return false
        }
        return settleRivals(tag, provenId: provenId, now: now)
    }

    /// `link`, proven as `provenId`, announced its next tag (`TAG_NEXT`; `onTagNext`, `:474-487`). Held pending, resolving
    /// nothing, until it is first heard or a dial's HELLO names it; then it replaces the link's claim. At most one per link
    /// per ``Configuration/tagNextMinIntervalMilliseconds``, counted on arrival.
    @discardableResult
    func onTagNext(_ link: L, provenId: NodeId, tag: NodeId) -> ClaimOutcome {
        let now = nowClock()
        expire(now)
        heldLinks.insert(link)
        guard Self.isTag(tag), !isOwn(tag) else {
            return ignored()
        }
        guard tagNextAllowed(link, now: now) else {
            counts.tagNextRateLimited += 1
            return .rateLimited
        }
        if voided[tag] != nil {
            return contested()
        }
        if let keyId = keyAnswer(tag) {
            return agreement(keyId, provenId)
        }
        return holdPending(link, provenId: provenId, tag: tag, now: now)
    }

    /// What `tag` names now, read when a dial is decided: a contact's key, else a claim, else a hint all naming one id; `nil`
    /// for none. Counts nothing and promotes no announced tag, so a decision read many times a second leaves the
    /// counters and the tables as the sightings left them.
    func standing(_ tag: NodeId) -> Answer? {
        guard Self.isTag(tag) else {
            return nil
        }
        expire(nowClock())
        if let keyId = keyAnswer(tag) {
            return Answer(nodeId: keyId, source: .key)
        }
        if let claim = claims[tag] {
            return Answer(nodeId: claim.nodeId, source: .claim, claimant: claim.link)
        }
        let hinted = hints.filter { $0.value.tag == tag }
        guard hinted.count == 1, let hint = hinted.first else {
            return nil
        }
        return Answer(nodeId: hint.value.claim.nodeId, source: .hint, claimant: hint.key)
    }

    /// Whether `tag`, which `link` (proven as `provenId`) announced, still stands for it: held pending under that link,
    /// claimed by it since it was heard, or what a contact's key already says of `provenId` (`stillAnnounced`, `:494-498`).
    /// Read when the announced tag reaches its edge, before it becomes the link's form.
    func stillAnnounced(_ link: L, provenId: NodeId, tag: NodeId) -> Bool {
        pending[tag]?.link == link || claims[tag]?.link == link || keyAnswer(tag) == provenId
    }

    /// The tag `node` announced that we hold pending, if any: a GATT payload naming it is that node's (rule 2).
    func announced(by node: NodeId) -> NodeId? {
        pending.first { $0.value.nodeId == node }?.key
    }

    /// Whether any contact's keys are listed, so the window has a slot edge to slide at.
    var listsKeys: Bool { table.contactCount > 0 }

    /// `link` ended: its hint goes, being unproven past the link. Its claim and any announced tag live one
    /// ``Configuration/claimLifetimeMilliseconds`` from now (`onLinkEnded`, `:505-512`). The wiring calls it for every link it
    /// named in a handshake event, or that link's entries never lapse.
    func onLinkEnded(_ link: L) {
        hints[link] = nil
        lastTagNext[link] = nil
        guard heldLinks.remove(link) != nil else {
            return
        }
        let until = nowClock() + configuration.claimLifetimeMilliseconds
        for (tag, claim) in claims where claim.link == link {
            extend(.claims, tag, claim, until: until)
        }
        for (tag, claim) in pending where claim.link == link {
            extend(.pending, tag, claim, until: until)
        }
    }

    /// The tag dials that met a replay, without building ``counters``.
    var keyProofMismatchCount: Int { counts.keyProofMismatches }

    /// Counts and table sizes.
    var counters: Counters {
        var counted = counts
        counted.tableSize = table.count
        counted.tableBuilds = table.builds
        counted.tableSlotSteps = table.slotSteps
        counted.tableHmacs = table.tagsComputed
        counted.tableContacts = table.contactCount
        counted.claims = claims.count
        counted.pending = pending.count
        counted.voided = voided.count
        counted.deadlines = deadlines.count
        counted.hints = hints.count
        counted.heldLinks = heldLinks.count
        counted.lastTagNext = lastTagNext.count
        return counted
    }

    /// Whether `tag` carries a tag's prefix (`tagBytes`, `:905`). A ``NodeId`` is always a canonical 26-character form.
    static func isTag(_ tag: NodeId) -> Bool {
        AdvertForm.hasTagPrefix(tag.bytes)
    }
}
