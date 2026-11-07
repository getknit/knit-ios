import KnitCrypto
import KnitStore
import KnitWire

/// What a received ctl 11 does to the presence keys held for its sender (knit-next ADR 2026-11.xp6d, "The presence key";
/// ADR 2026-11.sv5t), pure: the receive half of knit-next's `PresenceKeyPolicy` (`mesh/crypto/PresenceKeyPolicy.kt` at
/// `cad69c77b`), `keysIn` (`:299-308`) and `receive` (`:324-356`) with their types (`:255-296`). This port mints, rotates
/// and sends no key of its own, so the own-key rules (`due`, `nextGeneration`, `clampRestored`, `owed`, `departed`,
/// `linkReset`) are not ported. Nothing here reads a clock, a store or a link, and nothing prints a key.
///
/// A generation is the sender's own order for its keys, never a time of ours, and it is compared only with that sender's
/// other generations held under the same era.
internal enum PresenceKeyPolicy {
    /// The generations kept per peer: the three newest (`PEER_GENERATIONS`, `:42`).
    static let peerGenerations = 3

    /// One key a frame offers, lowest generation first (`keysIn`'s pairs).
    struct Offered: Sendable, Equatable {
        /// The sender's generation for it, positive.
        let generation: Int64
        /// The key.
        let key: PresenceKey
    }

    /// Why ``receive(held:frame:openedTag:active:)``, or the inbound arm before it, refused a frame (`Refusal`, `:264-276`).
    /// Every refusal is counted and changes nothing; the chain the frame came on still advances.
    enum Refusal: Sendable, Equatable, CustomStringConvertible {
        /// A key not 32 bytes, a generation not positive, half a next pair, or a next generation not above the first.
        case malformed
        /// From a sender with no peer row, or from ourselves.
        case unknownSender
        /// A generation already held under this era, with other bytes.
        case conflict
        /// A generation lower than every key held, in the same era (or a drain, which never starts one).
        case older

        /// Android's name for it (`Refusal.name`), which the log line prints.
        var description: String {
            switch self {
            case .malformed:
                "MALFORMED"
            case .unknownSender:
                "UNKNOWN_SENDER"
            case .conflict:
                "CONFLICT"
            case .older:
                "OLDER"
            }
        }
    }

    /// What ``receive(held:frame:openedTag:active:)`` decided (`Verdict`, `:279-296`).
    enum Verdict: Sendable, Equatable {
        /// Write `rows`, every key held for the peer afterwards, at most ``peerGenerations``. `replaced` is a new era: every
        /// key held before goes. `added` counts the generations this frame added.
        case store(rows: [HeldPresenceKey], replaced: Bool, added: Int)
        /// Every generation it carries is held with the same bytes: a re-send. Not counted.
        case noOp
        /// Refused, changing nothing.
        case refused(Refusal)
    }

    /// `payload`'s keys, lowest generation first, or `nil` when malformed (`keysIn`, `:299-308`): a key that is not 32
    /// bytes, a generation that is not positive (KnitWire reads `g` as kotlinx does, wrapping past `Int64.max`, so a
    /// wrapped one lands here), half a next pair, a next key that is not 32 bytes, or a next generation not above the first.
    static func keysIn(_ payload: PresenceKeyPayload) -> [Offered]? {
        guard let key = PresenceKey(bytes: payload.key), payload.generation > 0 else {
            return nil
        }
        let first = Offered(generation: payload.generation, key: key)
        switch (payload.nextGeneration, payload.nextKey) {
        case (nil, nil):
            return [first]
        case (let nextGeneration?, let nextBytes?):
            guard let nextKey = PresenceKey(bytes: nextBytes), nextGeneration > payload.generation else {
                return nil
            }
            return [first, Offered(generation: nextGeneration, key: nextKey)]
        default:
            return nil
        }
    }

    /// What a received ctl 11 offering `frame` does to the keys `held` for its sender, given the tag of the root it opened
    /// under, `openedTag`, and whether that is the root the session holds once the open commits, `active` (the pz9g
    /// predicate, ``KnitCrypto/RatchetEngine/OpenDelta/openedUnderActiveRoot``; `receive`, `:324-356`):
    /// - **nothing held:** its keys are stored under `openedTag`. A drain's keys stored so are replaced by the next
    ///   active-root open's as a new era (crypto R3);
    /// - **a new era** (an active-root open, the held keys under another tag): its keys replace every held one, under
    ///   `openedTag`. A restored sender whose generations went backwards lands here;
    /// - **the same era, or a drain** (not active, the held keys under another tag): ordered against the held keys key by
    ///   key, an equal generation with equal bytes skipped, with other bytes `CONFLICT`, one below every held one `OLDER`,
    ///   and any other added under the held keys' own tag. A drain never starts an era and never changes a tag.
    ///
    /// The result keeps the ``peerGenerations`` newest.
    static func receive(held: [HeldPresenceKey], frame: [Offered], openedTag: Int64, active: Bool) -> Verdict {
        let underOpened = trim(frame.map { HeldPresenceKey(generation: $0.generation, key: $0.key, rootTag: openedTag) })
        // Both are `nil` exactly when nothing is held, as Kotlin's `held.isEmpty()` guard before its `minOf` (`:330-343`).
        guard let heldTag = held.first?.rootTag, let lowest = held.map(\.generation).min() else {
            return .store(rows: underOpened, replaced: false, added: frame.count)
        }
        let sameEra = held.allSatisfy { $0.rootTag == openedTag }
        if !sameEra, active {
            return .store(rows: underOpened, replaced: true, added: frame.count)
        }
        // The same era, or a drain ordered against what is held (below `lowest` is `OLDER`): the held keys' own tag either way.
        var added: [HeldPresenceKey] = []
        for offered in frame {
            if let same = held.first(where: { $0.generation == offered.generation }) {
                // Equality on `PresenceKey` is no constant-time compare: both sides are the sender's own bytes, and nothing
                // secret of ours rides on the answer.
                guard same.key == offered.key else {
                    return .refused(.conflict)
                }
                continue
            }
            guard offered.generation >= lowest else {
                return .refused(.older)
            }
            added.append(HeldPresenceKey(generation: offered.generation, key: offered.key, rootTag: heldTag))
        }
        guard !added.isEmpty else {
            return .noOp
        }
        return .store(rows: trim(held + added), replaced: false, added: added.count)
    }

    /// The ``peerGenerations`` newest (`trim`, `:358`).
    private static func trim(_ rows: [HeldPresenceKey]) -> [HeldPresenceKey] {
        Array(rows.sorted { $0.generation > $1.generation }.prefix(peerGenerations))
    }
}
