import KnitCrypto
import KnitStore
import KnitWire

/// What a committed presence key pass does with our own keys (ADR 2026-11.prsp, "Our own keys"; `publish` and `sealOwed`,
/// `mesh/PresenceKeyEngine.kt:270-289`, `:437-459` at knit-next `cad69c77b`): our key and the departed set handed to the
/// radio, then one outermost seal per linked direct contact owed what it was not sent under the root its session holds.
extension MeshEngine {
    /// Publishes what `pass` committed (`publish`, `:270-289`): the departed set first, then our current key, so a
    /// `TAG_NEXT` sent right after a fresh key never reads the departures from before it. A settle that did not reach
    /// nothing-due publishes no key and keeps the departures it had: the rows still hold a key a leaver holds as current. A
    /// mint the identity's item refused publishes nothing new. Kotlin guards this with the session's epoch, since its pass
    /// can outlive a `beginSession`; here the pass and ``startPresenceKeySession()`` both run to completion on the engine's
    /// one actor, so no session can begin between a pass's read and its publish.
    func publishOwnKeys(_ pass: PresenceKeyFeed.Pass) {
        presenceKeyFeed.blocked = pass.blocked
        guard pass.own.mintFailed == nil, !pass.own.deferred else {
            return
        }
        if pass.own.reachedNone {
            presenceKeyFeed.departed = PresenceKeyPolicy.departed(rows: pass.rows, direct: pass.direct)
        }
        let current = PresenceKeyPolicy.keysOf(pass.rows).current
        let key =
            configuration.sendsOwnPresenceKeys && pass.own.reachedNone
            ? current.map { OwnPresenceKey(generation: $0.generation, key: $0.key) } : nil
        publishOwnKey(key)
    }

    /// Hands the radio `key` when it differs from what it holds.
    func publishOwnKey(_ key: OwnPresenceKey?) {
        guard presenceKeyFeed.published != key else {
            return
        }
        presenceKeyFeed.published = key
        presenceKeyFeed.counts.ownGeneration = key?.generation
        transport.ownPresenceKeyChanged(key)
    }

    /// Withdraws our published key at once and refuses `TAG_NEXT` to `blocked`, as a block lands (``block(_:)``), with no
    /// store read: a store that keeps failing never leaves someone just blocked resolving our tag. The next pass that
    /// commits mints the fresh pair.
    func withdrawOwnKey(from blocked: Set<NodeId>) {
        presenceKeyFeed.blocked = presenceKeyFeed.blocked?.union(blocked)
        publishOwnKey(nil)
    }

    /// Seals and sends what each linked direct contact is owed under `rows` and has not been sent under the root its session
    /// holds now (`sealOwed`, `:437-454`), one outermost unit each.
    func sendOwedPresenceKeys(rows: [OwnPresenceKeyRecord], direct: Set<NodeId>) {
        guard configuration.sendsOwnPresenceKeys, configuration.ratchet else {
            return
        }
        let keys = PresenceKeyPolicy.keysOf(rows)
        var seen = Set<NodeId>()
        for neighbor in transport.neighbors where seen.insert(neighbor.nodeId).inserted && direct.contains(neighbor.nodeId) {
            sendOwedPresenceKeys(to: neighbor, keys: keys)
        }
    }

    private func sendOwedPresenceKeys(to neighbor: Neighbor, keys: PresenceKeyPolicy.Keys) {
        let peer = neighbor.nodeId
        let owed = PresenceKeyPolicy.owed(peer, keys: keys)
        guard let first = owed.first, readsPresenceKeys(neighbor), transport.hasProvenLink(to: peer) else {
            return
        }
        let generations = owed.map(\.generation)
        // Read outside a unit to compare with the ledger: a store that cannot answer reads as no session, and sends nothing.
        guard let held = ratchet.session(of: peer), held.confirmed else {
            return
        }
        if let was = presenceKeyFeed.sent[peer], was.generations == generations, was.rootTag == RatchetCrypto.rootTag(held.root) {
            return
        }
        let next = owed.dropFirst().first.map { key in (generation: key.generation, key: key.key.bytes) }
        let content = PresenceKeyFrame.content(current: (first.generation, first.key.bytes), next: next)
        let sealing = sealControl(content, to: peer, in: .presenceKeys) {
            // No prekey: a ctl 11 never starts a session (ADR 2026-11.prsp).
            RatchetOutbound.receiptPlan(to: stores.peers.peer(peer), ratchet: true).map { plan in
                RatchetOutbound.ReceiptPlan(bundle: plan.bundle, prekey: nil, readsCryptoV3: false)
            }
        }
        guard case .sealed(let sealed) = sealing else {
            return
        }
        // The advance committed: its floors move whatever follows.
        ratchet.settle(sealed.settlement)
        // A ctl 11's seal always reads its root (``ControlFrame/confirmedOnly``).
        presenceKeyFeed.sent[peer] = sealed.rootTag.map { rootTag in
            PresenceKeyFeed.SentKeys(
                generations: generations,
                rootTag: rootTag,
                link: presenceKeyFeed.linkSequence[peer],
                queuedAt: clock.monotonicMilliseconds()
            )
        }
        router.markOwn(sealed.frame.envelope.id, now: clock.monotonicMilliseconds())
        guard transport.sendOverProvenLink(sealed.frame.wire, to: peer) else {
            // Sealed and never left (`onSendFailed`, `:363-370`): forgotten, so the next pass seals them again.
            presenceKeyFeed.sent[peer] = nil
            presenceKeyFeed.counts.sendsFailed += 1
            presenceKeyTrail("mesh presence keys to \(peer): frame \(sealed.frame.envelope.id) found no proven link")
            return
        }
        presenceKeyFeed.counts.sent += 1
        // `mesh/lab`'s idle-link oracle reads `frame (\S+),` (`:434-435`): keep `frame <id>,` as it is.
        presenceKeyTrail("mesh presence keys sealed to \(peer): frame \(sealed.frame.envelope.id), \(generations.count) generations")
    }

    /// Whether `neighbor` reads our keys: its HELLO or its pinned profile carries `CAP_BLIND_ADVERT` and `CAP_LINK_PROOF`,
    /// and its pinned profile `CAP_RATCHET` (ADR 2026-11.prsp; `capable`, `:457-459`, adds only the first). A row that cannot
    /// be read reads as none, which sends nothing.
    func readsPresenceKeys(_ neighbor: Neighbor) -> Bool {
        let pinned = Capabilities(rawValue: stores.peers.peer(neighbor.nodeId)?.capabilities ?? 0)
        let bits = neighbor.capabilities.union(pinned)
        return bits.contains(.blindAdvert) && bits.contains(.linkProof) && pinned.contains(.ratchet)
    }

    /// An open, a reset's adoption or a race's resolution with `peer` just committed (`ratchet.rootChanges`'s reconcile,
    /// `MeshManager.kt:1401`, `RatchetSessions.kt:64-115` at knit-next `cad69c77b`): our keys' pass is owed when the
    /// session it left is confirmed and its root is not the one the ledger records for that peer, the answer to our own init
    /// among them. Only for a linked peer that reads our keys; a flag in memory, and the ledger's compare keeps a pass that
    /// finds nothing new from sealing.
    func notePresenceRootMoved(_ peer: NodeId) {
        guard configuration.sendsOwnPresenceKeys, configuration.ratchet,
            let neighbor = transport.neighbors.first(where: { $0.nodeId == peer }), readsPresenceKeys(neighbor),
            let held = ratchet.session(of: peer), held.confirmed,
            presenceKeyFeed.sent[peer]?.rootTag != RatchetCrypto.rootTag(held.root)
        else {
            return
        }
        noteOwnPresenceKeyPassOwed()
    }

    /// One line of the per-decision trail, only where the configuration asks for it.
    func presenceKeyTrail(_ line: @autoclosure () -> String) {
        if configuration.logsPresenceKeyTrail {
            log.log(.debug, line())
        }
    }
}
