import KnitWire

/// The claim rules behind ``AdvertAliases``' entry points (`AdvertAliases.kt:578-895` at knit-next `cad69c77b`).
extension AdvertAliases {
    /// The contact whose expected tags list `tag`, or `nil`.
    func keyAnswer(_ tag: NodeId) -> NodeId? {
        table.lookup(tag, now: nowClock())?.nodeId
    }

    /// A claim's answer (``claimAnswer(_:)``, which a claim whose link ended yields to its own id's hint), else a hint's when
    /// every hint for `tag` names one id; `nil` when neither answers. A hint's answer carries its link, which this port's
    /// suppressor reads (ADR 2026-11.sv5t); one hint per id makes it one link. A yielded answer is counted as the hint's.
    func linkAnswer(_ tag: NodeId) -> Answer? {
        if let answer = claimAnswer(tag) {
            if answer.source == .claim {
                counts.resolvedByClaim += 1
            } else {
                counts.resolvedByHint += 1
            }
            return answer
        }
        let hinted = hints.filter { $0.value.tag == tag }
        let ids = Set(hinted.values.map(\.claim.nodeId))
        guard ids.count == 1, let id = ids.first else {
            return nil
        }
        counts.resolvedByHint += 1
        return Answer(nodeId: id, source: .hint, claimant: hinted.count == 1 ? hinted.first?.key : nil)
    }

    /// What `tag`'s claim answers, read alike by ``resolve(_:)`` and ``standing(_:)`` so a sighting's attribution and the
    /// decide-time read never disagree: the claim while its link is held; once that link has ended, the hint on `tag` that
    /// names the claim's own id, if one is held, else the claim still. `nil` without a claim.
    ///
    /// The yield is this port's, inside ADR 2026-11.sv5t's departure (Kotlin's hint suppresses nothing): a blinding peer
    /// that dials back in after its claimed link dropped tells the same tag, and its hint's link is the one held under its
    /// id, which the ended claim's ``Suppressor/claim(_:)`` never matches, so the dial would go at every head start for
    /// the claim's lifetime (`iphone-rotate` run 2, knit-peer reading the lab iPhone, 2026-11-11), refused each time
    /// with nothing to heal it. The hint is chosen by id, never by how many hints the tag holds, so another id's hint, a
    /// Sybil's included, brings no redial back. A Sybil that won a stranger's tag and relinks telling it holds the dial off
    /// while its new link is held: sv5t's "forged hint" residual, which a hint alone already reaches.
    func claimAnswer(_ tag: NodeId) -> Answer? {
        guard let claim = claims[tag] else {
            return nil
        }
        let ownHint = heldLinks.contains(claim.link) ? nil : hints.first { $0.value.tag == tag && $0.value.claim.nodeId == claim.nodeId }
        guard let ownHint else {
            return Answer(nodeId: claim.nodeId, source: .claim, claimant: claim.link)
        }
        return Answer(nodeId: claim.nodeId, source: .hint, claimant: ownHint.key)
    }

    /// ``onDialProved(_:provenId:)``'s work once the proof stands: liars voided, their void lifted, a proven rival contested.
    func settleRivals(_ tag: NodeId, provenId: NodeId, now: Int64) -> Bool {
        let rivals = ([claims[tag], pending[tag]].compactMap(\.self) + hints.values.filter { $0.tag == tag }.map(\.claim))
            .filter { $0.nodeId != provenId }
        let proven = rivals.filter(\.dialProven)
        let liars = rivals.filter { !$0.dialProven }
        for liar in liars {
            voidLiar(liar.link, liar.nodeId)
        }
        if !liars.isEmpty {
            counts.proofMismatches += 1
        }
        let standing = voided[tag]
        let lifted = standing.map { !$0.dialProven } ?? false
        if let standing, lifted {
            liftVoid(tag, standing, provenId: provenId)
        }
        if !proven.isEmpty {
            void(tag, now: now, dialProven: true, claimants: proven, incoming: 0)
        }
        return !rivals.isEmpty || lifted
    }

    /// Promotes `tag`'s announced entry to its link's claim; the entry goes only once its record settles.
    func promotePending(_ tag: NodeId, now: Int64) {
        guard let announced = pending[tag] else {
            return
        }
        let outcome = record(announced.link, tag: tag, nodeId: announced.nodeId, now: now, dialProven: false)
        if outcome.settles, pending[tag] === announced {
            pending[tag] = nil
        }
    }

    /// Holds `tag`, which `link` announced as `provenId`'s, until it is heard (`holdPending`, `:627-647`).
    func holdPending(_ link: L, provenId: NodeId, tag: NodeId, now: Int64) -> ClaimOutcome {
        let incoming = Claim(link: link, nodeId: provenId, expiresAt: now + configuration.claimLifetimeMilliseconds, dialProven: false)
        if let rival = pending[tag] ?? claims[tag], rival.nodeId != provenId {
            void(tag, now: now, dialProven: false, claimants: [rival, incoming], incoming: 1)
            return .contested
        }
        pending = pending.filter { $0.value.link != link && $0.value.nodeId != provenId }
        // At the cap an ended link's announcement goes before a held link's, the soonest to expire first.
        if pending.count >= configuration.entryCap {
            evictPending()
        }
        pending[tag] = incoming
        queue(.claim(.pending, tag, incoming), at: incoming.expiresAt)
        return .pending
    }

    /// One `TAG_NEXT` per link per window, counted on arrival (`tagNextAllowed`, `:649-657`).
    func tagNextAllowed(_ link: L, now: Int64) -> Bool {
        if let last = lastTagNext[link], (0..<configuration.tagNextMinIntervalMilliseconds).contains(now - last) {
            return false
        }
        lastTagNext[link] = now
        return true
    }

    /// Removes every claim, announced tag and hint of `link` and of `nodeId`, counting each as voided.
    func voidLiar(_ link: L, _ nodeId: NodeId) {
        let lied = { (claim: Claim) in claim.link == link || claim.nodeId == nodeId }
        let before = claims.count + pending.count + hints.count
        claims = claims.filter { !lied($0.value) }
        pending = pending.filter { !lied($0.value) }
        hints = hints.filter { !lied($0.value.claim) }
        counts.claimsVoided += before - claims.count - pending.count - hints.count
    }

    /// Our dial proved `provenId` for a tag that unproven claimants voided: the void goes, and so do they.
    func liftVoid(_ tag: NodeId, _ mark: VoidMark, provenId: NodeId) {
        voided[tag] = nil
        for claimant in mark.claimants where claimant.nodeId != provenId {
            voidLiar(claimant.link, claimant.nodeId)
        }
        counts.proofMismatches += 1
    }

    /// Drops what has come due: replaced keys past their cap, the window's slots, then the deadline queue's entries.
    func expire(_ now: Int64) {
        table.lapse(now: now)
        table.slide(wall: wallClock())
        while let due = deadlines.popDue(now) {
            switch due {
            case .claim(let kind, let tag, let claim):
                lapse(kind, tag, claim, now: now)
            case .void(let tag, let mark):
                if voided[tag] === mark, mark.expiresAt <= now {
                    voided[tag] = nil
                }
            }
        }
    }

    /// Removes `claim` from its table if it is still the entry under `tag`, its link is not held, and it is due.
    func lapse(_ kind: Table, _ tag: NodeId, _ claim: Claim, now: Int64) {
        guard !heldLinks.contains(claim.link), claim.expiresAt <= now else {
            return
        }
        switch kind {
        case .claims where claims[tag] === claim:
            claims[tag] = nil
        case .pending where pending[tag] === claim:
            pending[tag] = nil
        default:
            break
        }
    }

    func extend(_ kind: Table, _ tag: NodeId, _ claim: Claim, until: Int64) {
        claim.expiresAt = max(claim.expiresAt, until)
        queue(.claim(kind, tag, claim), at: claim.expiresAt)
    }

    /// Queues an expiry. Stale deadlines are dropped when due; if they ever outnumber the live entries by far, the queue is
    /// rebuilt from the tables.
    func queue(_ lapse: Lapse, at: Int64) {
        deadlines.push(lapse, at: at)
        let live = claims.count + pending.count + voided.count
        if deadlines.count > Configuration.queueSlack * live + Configuration.queueFloor {
            deadlines.removeAll()
            for (tag, claim) in claims {
                deadlines.push(.claim(.claims, tag, claim), at: claim.expiresAt)
            }
            for (tag, claim) in pending {
                deadlines.push(.claim(.pending, tag, claim), at: claim.expiresAt)
            }
            for (tag, mark) in voided {
                deadlines.push(.void(tag, mark), at: mark.expiresAt)
            }
        }
    }

    /// Records `nodeId`'s claim to `tag` on `link`, replacing the link's and the id's other claim; `dialProven` when a dial
    /// of ours to this very tag proved `nodeId` (`record`, `:757-774`).
    ///
    /// Kotlin's `record` also lifts a void unproven claimants made, and voids the tag against a rival id's claim. Neither
    /// can meet a claim here, so this port leaves both out:
    /// - a claim our dial proved is recorded only after ``onDialProved(_:provenId:)`` settled the same tag
    ///   (``settleRivals(_:provenId:now:)``): every rival that no dial of ours proved is voided as a liar, the void they made
    ///   is lifted, and a rival our own dial proved voids the tag here, so a void still standing is one our dials made;
    /// - an announced tag never stands beside another id's claim, since ``holdPending(_:provenId:tag:now:)`` voids one
    ///   announced against a claim, and a dial's settling voids an announcement another id made.
    ///
    /// `tag` is always a tag: the dialed one, or an announced one ``onTagNext(_:provenId:tag:)`` checked.
    func record(_ link: L, tag: NodeId, nodeId: NodeId, now: Int64, dialProven: Bool) -> ClaimOutcome {
        if isOwn(tag) {
            return ignored()
        }
        if voided[tag] != nil {
            return contested()
        }
        if let keyId = keyAnswer(tag) {
            return agreement(keyId, nodeId)
        }
        let claim = Claim(link: link, nodeId: nodeId, expiresAt: now + configuration.claimLifetimeMilliseconds, dialProven: dialProven)
        return place(claim, tag)
    }

    /// Places a claim the rules let through: the link's and the id's other claim go first. When the table is full, the
    /// ended-link claim that expires soonest (an unproven one first among equals) makes room; a held link's claim is never
    /// refused (`place`, `:792-812`).
    func place(_ claim: Claim, _ tag: NodeId) -> ClaimOutcome {
        let replaced = { (other: Claim) in other.link == claim.link || other.nodeId == claim.nodeId }
        if claims.values.count(where: { !replaced($0) }) >= configuration.maxClaims {
            let victim = claims.filter { !heldLinks.contains($0.value.link) && !replaced($0.value) }
                .min { lhs, rhs in
                    (lhs.value.expiresAt, lhs.value.dialProven ? 1 : 0) < (rhs.value.expiresAt, rhs.value.dialProven ? 1 : 0)
                }
            if let victim {
                claims[victim.key] = nil
                counts.claimsEvicted += 1
            } else if !heldLinks.contains(claim.link) {
                counts.claimsRefusedFull += 1
                return .full
            }
        }
        claims = claims.filter { !replaced($0.value) }
        claims[tag] = claim
        queue(.claim(.claims, tag, claim), at: claim.expiresAt)
        counts.claimsRecorded += 1
        return .recorded
    }

    /// Two ids claimed `tag`: neither resolves it, no hint does either, and none may claim it again until it would have
    /// expired. `incoming` counts the claim that found the rival. `dialProven` when every claimant was proven by our own
    /// dial: only then does the void stand against a later dial's proof (`void`, `:819-836`).
    func void(_ tag: NodeId, now: Int64, dialProven: Bool, claimants: [Claim], incoming: Int) {
        let hinted = hints.values.count { $0.tag == tag }
        hints = hints.filter { $0.value.tag != tag }
        let removed = (claims.removeValue(forKey: tag) == nil ? 0 : 1) + (pending.removeValue(forKey: tag) == nil ? 0 : 1)
        counts.claimsVoided += removed + hinted + incoming
        // At the cap a void unproven claimants made goes before one two of our dials made, the soonest first.
        if voided[tag] == nil, voided.count >= configuration.entryCap {
            let victim = voided.min { lhs, rhs in
                (lhs.value.dialProven ? 1 : 0, lhs.value.expiresAt) < (rhs.value.dialProven ? 1 : 0, rhs.value.expiresAt)
            }
            if let victim {
                voided[victim.key] = nil
                counts.entriesEvicted += 1
            }
        }
        let mark = VoidMark(expiresAt: now + configuration.claimLifetimeMilliseconds, dialProven: dialProven, claimants: claimants)
        voided[tag] = mark
        queue(.void(tag, mark), at: mark.expiresAt)
    }

    /// Evicts the announced tag an ended link made that expires soonest, else a held link's.
    func evictPending() {
        let victim = pending.min { lhs, rhs in
            let left = (heldLinks.contains(lhs.value.link) ? 1 : 0, lhs.value.expiresAt)
            let right = (heldLinks.contains(rhs.value.link) ? 1 : 0, rhs.value.expiresAt)
            return left < right
        }
        if let victim {
            pending[victim.key] = nil
            counts.entriesEvicted += 1
        }
    }

    /// A key resolved `tag` to `nodeId`: a claim, an announced tag or a hint naming another id for it goes.
    func dropContradicted(_ tag: NodeId, _ nodeId: NodeId) {
        if let claim = claims[tag], claim.nodeId != nodeId {
            claims[tag] = nil
            counts.claimsDropped += 1
        }
        if let announced = pending[tag], announced.nodeId != nodeId {
            pending[tag] = nil
            counts.claimsDropped += 1
        }
        let contradicted = { (hint: (tag: NodeId, claim: Claim)) in hint.tag == tag && hint.claim.nodeId != nodeId }
        counts.claimsDropped += hints.values.count(where: contradicted)
        hints = hints.filter { !contradicted($0.value) }
    }

    /// A key answered `keyId` for a tag claimed as `claimedId`: nothing to record, and a different id is counted.
    func agreement(_ keyId: NodeId, _ claimedId: NodeId) -> ClaimOutcome {
        guard keyId != claimedId else {
            return .redundant
        }
        counts.claimsDropped += 1
        return .contradicted
    }

    func ignored() -> ClaimOutcome {
        counts.claimsIgnored += 1
        return .ignored
    }

    func contested() -> ClaimOutcome {
        counts.claimsVoided += 1
        return .contested
    }
}
