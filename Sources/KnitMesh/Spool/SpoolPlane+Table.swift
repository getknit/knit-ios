import KnitWire

/// The plane's table and the engine's cues (ADR 2026-11.adrq, P4a): custody changed, the gate moved, a block, and the
/// table's re-read between inputs.
extension SpoolPlane {
    // MARK: Inputs from the engine

    /// Custody changed: every scope of every relay looks again. ``Mesh`` calls it where it notices a custody revision
    /// change, beside the advert's digest cue, never per writer.
    mutating func custodyChanged() {
        for relay in relays.keys {
            relays[relay]?.heal.custodyChanged()
        }
    }

    /// Something the gate reads moved (a block or an unblock, an acceptance, a deleted thread, a verification): the table
    /// is read again before the next heal input.
    mutating func markTableDirty() {
        tableDirty = true
    }

    /// Reads the table again now if it is due, and hands every heal the result: a block commit drops its peer's scopes, and
    /// cancels their mining, in the same turn.
    mutating func refreshTable(engine: MeshEngine) {
        guard !relays.isEmpty else {
            return
        }
        let now = engine.clock.monotonicMilliseconds()
        let wall = engine.clock.wallMilliseconds()
        let due =
            tableDirty || readGeneration != engine.ratchet.generation || reconcileAt.map { now >= $0 } != false
            || drainEndAt.map { wall >= $0 } == true
        guard due else {
            return
        }
        let generation = engine.ratchet.generation
        let inputs = engine.spoolTableInputs(now: wall)
        reconcileAt = SpoolSession.later(now, by: Self.reconcileMilliseconds)
        guard let dmScopes = inputs.dmScopes, let accepted = inputs.accepted, let blocked = inputs.blocked, let recent = inputs.recent
        else {
            // A store that could not answer keeps the table, and the next input tries again.
            unreadableTables += 1
            tableDirty = true
            return
        }
        tableDirty = false
        readGeneration = generation
        drainEndAt = dmScopes.compactMap(\.retiringUntil).min()
        let update = table.updated(dmScopes: dmScopes, accepted: accepted, blocked: blocked, recent: recent, relays: Array(relays.keys))
        guard case .table(let next) = update else {
            return
        }
        adopt(next)
    }

    /// `peer` was blocked: its scopes leave the table, and their mining is cancelled, in this turn, whatever the stores
    /// answer; a later read of the blocked set that succeeds decides, and one that fails keeps the table without them.
    mutating func block(_ peer: NodeId, engine: MeshEngine) {
        tableDirty = true
        adopt(table.dropping(peer))
        refreshTable(engine: engine)
    }

    /// Hands every heal `next`: a scope that left cancels its search now, connected or not, since a search can outlive
    /// its connection.
    mutating func adopt(_ next: ScopeTable) {
        table = next
        miner.adopt(next.scopes)
        for (handle, var state) in relays {
            state.heal.adopt(next.scopes)
            mining += state.heal.drain().compactMap(Mining.init)
            state.session?.retainSubscriptions(next.ids)
            relays[handle] = state
        }
    }
}
