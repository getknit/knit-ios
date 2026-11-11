import KnitWire

/// What may hold off a dial to a sighted peer that holds a link here (knit-next ADR 2026-11.xp6d, obligation 11;
/// `BlePresenceTracker.Suppressor`, `BlePresenceTracker.kt:41-64` at `cad69c77b`; ADR 2026-11.sv5t), read against the live
/// links when the dial is decided (``suppressed(id:linked:proven:held:)``), never frozen at the sighting, so a link that
/// comes up after the sighting counts at once. `L` is the link.
internal enum Suppressor<L: Hashable>: Hashable {
    /// Any link to the peer's id: a clear advert, the shipped rule.
    case linked
    /// Only a proven link to the peer's id: a key's answer (nothing counts as linked to X without X's proof).
    case proven
    /// Only the claimant's own link, while it is the one held under the peer's id: a claim's answer. A new link from the
    /// same id is not it, so a liar who relinks cannot keep blocking the dial whose proof would void its lie.
    case claim(L)
    /// Only the hint's own link, while it is the one held under the peer's id: a hint's answer. This port's departure from
    /// Android, whose hint suppresses nothing (ADR 2026-11.sv5t): Android heals the dial a hint costs with its held-link
    /// row, which never fires on an iPhone's link (`BleAdmissionPolicy.heldLinkRow`'s `!heldDoorbell`), so the dial would
    /// be refused or would replace the link.
    case hint(L)
    /// Nothing: an unresolved form's answer. Only our own held proven dial to the same tag and address holds it off
    /// (``DialKeys/dialHeld(blinded:held:dialKey:)``), or its own dial key in flight.
    case never

    /// Whether a link held now holds off a dial to `id` on this answer: any link (`linked`) for a clear advert, a proven
    /// one (`proven`) for a key's, the very link (the one `held` names under the id now) for a claim's or a hint's, none
    /// for an unresolved form's (`DialPlan.suppressed`, `DialPlan.kt:43-55`, with the hint's row added).
    func suppressed(id: NodeId, linked: Set<NodeId>, proven: Set<NodeId>, held: (NodeId) -> L?) -> Bool {
        switch self {
        case .linked:
            linked.contains(id)
        case .proven:
            proven.contains(id)
        case .claim(let link), .hint(let link):
            held(id) == link
        case .never:
            false
        }
    }
}

/// What the reader does with a blinded advert once ``AdvertAliases`` has answered (knit-next ADR 2026-11.xp6d's reader,
/// obligations 8 and 11; `BlindSightings.kt` at `cad69c77b`; ADR 2026-11.sv5t): which per-peer key the sighting lands
/// under, whether it may suppress a dial, and what becomes of the history the form gathered while it resolved to nobody.
///
/// - **Unresolved:** under the form's handle, never suppressing a dial.
/// - **A key's answer** attributes the sighting to the contact's id and carries the form's history (its dwell, its RSSI,
///   its address) to the id, so a contact first heard unresolved keeps its dwell. It suppresses a dial only while that id
///   holds a proven link. Except a **replay**: a tag a key resolves to X, heard from an address whose tag dial proved
///   another id, attributes nothing and carries nothing, so that address is never one dialed as X.
/// - **A claim** attributes from then on and never backwards: a linked liar naming a stranger's tag must not import its
///   dwell or RSSI. It suppresses a dial only while its claimant's own link is the one held under the id.
/// - **A hint** attributes from then on, for presence and RSSI. Here it also suppresses a dial while the hint's own link is
///   held (``Suppressor/hint(_:)``), where Android's suppresses nothing.
/// - **A malformed tag** attributes nothing.
///
/// Pure.
internal enum BlindSightings {
    /// What becomes of the entries the form's handle held while it resolved to nobody.
    enum History: Hashable, Sendable {
        /// Nothing to move: the sighting lands under the handle itself.
        case inPlace
        /// Moved to the id (a key's answer): the form's dwell, RSSI and address go with it.
        case carry
        /// Dropped (a claim's or a hint's answer): the id is attributed from now on, never backwards.
        case drop
    }

    /// Where a sighting lands.
    struct Attribution<L: Hashable>: Hashable {
        /// The per-peer key: the resolved id, or the form's handle.
        let key: SightingKey
        /// What may hold off a dial on it.
        let suppressor: Suppressor<L>
        /// What becomes of the handle's entries.
        let history: History
        /// False for a hint: presence and RSSI only (`Attribution.full`).
        let full: Bool
    }

    /// The attribution of a blinded sighting `resolution` answered, held under `handle` while unresolved; `replayed` when
    /// the sighting's tag and address are a replay (``ReplayMarks``). `nil` drops the sighting (`attribute`, `:62-79`).
    static func attribute<L: Hashable>(_ resolution: AdvertAliases<L>.Resolution, handle: FormHandle, replayed: Bool) -> Attribution<L>? {
        switch resolution {
        case .malformed, .own:
            return nil
        case .unresolved:
            return Attribution(key: .form(handle), suppressor: .never, history: .inPlace, full: true)
        case .resolved(let answer):
            let suppressor = suppressor(of: answer)
            switch answer.source {
            case .key:
                return replayed ? nil : Attribution(key: .node(answer.nodeId), suppressor: suppressor, history: .carry, full: true)
            case .claim:
                return Attribution(key: .node(answer.nodeId), suppressor: suppressor, history: .drop, full: true)
            case .hint:
                return Attribution(key: .node(answer.nodeId), suppressor: suppressor, history: .drop, full: false)
            case .clear:
                return Attribution(key: .node(answer.nodeId), suppressor: suppressor, history: .inPlace, full: true)
            }
        }
    }

    /// What may hold off a dial on `answer`: a key's only through a proven link; a claim's only while the claimant's own
    /// link is the one held under the id, and a hint's only while the hint's own link is (this port's departure, ADR
    /// 2026-11.sv5t), nothing for either without its link; a clear advert's through any link. The sighting's attribution
    /// and the decide-time read (``LinkManager/isHeldOff(_:live:proven:)``) share it, so the two never disagree.
    static func suppressor<L: Hashable>(of answer: AdvertAliases<L>.Answer) -> Suppressor<L> {
        switch answer.source {
        case .key:
            .proven
        case .claim:
            answer.claimant.map(Suppressor.claim) ?? .never
        case .hint:
            answer.claimant.map(Suppressor.hint) ?? .never
        case .clear:
            .linked
        }
    }

    /// Whether a handshake event for `link` (`onDialed`, `onAnswered`, `onTagNext`) may reach the resolver: only while
    /// `registered`, the link held under its id now, is that very link (`current`, `:110-113`). An event that fails it would
    /// otherwise hold a dead link, and its never-lapsing hint or claim, in ``AdvertAliases`` for good.
    static func current<L: Hashable>(registered: L?, link: L) -> Bool {
        registered == link
    }
}

/// The tags and addresses whose tag dial proved an id other than the one a contact's key resolves the tag to: a replay
/// (``BlindSightings``; `ReplayMarks`, `BlindSightings.kt:144-179`). Bounded, the oldest out first; a new tag or a new
/// address is a new pair.
internal struct ReplayMarks {
    /// The pairs kept (`DEFAULT_CAP`).
    static let defaultCap = 64

    private struct Pair: Hashable {
        let tag: NodeId
        let address: RadioAddress
    }

    private let cap: Int
    /// Oldest first; marking a pair again moves it last, as Kotlin's access-ordered map does.
    private var marks: [Pair] = []

    /// Keeps at most ``defaultCap`` pairs.
    init() {
        self.init(cap: Self.defaultCap)
    }

    /// Keeps at most `cap` pairs.
    init(cap: Int) {
        self.cap = cap
    }

    /// Marks `tag` at `address` as a replay.
    mutating func mark(_ tag: NodeId, at address: RadioAddress) {
        let pair = Pair(tag: tag, address: address)
        marks.removeAll { $0 == pair }
        marks.append(pair)
        if marks.count > cap {
            marks.removeFirst()
        }
    }

    /// Whether `tag` at `address` is a replay. A read moves nothing, as Kotlin's `containsKey` does not.
    func replayed(_ tag: NodeId, at address: RadioAddress?) -> Bool {
        guard let address else {
            return false
        }
        return marks.contains(Pair(tag: tag, address: address))
    }

    /// Forgets every pair.
    mutating func clear() {
        marks.removeAll()
    }
}
