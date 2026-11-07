import KnitWire

/// What a dial, its in-flight slot and its backoff are booked under once an advert can name a tag (knit-next ADR
/// 2026-11.xp6d's reader, obligation 9; `DialKeys.kt` at `cad69c77b`; ADR 2026-11.sv5t), and the streaks beside it. Kotlin
/// splices strings (`id`, `~zzzz…n@address`, `@address`); here each kind is a case, so no key can be read as another.
internal enum DialKey: Hashable, Sendable, CustomStringConvertible {
    /// A per-peer key's own streak: a clear dial's id (so a clear peer's backoff behaves exactly as it always did), a
    /// link's end under its id, or an unresolved form's handle streak (``DialKeys/handleKey(_:unresolved:)``).
    case peer(SightingKey)
    /// A dial to a blinded advert: the form's handle and the address it airs from, `nil` when none is known (such a peer is
    /// never dialable anyway). Every dial to a blinded advert is one, whether or not a key resolves the tag (ADR
    /// 2026-11.sv5t): a failed tag dial is the tag's and the address's, never the unproven id its reply names, and a
    /// replayer at another address never backs the tag's owner off under this key.
    case tag(FormHandle, RadioAddress?)
    /// The address streak a failed dial to an unresolved form also advances (``DialKeys/addressKey(_:unresolved:)``): an
    /// airer that changes its tag every few seconds from one address, each tag a new dial key, still backs off.
    case address(RadioAddress)

    /// Redacted by construction: a handle, never a tag, and an address only as the radio's opaque handle.
    var description: String {
        switch self {
        case .peer(let key):
            key.description
        case .tag(let handle, let address):
            "\(handle)@\(address?.rawValue ?? "?")"
        case .address(let address):
            "@\(address.rawValue)"
        }
    }
}

/// A dial in flight (`DialPlan.InFlight`, `DialPlan.kt:22-36`): its kind, recorded when it starts and never inferred
/// from the order; the per-peer key it was attributed to then (the resolved id, or an unresolved form's handle); and
/// whether that key already held a link when it began, so a refusal of a dial that began held is booked for
/// ``HeldStreaks`` (knit-next ADR 2026-09.hj4a's amendment of 2026-11-06).
internal struct DialRecord: Hashable, Sendable {
    /// Why a dial went out.
    enum Kind: Hashable, Sendable {
        /// The order says we dial, or ADR 2026-09.6es2's exception does.
        case ordinary
        /// A head start toward a flagged peer that would dial us ran out (ADR 2026-10.6eyf).
        case headStart
        /// Seeking dials whatever the order (ADR 2026-10.mueg).
        case seeking
    }

    /// Why it went out.
    let kind: Kind
    /// The per-peer key the sighting it dialed was attributed to.
    let peerKey: SightingKey
    /// Whether `peerKey` held a link when the dial began. Required, never defaulted: the two readings are opposite failures.
    let linkedAtStart: Bool
}

/// The dial key's rules, and how the per-peer filters read its backoff (`DialKeys`, `DialKeys.kt:7-119`). Pure.
internal enum DialKeys {
    /// The age past which a responder has kept a dialed proven link (`ProvenDialStreak.CONFIRM_BY_AGE_MS`), for
    /// ``HeldStreaks``.
    static let confirmByAgeMilliseconds: Int64 = 15_000
    /// The keys one held link earns at most (`HeldStreaks.MAX_KEYS_PER_LINK`).
    static let maxHeldKeysPerLink = 16

    /// The one key a dial to a sighting of `form`, attributed to `key`, is booked under: a clear advert's id, a blinded
    /// one's handle (from `handle`, which every blinded form has while it is remembered, resolved or not) and `address`
    /// (`dialKey`, `:24-28`); `nil` for a blinded form whose handle has gone.
    static func dialKey(form: AdvertOrder.Form, key: SightingKey, address: RadioAddress?, handle: (NodeId) -> FormHandle?) -> DialKey? {
        guard form.blinded else {
            return .peer(key)
        }
        return handle(form.advertised).map { .tag($0, address) }
    }

    /// What a link holds off, of the dial key it was dialed under: that key only when the link is `proven` and the dial
    /// went to a tag (`heldDial`, `:41-44`). A clear dial's key is an id, which a live link already covers; a link the peer
    /// dialed has none.
    static func heldDial(_ dialKey: DialKey?, proven: Bool) -> DialKey? {
        guard proven, case .tag = dialKey else {
            return nil
        }
        return dialKey
    }

    /// Whether a sighting of a `blinded` form is the tag at the address a held proven link of ours was dialed at (`held`,
    /// from ``heldDial(_:proven:)``): another dial reaches the same phone and is refused (`dialHeld`, `:54-58`). Only our own
    /// completed dial writes a key, and it names the address, so no claim, hint, `TAG_NEXT` or HELLO `t` can make one.
    /// `dialKey` is read only when it can matter.
    static func dialHeld(blinded: Bool, held: Set<DialKey>, dialKey: () -> DialKey?) -> Bool {
        guard blinded, !held.isEmpty, let key = dialKey() else {
            return false
        }
        return held.contains(key)
    }

    /// The address streak a failed dial under `dialKey` to an `unresolved` form also advances; `nil` for a clear dial key,
    /// a resolved peer's, and one with no address (`addressKey`, `:66-73`).
    static func addressKey(_ dialKey: DialKey, unresolved: Bool) -> DialKey? {
        guard unresolved, case .tag(_, let address?) = dialKey else {
            return nil
        }
        return .address(address)
    }

    /// The handle streak a failed dial under `dialKey` to an `unresolved` form also advances: the form's own per-peer key,
    /// so one tag aired from two addresses keeps one growing streak; `nil` as ``addressKey(_:unresolved:)`` is
    /// (`handleKey`, `:81-84`).
    static func handleKey(_ dialKey: DialKey, unresolved: Bool) -> DialKey? {
        guard unresolved, case .tag(let handle, _) = dialKey else {
            return nil
        }
        return .peer(.form(handle))
    }

    /// The per-peer keys backing off, for every filter that reads backoff by per-peer key (promotion, the dwell's wake):
    /// each key in `active` that is a per-peer key's own streak (a link's flap backs off the id, a handle its streak), and
    /// each of `sighted` whose dial key (`dialKey`), or, while it resolves to nobody, whose address
    /// (``addressKey(_:unresolved:)``), is in `active` (`backedOff`, `:92-104`).
    static func backedOff(sighted: [SightingKey], active: Set<DialKey>, dialKey: (SightingKey) -> DialKey?) -> Set<SightingKey> {
        var keys = Set<SightingKey>()
        for case .peer(let key) in active {
            keys.insert(key)
        }
        guard active.contains(where: { if case .peer = $0 { false } else { true } }) else {
            return keys
        }
        for key in sighted where !keys.contains(key) {
            guard let dial = dialKey(key) else {
                continue
            }
            let unresolved = key.nodeId == nil
            if active.contains(dial) || addressKey(dial, unresolved: unresolved).map(active.contains) == true {
                keys.insert(key)
            }
        }
        return keys
    }

    /// Whether a dial booked as `record` (under `dialKey`) that failed found its peer linked meanwhile: its key holds a link
    /// that came up during the dial, so it is no failure to back off from. A dial that began held crossed nothing: an
    /// ordinary refusal (`linkedNow`, `:114-118`). With no record, `dialKey` alone is read.
    static func linkedNow(_ record: DialRecord?, dialKey: DialKey, linked: Set<SightingKey>) -> Bool {
        guard let record else {
            if case .peer(let key) = dialKey {
                return linked.contains(key)
            }
            return false
        }
        return !record.linkedAtStart && linked.contains(record.peerKey)
    }
}

/// The dial keys a held link's refused dials were booked under (knit-next ADR 2026-09.hj4a's amendment of 2026-11-06;
/// `HeldStreaks`, `ConnectBackoffPolicy.kt:165-232` at `cad69c77b`), so the link's end clears exactly those and the relink
/// after it is not held off by a backoff the held link earned. An unflagged blinding Android never dials an iPhone, so
/// without this, dials refused at rotation edges while a link was held would leave the relink waiting up to the 180 s cap.
///
/// Only a link that outlived ``confirmByAgeMilliseconds``, a replacement chain counted whole, clears anything, so a fork
/// that dials in, refuses our dial and closes cannot reset the streak each cycle. `L` is the link. Pure.
internal struct HeldStreaks<L: Hashable> {
    /// The age past which a responder has kept a dialed proven link (`ProvenDialStreak.CONFIRM_BY_AGE_MS`, knit-next ADR
    /// 2026-11.264w): it waits at most 5 s for our PROOF and closes as soon as it fails.
    static var confirmByAgeMilliseconds: Int64 { DialKeys.confirmByAgeMilliseconds }
    /// The keys one link earns at most: past it the oldest goes, left to its own backoff uncleared (`MAX_KEYS_PER_LINK`).
    static var maxKeysPerLink: Int { DialKeys.maxHeldKeysPerLink }

    /// What a link earned, oldest first, and how long the links it replaced held before it.
    private struct Earned {
        var keys: [DialKey] = []
        var priorMilliseconds: Int64 = 0

        mutating func add(_ key: DialKey) {
            keys.removeAll { $0 == key }
            keys.append(key)
            if keys.count > HeldStreaks.maxKeysPerLink {
                keys.removeFirst()
            }
        }
    }

    private var earned: [L: Earned] = [:]

    /// A dial booked as `record` under `dialKey` failed: the link `held` names earns the key, if the dial began held and
    /// that link stands.
    mutating func dialFailed(_ record: DialRecord?, dialKey: DialKey, held: (SightingKey) -> L?) {
        guard let record, record.linkedAtStart, let link = held(record.peerKey) else {
            return
        }
        earned[link, default: Earned()].add(dialKey)
    }

    /// `from`, held `fromHeldMilliseconds`, was replaced by `to` under the same id: what it earned stays earned, and its hold
    /// counts towards `to`'s.
    mutating func moved(from: L, to: L, fromHeldMilliseconds: Int64) {
        let carried = earned.removeValue(forKey: from)
        var next = earned[to] ?? Earned()
        next.priorMilliseconds += fromHeldMilliseconds + (carried?.priorMilliseconds ?? 0)
        for key in carried?.keys ?? [] {
            next.add(key)
        }
        earned[to] = next
    }

    /// `link` ended after `heldMilliseconds`: the keys it earned, if its chain outlived the confirm age, which the caller
    /// clears from its backoff book. Forgotten either way.
    mutating func ended(_ link: L, heldMilliseconds: Int64) -> [DialKey] {
        guard let ended = earned.removeValue(forKey: link),
            heldMilliseconds + ended.priorMilliseconds >= Self.confirmByAgeMilliseconds
        else {
            return []
        }
        return ended.keys
    }

    /// The radio went down with every link, and the book with them.
    mutating func clear() {
        earned.removeAll()
    }
}
