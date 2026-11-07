import KnitWire
import Testing

@testable import KnitCrypto

/// ``BlindTag``'s owner-bound, slotted construction, ported from `BlindTagTest.kt` at knit-next `cad69c77b` (knit-next ADR
/// 2026-11.xp6d; ADR 2026-11.sv5t). The pinned tags were computed outside knit-next's code with Python's `hmac`, so they
/// check the layout and not only that ``BlindTag/tag(key:owner:slot:restart:)`` and ``BlindTag/Expected`` agree. Kotlin's
/// `tagRefusesABadKeyOwnerOrRestart` becomes ``aTagIsTotal()``: this port mints no tag, so nothing throws. Every draw is
/// seeded and nothing reads a clock.
@Suite struct BlindTagTests {
    private static func key(_ bytes: [UInt8]) throws -> PresenceKey {
        try #require(PresenceKey(bytes: bytes))
    }

    private let keyBytes = (0..<32).map { UInt8($0) }
    private let otherKeyBytes = (0..<32).map { UInt8($0 + 1) }
    private let owner = (0..<16).map { UInt8($0 + 0x20) }
    private let otherOwner = (0..<16).map { UInt8($0 + 0x30) }

    private var key: PresenceKey {
        get throws { try Self.key(keyBytes) }
    }

    private var otherKey: PresenceKey {
        get throws { try Self.key(otherKeyBytes) }
    }

    private func tag(_ key: PresenceKey, _ owner: [UInt8], _ slot: Int64, _ restart: Int) throws -> [UInt8] {
        try #require(BlindTag.tag(key: key, owner: owner, slot: slot, restart: restart))
    }

    @Test func theConstantsAreTheAdrs() {
        #expect(BlindTag.byteCount == NodeId.byteCount)
        #expect(BlindTag.keyByteCount == 32)
        #expect(BlindTag.label == "knit/advert/v1/slot")
        #expect(BlindTag.label.utf8.count == 19)
        #expect(BlindTag.messageByteCount == 44)
        #expect(BlindTag.slotMilliseconds == 15 * 60 * 1000)
        #expect(BlindTag.restarts == 4)
        #expect(BlindTag.windowPastSlots == 32)
        #expect(BlindTag.windowAheadSlots == 2)
    }

    @Test func aFixedKeySlotAndRestartGiveThePinnedBytes() throws {
        #expect(Hex.encode(try tag(try key, owner, 1_987_654, 0)) == "ce7393899a7ccecda1f704358f78550f")
        #expect(Hex.encode(try tag(try key, owner, 1_987_654, 1)) == "ce739f046d5df7d91e32b941aca8f5b6")
        #expect(Hex.encode(try tag(try key, otherOwner, 1_987_654, 0)) == "ce7397818b0f13e6908d532e993729c4")
        // A negative slot is two's complement on the wire, and the last restart index.
        let a5 = try Self.key([UInt8](repeating: 0xA5, count: 32))
        #expect(Hex.encode(try tag(a5, owner, -1, 3)) == "ce739ebc030e3bb566907fe9d843dafc")
    }

    /// A contact re-sending another's key as its own: the two lists share no tag, in the builder as in the one-off.
    @Test func oneKeyUnderTwoOwnersGivesDifferentTags() throws {
        let slots: ClosedRange<Int64> = 100...140
        let mine = Set(BlindTag.Expected(key: try key, owner: owner).tags(slots: slots).map(\.tag))
        let theirs = Set(BlindTag.Expected(key: try key, owner: otherOwner).tags(slots: slots).map(\.tag))
        #expect(mine.count == slots.count * BlindTag.restarts)
        #expect(theirs.count == slots.count * BlindTag.restarts)
        #expect(mine.isDisjoint(with: theirs))
        #expect(try tag(try key, owner, 7, 0) != (try tag(try key, otherOwner, 7, 0)))
    }

    @Test func slotsRestartsAndKeysEachGiveADifferentTag() throws {
        var tags: [[UInt8]] = []
        for slot in Int64(100)...140 {
            for restart in 0..<BlindTag.restarts {
                tags.append(try tag(try key, owner, slot, restart))
                tags.append(try tag(try otherKey, owner, slot, restart))
            }
        }
        #expect(Set(tags).count == tags.count)
    }

    @Test func aTagIsDeterministic() throws {
        let copy = try Self.key(keyBytes)
        #expect(try tag(try key, owner, 42, 2) == (try tag(copy, owner, 42, 2)))
    }

    @Test func everyTagCarriesThePrefixStartsZzzzAndRoundTrips() throws {
        var random = SeededGenerator(seed: 4)
        var tags: [[UInt8]] = []
        for _ in 0..<256 {
            let fresh = try Self.key((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
            let slot = Int64.random(in: .min ... .max, using: &random)
            tags.append(try tag(fresh, owner, slot, Int.random(in: 0..<BlindTag.restarts, using: &random)))
        }
        tags += [try tag(try key, owner, .min, 0), try tag(try key, owner, .max, 3), try tag(try key, owner, 0, 0)]
        for tag in tags {
            #expect(tag.count == BlindTag.byteCount)
            #expect(AdvertForm.hasTagPrefix(tag))
            let id = try #require(NodeId(bytes: tag))
            #expect(id.string.hasPrefix("zzzz"))
            #expect(NodeId(id.string)?.bytes == tag, "\(id) is canonical and round-trips")
        }
    }

    /// The prefix this derivation writes is the one phase 1a's ``AdvertForm/hasTagPrefix(_:)`` reads, on its 20 fixed bits
    /// and nothing else.
    @Test func hasPrefixReadsOnlyTheTwentyFixedBits() throws {
        let tag = try tag(try key, owner, 7, 0)
        for bit in 0..<(BlindTag.byteCount * 8) {
            var flipped = tag
            flipped[bit / 8] ^= 0x80 >> UInt8(bit % 8)
            #expect(AdvertForm.hasTagPrefix(flipped) == (bit >= 20), "bit \(bit)")
        }
        for bad in [[], Array(tag.prefix(15)), tag + [0], [UInt8](repeating: 0, count: BlindTag.byteCount)] {
            #expect(!AdvertForm.hasTagPrefix(bad))
        }
    }

    /// Kotlin's `tag` throws on a bad key, owner or restart; this port's answers `nil`, and a bad key cannot be a
    /// ``PresenceKey``. The key with one trailing zero is the same HMAC key as the key itself (RFC 2104 zero-pads), so only
    /// the length guard can refuse it.
    @Test func aTagIsTotal() throws {
        let presence = try key
        for bad in [[], [UInt8](repeating: 0, count: 31), [UInt8](repeating: 0, count: 33), keyBytes + [0]] {
            #expect(PresenceKey(bytes: bad) == nil, "key \(bad.count)")
        }
        for bad in [[], Array(owner.prefix(15)), owner + [0]] {
            #expect(BlindTag.tag(key: presence, owner: bad, slot: 1, restart: 0) == nil, "owner \(bad.count)")
        }
        for restart in [-1, BlindTag.restarts, .min, .max] {
            #expect(BlindTag.tag(key: presence, owner: owner, slot: 1, restart: restart) == nil, "restart \(restart)")
        }
    }

    @Test func expectedIsTotal() throws {
        let presence = try key
        // The owner with one trailing zero is the case a truncating read would let through.
        for bad in [[], Array(owner.prefix(15)), owner + [0]] {
            let expected = BlindTag.Expected(key: presence, owner: bad)
            #expect(expected.tags(slots: Int64(0)...3).isEmpty)
            #expect(expected.tag(slot: 0, restart: 0) == nil)
        }
        let good = BlindTag.Expected(key: presence, owner: owner)
        for restart in [-1, BlindTag.restarts, .min, .max] {
            #expect(good.tag(slot: 1, restart: restart) == nil)
        }
        #expect(good.tags(slots: Int64(0)..<0).isEmpty)
    }

    @Test func expectedAgreesWithTagSlotMajor() throws {
        let expected = BlindTag.Expected(key: try key, owner: owner)
        let listed = expected.tags(slots: Int64(-3)...5)
        #expect(listed.count == 9 * BlindTag.restarts)
        var index = 0
        for slot in Int64(-3)...5 {
            for restart in 0..<BlindTag.restarts {
                let entry = listed[index]
                index += 1
                #expect(entry.slot == slot && entry.restart == restart)
                #expect(entry.tag == (try tag(try key, owner, slot, restart)))
                #expect(entry.tag == expected.tag(slot: slot, restart: restart))
            }
        }
        #expect(expected.tag(slot: 1_987_654, restart: 0).map(Hex.encode) == "ce7393899a7ccecda1f704358f78550f")
    }

    /// One builder's tags, asked for in interleaved order, equal fresh one-off computations: no MAC state crosses two tags
    /// (the design pass's HMAC finding).
    @Test func interleavedListingsOfOneBuilderStayCorrect() throws {
        let expected = BlindTag.Expected(key: try otherKey, owner: owner)
        let first = Int64(0)...9
        let second = Int64(100)...109
        for (low, high) in zip(first, second) {
            for restart in 0..<BlindTag.restarts {
                let early = try #require(expected.tag(slot: low, restart: restart))
                let late = try #require(expected.tag(slot: high, restart: BlindTag.restarts - 1 - restart))
                #expect(early == (try tag(try otherKey, owner, low, restart)))
                #expect(late == (try tag(try otherKey, owner, high, BlindTag.restarts - 1 - restart)))
            }
        }
        let other = try otherKey
        let fresh = first.flatMap { slot in
            (0..<BlindTag.restarts).compactMap { BlindTag.tag(key: other, owner: owner, slot: slot, restart: $0) }
        }
        #expect(expected.tags(slots: first).map(\.tag) == fresh)
    }

    @Test func slotOfFloorsAtBoundariesAndBelowZero() {
        let slot = BlindTag.slotMilliseconds
        #expect(BlindTag.slotOf(wallMilliseconds: 0) == 0)
        #expect(BlindTag.slotOf(wallMilliseconds: slot - 1) == 0)
        #expect(BlindTag.slotOf(wallMilliseconds: slot) == 1)
        #expect(BlindTag.slotOf(wallMilliseconds: 2 * slot - 1) == 1)
        #expect(BlindTag.slotOf(wallMilliseconds: -1) == -1)
        #expect(BlindTag.slotOf(wallMilliseconds: -slot) == -1)
        #expect(BlindTag.slotOf(wallMilliseconds: -slot - 1) == -2)
        // 2026-11-02T00:00:00Z
        #expect(BlindTag.slotOf(wallMilliseconds: 1_793_577_600_000) == 1_793_577_600_000 / slot)
        // Math.floorDiv(Long.MIN_VALUE, 900000): the quotient toward zero, one lower.
        #expect(BlindTag.slotOf(wallMilliseconds: .min) == Int64.min / slot - 1)
        #expect(BlindTag.slotOf(wallMilliseconds: .max) == Int64.max / slot)
    }

    @Test func theWindowIsTheLastEightHoursAndTheNextHalfHour() throws {
        let now: Int64 = 1_793_577_600_000 + 123_456
        let window = BlindTag.window(wallMilliseconds: now)
        let current = BlindTag.slotOf(wallMilliseconds: now)
        #expect(window.lowerBound == current - 32)
        #expect(window.upperBound == current + 2)
        #expect(window.count == 35)
        #expect(BlindTag.Expected(key: try key, owner: owner).tags(slots: window).count == 140)
        // Neither end overflows at the clock's limits.
        #expect(BlindTag.window(wallMilliseconds: .min).count == 35)
        #expect(BlindTag.window(wallMilliseconds: .max).count == 35)
    }

    /// Nothing holding a key prints a byte of it, nor of the owner or a tag: not a key, a builder or a slotted tag.
    @Test func nothingPrintsAKeyAnOwnerOrATag() throws {
        let marker = try Self.key([UInt8](repeating: 0xAB, count: 32))
        let markedOwner = [UInt8](repeating: 0xCD, count: 16)
        let expected = BlindTag.Expected(key: marker, owner: markedOwner)
        let slotted = try #require(expected.tags(slots: Int64(5)...5).first)
        var dumped = ""
        dump(marker, to: &dumped)
        dump(expected, to: &dumped)
        dump(slotted, to: &dumped)
        let printed = [
            String(describing: marker), String(reflecting: marker), String(describing: expected), String(reflecting: expected),
            String(describing: slotted), String(reflecting: slotted), dumped,
        ]
        let forbidden = ["171", "205", "abab", "cdcd", Hex.encode(slotted.tag), "\(slotted.tag[3])"]
        for text in printed {
            for needle in forbidden {
                #expect(!text.lowercased().contains(needle), "\(text) shows \(needle)")
            }
        }
        #expect(String(describing: slotted) == "Slotted(slot: 5, restart: 0)")
        #expect(String(describing: marker) == "PresenceKey(32 bytes)")
    }
}
