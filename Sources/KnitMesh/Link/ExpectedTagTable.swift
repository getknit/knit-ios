import KnitCrypto
import KnitWire

/// Every direct contact's expected tags over the contact window, so ``AdvertAliases`` resolves a heard tag with one hash
/// lookup (knit-next ADR 2026-11.xp6d, "The tag" and "Clocks"; `ExpectedTagTable.kt` at `cad69c77b`; ADR 2026-11.sv5t). A
/// tag is a function of (key, owner, slot, restart) (``BlindTag``), so the table lists each contact key's tags, minted
/// under that contact's own id, for every slot of ``BlindTag/window(wallMilliseconds:)`` and all four restarts, keyed by
/// the tag. An unknown tag, a flood of them included, costs a miss and nothing else.
///
/// - **Incremental.** ``slide(wall:)`` at a slot change lists only the slots that entered the window and drops those that
///   left it; ``setKeys(_:now:wall:)`` rebuilds only the contacts whose keys changed.
/// - **Every key the feed lists** (newest first, up to the store's three): a tag carries no key generation. A tag heard
///   under one caps every older one at `previousKeyMaxMilliseconds` from then (``lookup(_:now:)``), and a lapsed key stays
///   unlisted while the feed still names it. A **replaced newest key** stays listed until a tag under its successor is
///   heard or its cap passes (``lapse(now:)``). A key the feed drops otherwise is unlisted at once.
/// - **One entry per form.** A tag binds its owner's id, so a key two contacts list gives each contact tags of its own.
/// - **Clocks.** Slots read the wall clock; the previous key's cap reads the monotonic clock.
///
/// Pure; a build is up to 140 HMACs per key, on the `Mesh` actor.
internal final class ExpectedTagTable {
    /// A heard tag's owner, and whether it was minted under that contact's newest key.
    struct Hit: Hashable {
        let nodeId: NodeId
        let current: Bool
    }

    /// A direct contact's presence keys, newest first (`AdvertAliases.ContactKey`, `AdvertAliases.kt:139-159`): the store
    /// holds up to three (a previous, a current and a next key that went ahead), and every one is listed, since a tag
    /// carries no generation. A key the feed drops is unlisted at once, except the newest when a new newest replaces it: it
    /// lingers until a tag under its successor is heard or the cap passes. ``previousUntilMilliseconds`` caps every older
    /// key on the monotonic clock; ``capsOlder`` caps them at the cap from now when it is `nil` (the two-key form's rule);
    /// the store's list leaves them uncapped, its own bound of three being theirs. Its printing shows no key.
    struct ContactKey: CustomStringConvertible {
        /// The keys, newest first, never empty.
        let keys: [PresenceKey]
        /// When every older key stops being listed, on the monotonic clock.
        let previousUntilMilliseconds: Int64?
        /// Whether older keys are capped from the listing when ``previousUntilMilliseconds`` is `nil`.
        let capsOlder: Bool

        /// The store's list, newest first, its older keys uncapped; `nil` when empty (Kotlin's `require`).
        init?(keys: [PresenceKey]) {
            guard !keys.isEmpty else {
                return nil
            }
            self.keys = keys
            previousUntilMilliseconds = nil
            capsOlder = false
        }

        /// The current key alone.
        init(current: PresenceKey) {
            keys = [current]
            previousUntilMilliseconds = nil
            capsOlder = false
        }

        /// The current key with the one it replaced, capped at `previousUntilMilliseconds`, or a key generation from the
        /// listing when that is `nil`.
        init(current: PresenceKey, previous: PresenceKey, previousUntilMilliseconds: Int64?) {
            keys = [current, previous]
            self.previousUntilMilliseconds = previousUntilMilliseconds
            capsOlder = true
        }

        /// The count only.
        var description: String { "ContactKey(\(keys.count) keys)" }
    }

    private final class Generation {
        let key: PresenceKey
        let expected: BlindTag.Expected
        var untilMilliseconds: Int64?
        var bySlot: [Int64: [NodeId]] = [:]
        /// Kept past the feed: the newest key a newer one replaced, listed until its cap or a tag under a newer key.
        var lingering = false

        init(owner: NodeId, key: PresenceKey) {
            self.key = key
            expected = BlindTag.Expected(key: key, owner: owner)
        }
    }

    private final class Contact {
        let id: NodeId
        /// Listed generations, newest first; a lingering replaced key after the feed's.
        var generations: [Generation]
        /// Keys the feed still lists that a tag under a newer key retired: never listed again while the feed has them.
        var retired: [PresenceKey] = []

        init(id: NodeId, generations: [Generation]) {
            self.id = id
            self.generations = generations
        }
    }

    private struct Entry {
        let contact: Contact
        let generation: Generation
    }

    private let previousKeyMax: Int64
    private var contacts: [NodeId: Contact] = [:]
    private var table: [NodeId: Entry] = [:]
    private var window: ClosedRange<Int64>?
    private var nextLapse = Int64.max

    /// Expected tags listed now.
    var count: Int { table.count }
    /// Contacts listed now.
    var contactCount: Int { contacts.count }
    /// Key generations listed whole over the window, since the start.
    private(set) var builds = 0
    /// Slots listed for a key as the window moved, since the start.
    private(set) var slotSteps = 0
    /// Tags computed since the start: one HMAC each.
    private(set) var tagsComputed = 0

    /// A table capping an older key at `previousKeyMaxMilliseconds` past a hit under a newer one.
    init(previousKeyMaxMilliseconds: Int64) {
        previousKeyMax = previousKeyMaxMilliseconds
    }

    /// The direct contacts' keys, replacing the whole set (``ContactKey``'s rules). Only a key new to its
    /// contact is listed; a key the contact already listed keeps its tags whatever its place in the list.
    func setKeys(_ keys: [NodeId: ContactKey], now: Int64, wall: Int64) {
        slide(wall: wall)
        for id in contacts.keys where keys[id] == nil {
            if let contact = contacts.removeValue(forKey: id) {
                unlist(contact)
            }
        }
        for (id, key) in keys {
            update(id, key, now: now)
        }
        nextLapse = earliestLapse()
    }

    /// The owner of `tag`, or `nil` when it is unlisted. A hit at `now` under one of a contact's keys caps every older key
    /// it still lists, and retires at once one the feed replaced.
    func lookup(_ tag: NodeId, now: Int64) -> Hit? {
        guard let entry = table[tag] else {
            return nil
        }
        let contact = entry.contact
        let heard = contact.generations.firstIndex { $0 === entry.generation }
        if let heard {
            retireOlder(contact, index: heard, now: now)
        }
        return Hit(nodeId: contact.id, current: heard == 0)
    }

    /// Moves the window to `wall`'s: lists the slots that entered it and drops those that left it.
    func slide(wall: Int64) {
        let next = BlindTag.window(wallMilliseconds: wall)
        let held = window
        guard held != next else {
            return
        }
        window = next
        for contact in contacts.values {
            for generation in contact.generations {
                for slot in generation.bySlot.keys where !next.contains(slot) {
                    dropSlot(generation, slot)
                }
                for slot in next where !(held?.contains(slot) ?? false) {
                    slotSteps += 1
                    listSlot(contact, generation, slot)
                }
            }
        }
    }

    /// Drops every older key whose cap has passed at `now`. Cheap when none is due.
    func lapse(now: Int64) {
        guard now >= nextLapse else {
            return
        }
        for contact in contacts.values {
            let due = contact.generations.filter { ($0.untilMilliseconds ?? .max) <= now }
            guard !due.isEmpty else {
                continue
            }
            for generation in due {
                unlistGeneration(generation)
                // A key the feed still names stays unlisted once it lapsed.
                if !generation.lingering {
                    contact.retired.append(generation.key)
                }
            }
            contact.generations.removeAll { ($0.untilMilliseconds ?? .max) <= now }
        }
        nextLapse = earliestLapse()
    }

    private func earliestLapse() -> Int64 {
        contacts.values.flatMap(\.generations).compactMap(\.untilMilliseconds).min() ?? .max
    }

    /// A tag under `contact`'s generation at `index` was heard at `now`. A lingering older key goes at once: the feed named
    /// the successor. A key the feed still lists only lapses, `previousKeyMax` after the first such hit: another contact of
    /// the owner holds the owner's next key and could air one tag under it.
    private func retireOlder(_ contact: Contact, index: Int, now: Int64) {
        let older = contact.generations.dropFirst(index + 1)
        guard !older.isEmpty else {
            return
        }
        for generation in older where generation.lingering {
            unlistGeneration(generation)
        }
        contact.generations.removeAll { generation in older.contains { $0 === generation } && generation.lingering }
        let until = now + previousKeyMax
        for generation in older where !generation.lingering {
            generation.untilMilliseconds = min(generation.untilMilliseconds ?? .max, until)
        }
        nextLapse = min(nextLapse, until)
    }

    private func update(_ id: NodeId, _ key: ContactKey, now: Int64) {
        let held = contacts[id]
        // A fork can store one key under two generations: both would list the same forms, so the unlisting of one would
        // leave the key's tags dark. The newest stands for it.
        var keys: [PresenceKey] = []
        for candidate in key.keys where !keys.contains(candidate) {
            keys.append(candidate)
        }
        held?.retired.removeAll { !keys.contains($0) }
        let wanted = keys.filter { !(held?.retired.contains($0) ?? false) }
        let listed = wanted.enumerated().map { index, presenceKey in
            let generation = held?.generations.first { $0.key == presenceKey } ?? Generation(owner: id, key: presenceKey)
            generation.lingering = false
            // A store-listed older key keeps the cap a hit under a newer one set; the two-key form's is reset.
            let cap = generation.untilMilliseconds
            generation.untilMilliseconds =
                index == 0 ? nil : key.previousUntilMilliseconds ?? (key.capsOlder ? now + previousKeyMax : cap)
            return generation
        }
        let kept = listed + lingering(held, key, now: now).filter { generation in !listed.contains { $0 === generation } }
        let contact = held ?? Contact(id: id, generations: kept)
        contacts[id] = contact
        for generation in held?.generations ?? [] where !kept.contains(where: { $0 === generation }) {
            unlistGeneration(generation)
        }
        contact.generations = kept
        for generation in kept where generation.bySlot.isEmpty {
            builds += 1
            for slot in window.map(Array.init) ?? [] {
                listSlot(contact, generation, slot)
            }
        }
    }

    /// The held generations that outlive this feed: the held newest when the feed replaced it with a new newest (it
    /// lingers, capped from now, until a tag under its successor is heard), and one already lingering, within its cap.
    private func lingering(_ held: Contact?, _ key: ContactKey, now: Int64) -> [Generation] {
        guard let generations = held?.generations else {
            return []
        }
        let absent = { (generation: Generation) in !key.keys.contains(generation.key) }
        var replaced: Generation?
        if let newest = generations.first, !newest.lingering, absent(newest) {
            newest.lingering = true
            newest.untilMilliseconds = now + previousKeyMax
            replaced = newest
        }
        let still = generations.filter { generation in
            generation !== replaced && generation.lingering && absent(generation) && (generation.untilMilliseconds ?? .max) > now
        }
        return (replaced.map { [$0] } ?? []) + still
    }

    private func listSlot(_ contact: Contact, _ generation: Generation, _ slot: Int64) {
        let forms = generation.expected.tags(slots: slot...slot).compactMap { NodeId(bytes: $0.tag) }
        tagsComputed += forms.count
        guard !forms.isEmpty else {
            return
        }
        generation.bySlot[slot] = forms
        let entry = Entry(contact: contact, generation: generation)
        for form in forms {
            table[form] = entry
        }
    }

    private func dropSlot(_ generation: Generation, _ slot: Int64) {
        for form in generation.bySlot.removeValue(forKey: slot) ?? [] where table[form]?.generation === generation {
            // A form a later listing won (the 2⁻¹⁰⁸ accident) stays that listing's.
            table[form] = nil
        }
    }

    private func unlistGeneration(_ generation: Generation) {
        for slot in Array(generation.bySlot.keys) {
            dropSlot(generation, slot)
        }
    }

    private func unlist(_ contact: Contact) {
        for generation in contact.generations {
            unlistGeneration(generation)
        }
    }
}
