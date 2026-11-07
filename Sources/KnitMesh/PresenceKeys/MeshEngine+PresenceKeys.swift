import KnitCrypto
import KnitStore
import KnitWire

/// The presence keys' receive side (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): a ctl 11 is filed for its sender inside
/// the ratchet open that delivered it (`applyPresenceKey` and `notePresenceKey`, `mesh/InboundPipeline.kt:1959-1995` at
/// knit-next `cad69c77b`), and the direct contacts' keys are listed to the radio through ``MeshTransport/listPresenceKeys(_:)``
/// (`MeshManager.feedPresenceKeys`, `MeshManager.kt:1414-1426`), a leaver's deleted as they go (`PresenceKeyEngine.dropLeavers`,
/// `PresenceKeyEngine.kt:506-521`). Receive only: nothing here mints, seals or sends a key.
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
    /// `PresenceKeyEngine.kt:511-512`).
    func startPresenceKeySession() {
        presenceKeyFeed.lastDirect = nil
        notePresenceKeyInputsChanged()
    }

    /// Lists the direct contacts' keys to the radio, when anything that could change them moved since the last listing
    /// (``Mesh`` calls it after every entry, as it re-reads the digest cue): each contact's stored keys, newest first, at
    /// most three, read fresh from the stores, never cached, handed whole to ``MeshTransport/listPresenceKeys(_:)``, which
    /// bounds a contact's churn itself.
    ///
    /// The direct contacts, the keys and the leavers' delete run in one store unit, and nothing is deleted, listed or
    /// remembered unless it commits: outside one a failing read answers nobody, and a first pass would delete every key
    /// and list none, which Android, remembering what it sent each contact per root, would not resend for up to a week.
    /// After a failure the last direct set and the last listing stand, and the next call tries again. The leavers are
    /// counted, never logged (xp6d's 2026-11-04 amendment: a dated sweep says when the user blocked someone).
    public func feedPresenceKeys() {
        let revision = presenceKeyFeed.revision
        guard presenceKeyFeed.listed != revision else {
            return
        }
        let before = presenceKeyFeed.lastDirect
        let unit = stores.transactor.atomically { () -> PresenceKeyFeed.Pass? in
            let direct = directContacts()
            let leavers = before.map { $0.subtracting(direct) } ?? Set(stores.presenceKeys.peersWithKeys()).subtracting(direct)
            stores.presenceKeys.deleteKeys(of: leavers)
            let listing = stores.presenceKeys.keys(of: direct).mapValues { keys in
                keys.prefix(PresenceKeyPolicy.peerGenerations).map(\.held.key)
            }
            return PresenceKeyFeed.Pass(direct: direct, leavers: leavers.count, listing: listing)
        }
        guard case .committed(let pass) = unit else {
            // Once per revision: a store that keeps failing is retried at every settle, and says so once.
            if presenceKeyFeed.warned != revision {
                presenceKeyFeed.warned = revision
                log.log(.warning, "mesh presence key listing skipped: a store failed")
            }
            return
        }
        presenceKeyFeed.lastDirect = pass.direct
        presenceKeyFeed.listed = revision
        presenceKeyFeed.counts.leavers += pass.leavers
        presenceKeyFeed.lastListing = pass.listing
        transport.listPresenceKeys(pass.listing)
    }

    /// Unlists `peer`, whom the user just blocked, at once, and every listed peer whose row carries the device tag the block
    /// covers: the last listing pushed, less them, with no store read the removal needs, so a store that keeps failing
    /// (one damaged row fails every feed's unit) never leaves a blocked contact's tag resolving by key. A drop applies at
    /// once in the link manager (``KeyChurnLimiter``). Their keys go at the next feed that commits, which still counts them
    /// as leavers. Nothing is logged.
    func unlistBlocked(_ peer: NodeId, deviceTag: String?) {
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
        /// How many left the direct contacts, whose keys it deleted.
        let leavers: Int
        /// Each direct contact's keys, newest first.
        let listing: [NodeId: [PresenceKey]]
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
    /// What the receive side did so far.
    var counts = PresenceKeyCounts()
}

/// What the presence keys' receive side did so far (Android's `onPresenceKeyStored` and `onPresenceKeyReplaced`; a refusal is
/// a ``DropReason/presenceKeyRefused``). Counts only, with no time and no peer.
public struct PresenceKeyCounts: Sendable, Equatable {
    /// Frames whose keys were added to their sender's era, or stored with nothing held.
    public internal(set) var stored = 0
    /// Frames whose keys replaced every key held for their sender: a new era.
    public internal(set) var replaced = 0
    /// Peers who left the direct contacts, or were found not to be one at a session's first pass, and whose keys went.
    public internal(set) var leavers = 0
}
