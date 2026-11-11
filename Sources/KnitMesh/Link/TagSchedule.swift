import KnitCrypto
import KnitStore
import KnitWire

/// Where the advertiser's marks persist, per key generation (`TagSchedule.MarkStore`, `TagSchedule.kt:74-81` at knit-next
/// `cad69c77b`): the presence key's own row in `own_presence_keys`, out of backups, written durably and only while the
/// generation is the current key (``PresenceKeySource/readMark`` and ``PresenceKeySource/writeMark``; ADR 2026-11.prsp).
internal protocol TagMarks {
    /// The mark under `generation`, or `nil` for one that has never aired a tag; throws when the store cannot answer
    /// (`read` throws on failure, `TagSchedule.kt:67-68`): a failed read is never "no mark".
    func read(_ generation: Int64) throws(PresenceMarkReadFailure) -> PresenceMark?
    /// Writes `mark` under `generation`; only ``KnitStore/PresenceMarkWrite/durable`` lets the tag air.
    func write(_ mark: PresenceMark, _ generation: Int64) -> PresenceMarkWrite
}

/// Which tag the advertiser airs at a rotation or a bring-up (`TagSchedule`, `TagSchedule.kt` at knit-next `cad69c77b`; ADR
/// 2026-11.prsp, "Rotation"). A slotted tag is a pure function of (key, owner, slot, restart), so airing one (slot, restart)
/// twice from two addresses ties the addresses together. The wall clock alone cannot prevent that: a clock pushed forward
/// then corrected, pulled back, or stepped across a slot edge comes back to slots already aired, and a fifth bring-up in one
/// slot has no restart index left. iOS brings Knit up far more often than Android does (restoration relaunches, Settings'
/// Stop and Start, Bluetooth toggles), so the fifth bring-up is a case the trial counts.
///
/// So the schedule keeps a high-water mark per key generation, persisted through ``TagMarks``, and never returns a
/// (slot, restart) at or below it:
/// - in a slot above the mark, restart 0; in the mark's own slot, the next restart;
/// - when the clock's slot is behind the mark, or the mark's slot has used all ``KnitCrypto/BlindTag/restarts``, a fresh
///   random tag (the `zzzz` prefix and 108 random bits) that no contact resolves, until the clock passes the mark;
/// - a new key generation has no mark, so it starts at the current slot, restart 0.
///
/// **A stale mark.** A mark more than ``KnitCrypto/BlindTag/windowAheadSlots`` slots ahead of the clock (a clock pushed
/// ahead and corrected) answers ``Next/stale``: the tag is still random, and the wiring asks the engine for one pass of our
/// keys, which starts a new generation with no mark (``StaleLatch``).
///
/// **One tag per rotation, announced ahead.** A `TAG_NEXT` names the tag that is then aired: the wiring takes the coming
/// slot's tag with ``reserve(key:wall:marks:using:)`` when it announces and airs exactly those bytes with ``take(_:wall:)``.
///
/// **Durability.** The tag is computed first and the mark written before it is returned, so a tag airs only after its mark
/// is durable. A write that is not ``KnitStore/PresenceMarkWrite/durable`` throws, and nothing is returned, so nothing airs
/// under it (``TagChoice`` airs a random tag instead). Marks are cached per generation, so the store is read once each.
///
/// ``Next/resolvable`` and ``Next/stale`` are counts only, never a dated line: either shows the clock was moved. Pure: the
/// wall clock and the generator passed in, single-threaded on the `Mesh` actor.
internal struct TagSchedule {
    /// The tag to air, and two diagnostics (`TagSchedule.Next`, `:88-94`): `resolvable` is false for a random tag; `stale`
    /// says the mark is past the contact window's lead, so the wiring should ask for a new key generation.
    struct Next: Equatable, CustomStringConvertible {
        /// Advert bytes 1–16.
        let tag: NodeId
        let resolvable: Bool
        let stale: Bool

        /// Never the tag.
        var description: String { "Next(resolvable: \(resolvable), stale: \(stale))" }
    }

    /// Why no slotted tag came back.
    enum Failure: Error, Equatable {
        /// The key and owner made no tag: an owner that is not 16 bytes. Nothing was written.
        case noTag
        /// The mark write answered this, so the tag would rest on a mark that is not durable.
        case notDurable(PresenceMarkWrite)
        /// The mark could not be read, so no pair is known to be unused. Nothing is cached: the next choice reads again.
        case readFailed
    }

    /// The node id a tag is minted under, as a contact's ``ExpectedTagTable`` lists it.
    let owner: [UInt8]
    /// Each generation's mark once read (`nil` inside: the store had none).
    private var marks: [Int64: PresenceMark?] = [:]
    /// Each generation's reservation, with the slot it was reserved for.
    private var reserved: [Int64: (slot: Int64, next: Next)] = [:]

    /// A schedule minting tags under `owner`.
    init(owner: [UInt8]) {
        self.owner = owner
    }

    /// The tag to air now (a bring-up, or a rotation nobody announced) under `key`, its mark written first (`next`, `:103`).
    mutating func next(
        key: OwnPresenceKey, wall: Int64, marks store: some TagMarks, using generator: inout some RandomNumberGenerator
    ) throws(Failure) -> Next {
        try choose(key, wall: wall, slot: BlindTag.slotOf(wallMilliseconds: wall), marks: store, using: &generator)
    }

    /// Reserves the tag for the slot after `wall`'s, to announce in `TAG_NEXT` and air with ``take(_:wall:)`` at the
    /// rotation, its mark written now (`reserve`, `:115-123`). Another call for the same slot and generation answers the same
    /// tag, so a link that comes up inside the lead is told the same tag and no restart is spent; one for a later slot
    /// replaces the reservation, which then never airs.
    mutating func reserve(
        key: OwnPresenceKey, wall: Int64, marks store: some TagMarks, using generator: inout some RandomNumberGenerator
    ) throws(Failure) -> Next {
        let slot = BlindTag.slotOf(wallMilliseconds: wall) + 1
        if let held = reserved[key.generation], held.slot == slot {
            return held.next
        }
        let next = try choose(key, wall: wall, slot: slot, marks: store, using: &generator)
        reserved[key.generation] = (slot, next)
        return next
    }

    /// The tag reserved under `generation`, to air now exactly, if it was reserved for `wall`'s slot; `nil` otherwise. The
    /// reservation goes either way (`take`, `:131-137`): a rotation slots late finds it stale and falls back to
    /// ``next(key:wall:marks:using:)``, and its mark was written, so nothing repeats.
    mutating func take(_ generation: Int64, wall: Int64) -> Next? {
        guard let held = reserved.removeValue(forKey: generation), held.slot == BlindTag.slotOf(wallMilliseconds: wall) else {
            return nil
        }
        return held.next
    }

    /// Drops every reservation unaired, their marks kept (`dropReservations`, `:144-146`): at a key change and when the radio
    /// goes down, so a tag reserved under a key that has since gone is never taken.
    mutating func dropReservations() {
        reserved.removeAll()
    }

    /// A random prefixed tag that no contact resolves, with no mark written (`random`, `:152`): what airs with no key, when
    /// a mark write failed, or when the key is no longer the engine's current one.
    static func randomTag(using generator: inout some RandomNumberGenerator) -> Next {
        Next(tag: AdvertForm.tag(prefixing: generator.next(), generator.next()), resolvable: false, stale: false)
    }

    /// Picks `slot`'s next unused restart under the mark, writes the mark, and answers its tag (`choose`, `:154-174`).
    private mutating func choose(
        _ key: OwnPresenceKey, wall: Int64, slot: Int64, marks store: some TagMarks, using generator: inout some RandomNumberGenerator
    ) throws(Failure) -> Next {
        let generation = key.generation
        let mark = try markOf(generation, store)
        let stale = mark.map { $0.slot > BlindTag.slotOf(wallMilliseconds: wall) + BlindTag.windowAheadSlots } ?? false
        let chosen: PresenceMark?
        if let mark {
            if slot > mark.slot {
                chosen = PresenceMark(slot: slot, restart: 0)
            } else if slot == mark.slot, mark.restart < BlindTag.restarts - 1 {
                chosen = PresenceMark(slot: slot, restart: mark.restart + 1)
            } else {
                chosen = nil
            }
        } else {
            chosen = PresenceMark(slot: slot, restart: 0)
        }
        guard let chosen else {
            let fallback = Self.randomTag(using: &generator)
            return Next(tag: fallback.tag, resolvable: false, stale: stale)
        }
        guard let bytes = BlindTag.tag(key: key.key, owner: owner, slot: chosen.slot, restart: chosen.restart),
            let tag = NodeId(bytes: bytes)
        else {
            throw .noTag
        }
        let written = store.write(chosen, generation)
        guard written == .durable else {
            throw .notDurable(written)
        }
        marks[generation] = chosen
        return Next(tag: tag, resolvable: true, stale: false)
    }

    private mutating func markOf(_ generation: Int64, _ store: some TagMarks) throws(Failure) -> PresenceMark? {
        if let cached = marks[generation] {
            return cached
        }
        let read: PresenceMark?
        do {
            read = try store.read(generation)
        } catch {
            throw .readFailed
        }
        marks[generation] = read
        return read
    }
}
