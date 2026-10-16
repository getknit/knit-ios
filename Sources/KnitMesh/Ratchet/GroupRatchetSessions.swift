public import KnitCrypto
public import KnitStore
public import KnitWire

/// The group form's session service (`GroupRatchetSessions` in knit-next's `mesh/crypto/ratchet/GroupRatchetSessions.kt`,
/// at `cbf2a487`): the pure ``GroupRatchetEngine`` over a ``GroupRatchetStore``, our node id, and the floors held in
/// memory per group and sender (ADR 2026-10.5sk9). Nothing in the mesh calls it before phase P6a2 (the receive path) and
/// P6b (the send path); A9's group transcripts and the tests drive it directly.
///
/// **One phase, in a store unit,** as ``RatchetSessions`` runs. Android peeks with no lock, then commits under the one
/// ratchet mutex both facades share, inside a Room transaction (`:9-34`). This port's engine runs on one actor, so each
/// call decides and writes inside one ``StoreTransactor`` unit, which joins the caller's unit when one is open: an
/// adoption runs inside the open of the `CTL_GROUP_KEY` DM that carried it, as Kotlin's `adoptSeeds` runs inside the DM
/// commit (`:115-118`), and the store is read inside the unit too, so a store that cannot answer fails the unit rather
/// than deciding on its fallback. Every call answers an ``Answer``: ``Answer/settled(_:)``, ``Answer/joined(_:_:)``,
/// whose ``Settlement`` the caller applies with ``settle(_:)`` once its outermost unit commits, or ``Answer/failed``.
///
/// **The floors held in memory,** as Kotlin holds them (`:36-43`), die with the process: the fresh adoptions per group
/// and sender within the last day, at most ``maxAdoptionsPerDay`` (`:274`), which bounds the skipped keys a sender can
/// make us bank; the key-request heuristic's distinct undecryptable frame ids; and when we last asked each sender for its
/// key. An adoption moves its floor only once the outermost unit commits, where Kotlin stamps it as it adopts, inside the
/// transaction, so a rollback there still costs one of the day's four. The heuristic's ids join at once, on the drop
/// path outside any unit, as Kotlin's do, and ``markKeyRequested(in:from:now:)`` is the caller's to call once its
/// request's unit commits.
public final class GroupRatchetSessions {
    /// Fresh adoptions per group and sender per day: a count's, an age's, a leave's and a wipe's advances all fit
    /// (`MAX_ADOPTIONS_PER_DAY`, `GroupRatchetSessions.kt:274`).
    public static let maxAdoptionsPerDay = 4
    /// The adoption floor's sliding window (`ADOPTION_WINDOW_MS`).
    public static let adoptionWindowMilliseconds: Int64 = 86_400_000
    /// Distinct undecryptable frames from a group's sender before a key request is due (`REQUEST_DISTINCT_FRAMES`): custody
    /// re-serves one frame endlessly, and one stuck frame must not trigger anything.
    public static let requestDistinctFrames = 3
    /// The most undecryptable ids held per group and sender (`REQUEST_TRACKED_FRAMES`).
    public static let requestTrackedFrames = 8
    /// One key request per group and sender at most this often (`KEY_REQUEST_MIN_INTERVAL_MS`), cheaper and gentler than the
    /// DM's six-hour reset.
    public static let keyRequestMilliseconds: Int64 = 3_600_000
    /// A frame older than this, by its own stamp, never feeds the heuristic (`REQUEST_MAX_FRAME_AGE_MS`), custody's
    /// dead-on-arrival guard: its epoch is rightly swept everywhere.
    public static let requestMaxFrameAgeMilliseconds: Int64 = 172_800_000

    let nodeId: NodeId
    let store: any GroupRatchetStore
    let transactor: any StoreTransactor
    let engine: GroupRatchetEngine

    /// Per group and sender, when a fresh chain was adopted, oldest first (`adoptionTimes`, `:36-37`).
    var adoptions: [GroupSender: [Int64]] = [:]
    /// Per group and sender, the distinct undecryptable frame ids, oldest first, at most ``requestTrackedFrames``
    /// (`undecryptable`, `:39-40`). Ids compare by their bytes (ADR 2026-09.jc2x).
    var undecryptable: [GroupSender: [ExactKey]] = [:]
    /// Per group and sender, when we last sent a key request (`lastKeyRequestAt`, `:42-43`).
    var lastKeyRequestAt: [GroupSender: Int64] = [:]

    /// A session service for `nodeId`, our own, over `store`, whose units `transactor` runs. `engine` draws from the
    /// system's generator unless a test or a vector replay passes another.
    public init(
        nodeId: NodeId, store: any GroupRatchetStore, transactor: any StoreTransactor, engine: GroupRatchetEngine = GroupRatchetEngine()
    ) {
        self.nodeId = nodeId
        self.store = store
        self.transactor = transactor
        self.engine = engine
    }

    /// Opens one group frame from `sender`, the frame's verified author, in `group`, and commits what the open changed
    /// together with what `alongside` writes, in one store unit (`peekOpen` and `commitOpen`, `:57-99`, as one phase). The
    /// chain advanced, the keys banked and the ones spent stand with the caller's message row or reaction, or none of them
    /// does. `alongside` runs inside the unit once the frame has opened, with the plaintext; it writes stores and nothing
    /// else, and answers the work for after the commit, or `nil` to abandon the unit with the open. An open moves no floor.
    public func open<Work>(
        _ frame: Frame,
        in group: String,
        from sender: NodeId,
        now: Int64,
        alongside: (GroupRatchetEngine.OpenOutcome.Opened) -> Work?
    ) -> Answer<Opening<Work>> {
        var unopened = Opening<Work>.abandoned
        let unit = transactor.atomically { () -> Opening<Work>? in
            let context = GroupRatchetEngine.OpenContext(
                chains: store.recvChains(group, from: sender, epoch: frame.header.se).map(GroupRatchetRecords.recvChain),
                skippedKeys: store.skippedKeys(group, from: sender, epoch: frame.header.se, index: frame.header.n)
                    .map(GroupRatchetRecords.skippedKey)
            )
            switch engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: now) {
            case .failed(let failure):
                unopened = .refused(failure)
                return nil
            case .opened(let opened):
                store.applyOpen(GroupRatchetRecords.record(opened.delta), in: group, from: sender, se: frame.header.se, n: frame.header.n)
                guard let work = alongside(opened) else {
                    return nil
                }
                return .opened(plaintext: opened.plaintext, work: work)
            }
        }
        return answer(unit, settlement: .unchanged, otherwise: unopened)
    }

    /// Adopts the seeds of one `CTL_GROUP_KEY` distribution from `sender` in `group` (`adoptSeeds`, `:108-148`), each
    /// against the newest mint held for its epoch: idempotent per `(epoch, mintedAt)`, so a custody re-serve is
    /// acknowledged again with no chain moved, and the sender's outbox converges though the first ack was lost. Fresh
    /// adoptions stop at ``maxAdoptionsPerDay`` per group and sender, counting those this call has made: the
    /// skipped-key pump's bound, which a count's, an age's, a leave's and a wipe's advances fit under. The roster gate (the
    /// group held, not left, the sender a member) is the caller's, which holds the group's rows, before it calls this.
    ///
    /// Inside the open of the DM that carried the seeds, which is where it belongs, it answers ``Answer/joined(_:_:)``: the
    /// chains stand with that open, and the floor moves only once its caller settles after the outermost commit. The floor
    /// reads only what has settled, so two distributions joined into one outer unit would each read it as it stood before
    /// that unit: the caller settles each DM's open before the next one opens.
    public func adoptSeeds(_ seeds: [GroupSeed], in group: String, from sender: NodeId, now: Int64) -> Answer<Adoption> {
        let adopter = GroupSender(group, sender)
        let held = adoptionsWithinWindow(adopter, now: now).count
        var fresh = 0
        let unit = transactor.atomically { () -> Adoption? in
            var verdicts: [Adoption.Verdict] = []
            var acknowledged: [Int] = []
            for seed in seeds {
                let newest = store.recvChains(group, from: sender, epoch: seed.epoch).first.map(GroupRatchetRecords.recvChain)
                let outcome = engine.adoptSeed(
                    existing: newest,
                    groupId: group,
                    senderId: sender,
                    epoch: seed.epoch,
                    seed: seed.seed,
                    mintedAt: seed.mintedAt,
                    now: now
                )
                switch outcome {
                case .adopt(let chain) where held + fresh < Self.maxAdoptionsPerDay:
                    store.insertRecvChain(GroupRatchetRecords.record(chain), in: group, from: sender)
                    fresh += 1
                    verdicts.append(.adopted)
                    acknowledged.append(seed.epoch)
                case .adopt:
                    verdicts.append(.floored)
                case .alreadyKnown:
                    verdicts.append(.alreadyKnown)
                    acknowledged.append(seed.epoch)
                case .stale:
                    verdicts.append(.stale)
                }
            }
            return Adoption(ackEpoch: acknowledged.max(), freshChains: fresh, verdicts: verdicts)
        }
        let settlement = Settlement(adopter: adopter, adoptions: fresh, at: now)
        return answer(unit, settlement: settlement, otherwise: Adoption(ackEpoch: nil, freshChains: 0, verdicts: []))
    }

    /// Seals one frame to `group` under our send chain, minting a fresh epoch when the advance rules call for one: none
    /// yet, the count, the age, and a forced rekey's retired chain, which the mint numbers past; a wipe's empty store
    /// restarts at epoch 1 (`sealGroup`, `:174-198`). Read, mint, seal and persist in one unit, so the chain is stored
    /// before the envelope is answered. A minted seed is the caller's to distribute to the roster, and the outbox rows to
    /// record, strictly after, before the frame floods (P6b's).
    public func sealGroup(plaintext: [UInt8], aad: [UInt8], in group: String, now: Int64) -> Answer<Sealing> {
        let unit = transactor.atomically { () -> Sealing? in
            let held = store.sendChain(group).map(GroupRatchetRecords.sendChain)
            let minted =
                GroupRatchetEngine.needsNewEpoch(held, now: now)
                ? engine.mint(groupId: group, selfId: nodeId, previousEpoch: held?.epoch ?? 0, now: now) : nil
            // Kotlin's seal answers null only for a chain at the cap, which a mint has just replaced; here a test's IV that
            // is not 12 bytes also refuses, and the unit is abandoned with the mint.
            guard let chain = minted ?? held, let sealed = try? engine.seal(chain, plaintext: plaintext, aad: aad) else {
                return nil
            }
            store.commitSend(GroupRatchetRecords.record(sealed.chain), in: group)
            let envelope = EncEnvelope(
                version: EncEnvelope.Version.ratchet, nonce: sealed.nonce, ct: sealed.ct, keys: [], groupRatchet: sealed.header)
            return .sealed(envelope, minted: minted.map { GroupSeed(epoch: $0.epoch, seed: $0.seed, mintedAt: $0.mintedAt) })
        }
        return answer(unit, settlement: .unchanged, otherwise: .unavailable)
    }

    /// Our retained seeds for `group`, the newest epoch first: the current one and a draining previous one, which a key
    /// request's answer, the re-send flush and a reset's forced flush re-distribute (`currentSeeds`, `:200-206`). Empty
    /// right after a forced rekey: the retired chain holds no seed and is never re-served (knit-next ADR 2026-10.xgwj).
    /// Read in a unit, so a store that cannot answer fails rather than reading as no seeds.
    public func currentSeeds(of group: String) -> Answer<[GroupSeed]> {
        let unit = transactor.atomically { () -> [GroupSeed]? in
            store.sendChains(group).map { GroupSeed(epoch: $0.epoch, seed: $0.seed, mintedAt: $0.mintedAt) }
        }
        return answer(unit, settlement: .unchanged, otherwise: [])
    }

    /// Records in the outbox that we sent `member` our `epoch` in `group` at `now`, the send path's bookkeeping beside a
    /// seed DM's seal (`markKeySent`, `:150-159`): the outbox, not custody, is the truth of what the member holds. Answers the
    /// row as it stands.
    public func markKeySent(_ epoch: Int, to member: NodeId, in group: String, now: Int64) -> Answer<GroupKeySendRecord?> {
        let unit = transactor.atomically { () -> GroupKeySendRecord?? in
            store.markKeySent(group, to: member, epoch: epoch, at: now)
            return .some(store.keySend(group, member: member))
        }
        return answer(unit, settlement: .unchanged, otherwise: nil)
    }

    /// `member`'s outbox row in `group`, or `nil` when we never sent it a seed (`keySend`, `:161-165`).
    public func keySend(to member: NodeId, in group: String) -> Answer<GroupKeySendRecord?> {
        let unit = transactor.atomically { () -> GroupKeySendRecord?? in .some(store.keySend(group, member: member)) }
        return answer(unit, settlement: .unchanged, otherwise: nil)
    }

    /// Stamps `member`'s `CTL_GROUP_KEY_ACK` of `epoch` into `group`'s outbox (`onKeyAck`, `:208-216`), inside the open of
    /// the DM that carried it: only a newer epoch moves the row, and an ack with no row is ignored. Answers the row as it
    /// stands.
    public func onKeyAck(_ epoch: Int, from member: NodeId, in group: String, now: Int64) -> Answer<GroupKeySendRecord?> {
        let unit = transactor.atomically { () -> GroupKeySendRecord?? in
            store.markKeyAcked(group, by: member, epoch: epoch, at: now)
            return .some(store.keySend(group, member: member))
        }
        return answer(unit, settlement: .unchanged, otherwise: nil)
    }

    /// Records an undecryptable group frame from `sender` in `group`, the frame `frameId` signed at `sentAt`, and says
    /// whether a key request toward that sender is due (`noteUndecryptable`, `:232-256`, and the age gate before it,
    /// `InboundPipeline.kt:1700-1701`). The caller calls it for a `NO_KEY` or `AEAD_FAIL` from an open that answered
    /// ``Answer/settled(_:)``, never ``Answer/failed``, on the drop path and outside any unit, as Kotlin does.
    /// - **The age gate first:** a frame more than ``requestMaxFrameAgeMilliseconds`` older than `now` by its own stamp,
    ///   the envelope's signed `sentAt`, counts nothing, so an ancient replay never spends the request budget. That
    ///   compares the sender's clock with ours, loosely, as custody's dead-on-arrival guard does.
    /// - **Then the count:** the id joins the last ``requestTrackedFrames`` at once, and a request is due at
    ///   ``requestDistinctFrames`` distinct ids, ``keyRequestMilliseconds`` past our last request to that sender here.
    ///   Check-only: ``markKeyRequested(in:from:now:)`` stamps the floor once the request went.
    public func noteUndecryptable(in group: String, from sender: NodeId, frameId: String, sentAt: Int64, now: Int64) -> Bool {
        guard now &- sentAt <= Self.requestMaxFrameAgeMilliseconds else {
            return false
        }
        let key = GroupSender(group, sender)
        var ids = undecryptable[key] ?? []
        let id = ExactKey(frameId)
        if !ids.contains(id) {
            ids.append(id)
        }
        ids.removeFirst(max(0, ids.count - Self.requestTrackedFrames))
        undecryptable[key] = ids
        guard ids.count >= Self.requestDistinctFrames else {
            return false
        }
        return now &- (lastKeyRequestAt[key] ?? 0) >= Self.keyRequestMilliseconds
    }

    /// Stamps the key-request floor for `sender` in `group` at `now` and clears the heuristic's ids, since the request is
    /// on its way (`markKeyRequested`, `:258-267`): the caller's, once its request's unit commits.
    public func markKeyRequested(in group: String, from sender: NodeId, now: Int64) {
        let key = GroupSender(group, sender)
        lastKeyRequestAt[key] = now
        undecryptable[key] = nil
    }

    /// The floors held in memory for `sender` in `group` at `now`.
    public func floors(in group: String, for sender: NodeId, now: Int64) -> Floors {
        let key = GroupSender(group, sender)
        return Floors(
            adoptions: adoptionsWithinWindow(key, now: now).count,
            undecryptableIds: undecryptable[key]?.count ?? 0,
            lastKeyRequestAt: lastKeyRequestAt[key]
        )
    }

    /// Moves the floors held in memory as `settlement` says: what a call answered ``Answer/joined(_:_:)`` leaves for after
    /// the caller's outermost unit commits.
    public func settle(_ settlement: Settlement) {
        guard let adopter = settlement.adopter, settlement.adoptions > 0 else {
            return
        }
        adoptions[adopter] =
            adoptionsWithinWindow(adopter, now: settlement.at) + Array(repeating: settlement.at, count: settlement.adoptions)
    }

    /// The retention sweep at `now`, in a unit of its own, and whether it stood (`sweep`, `:269-270`, over
    /// ``GroupRatchetStore/sweep(now:)``). The engine is to run it beside ``RatchetSessions/sweep(now:)``, at start and
    /// then every ``RatchetSessions/sweepMilliseconds``, as Android's one retention sweep runs both (`sweepKeyRetention`,
    /// `MeshManager.kt:988-993`), and never inside another unit, so no send waits behind the checkpoint the database's
    /// sweep runs as it commits. Nothing schedules it before P6a2.
    @discardableResult
    public func sweep(now: Int64) -> Bool {
        let unit = transactor.atomically { () -> Void? in
            store.sweep(now: now)
            return ()
        }
        switch unit {
        case .committed, .joined:
            return true
        case .abandoned, .failed:
            return false
        }
    }

    /// The fresh adoptions held for `adopter` that are still inside the day at `now`, oldest first: Kotlin's window, which
    /// drops from the front while the oldest is a day old (`recordAdoption`, `:218-230`).
    private func adoptionsWithinWindow(_ adopter: GroupSender, now: Int64) -> [Int64] {
        var times = adoptions[adopter] ?? []
        while let oldest = times.first, now &- oldest >= Self.adoptionWindowMilliseconds {
            times.removeFirst()
        }
        return times
    }

    /// What a unit came to, as this answers it: the floors move at once when it committed as the outermost, and go up to
    /// the caller when it joined one; `otherwise` is what a unit that wrote nothing says.
    private func answer<Result>(_ unit: Transacted<Result>, settlement: Settlement, otherwise: Result) -> Answer<Result> {
        switch unit {
        case .committed(let result):
            settle(settlement)
            return .settled(result)
        case .joined(let result):
            return .joined(result, settlement)
        case .abandoned:
            return .settled(otherwise)
        case .failed:
            return .failed
        }
    }
}
