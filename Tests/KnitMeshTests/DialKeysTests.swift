import KnitWire
import Testing

@testable import KnitMesh

/// ``DialKeys`` and ``FormKeys`` (knit-next ADR 2026-11.xp6d's reader, obligations 8 and 9; ADR 2026-11.sv5t): what a dial
/// is booked under, how a backoff reads back to per-peer keys, and the handles' bound. Kotlin tests these through
/// `BlindReaderTest`; these are the rules alone.
@Suite struct DialKeysTests {
    private let bob = BlindFixture.id("bob")
    private let tag = BlindFixture.form("zzzzq")
    private let here = RadioAddress("AA")
    private let handle = FormHandle(number: 7)

    @Test func aClearAdvertIsBookedOnItsIdAndABlindedOneOnItsHandleAndAddress() throws {
        let clear = DialKeys.dialKey(form: .clear(bob), key: .node(bob), address: here) { _ in handle }
        #expect(clear == .peer(.node(bob)), "a clear peer's backoff behaves as it always did")
        let blinded = try #require(DialKeys.dialKey(form: BlindFixture.blinded(tag), key: .node(bob), address: here) { _ in handle })
        #expect(blinded == .tag(handle, here), "a tag a key resolves is still booked on the tag and the address")
        #expect(String(describing: blinded) == "~zzzz…7@AA")
        #expect(!String(describing: blinded).contains(tag.string))
        #expect(DialKeys.dialKey(form: BlindFixture.blinded(tag), key: .form(handle), address: here) { _ in nil } == nil, "a handle gone")
    }

    @Test func onlyAFailedDialToAnUnresolvedFormAdvancesItsAddressAndHandleStreaks() {
        let dial = DialKey.tag(handle, here)
        #expect(DialKeys.addressKey(dial, unresolved: true) == .address(here))
        #expect(DialKeys.handleKey(dial, unresolved: true) == .peer(.form(handle)))
        #expect(DialKeys.addressKey(dial, unresolved: false) == nil, "never a resolved peer's")
        #expect(DialKeys.handleKey(dial, unresolved: false) == nil)
        #expect(DialKeys.addressKey(.tag(handle, nil), unresolved: true) == nil, "no address, no address streak")
        #expect(DialKeys.addressKey(.peer(.node(bob)), unresolved: true) == nil, "never a clear dial's")
    }

    @Test func aBackoffReadsBackToEveryPerPeerKeyItHoldsOff() {
        let unresolved = SightingKey.form(handle)
        let other = SightingKey.form(FormHandle(number: 8))
        let dialKeys: [SightingKey: DialKey] = [unresolved: .tag(handle, here), other: .tag(FormHandle(number: 8), RadioAddress("BB"))]
        let read = { (active: Set<DialKey>) in
            DialKeys.backedOff(sighted: [unresolved, other, .node(bob)], active: active) { dialKeys[$0] ?? .peer($0) }
        }
        #expect(read([.tag(handle, here)]) == [unresolved], "the dial key")
        #expect(read([.address(here)]) == [unresolved], "the address streak, while it resolves to nobody")
        #expect(read([.peer(unresolved)]) == [unresolved], "the handle streak")
        #expect(read([.peer(.node(bob))]) == [.node(bob)], "an id with or without a snapshot")
        #expect(read([.peer(.node(BlindFixture.id("gone")))]) == [.node(BlindFixture.id("gone"))])
        #expect(read([]).isEmpty)
    }

    /// Every key prints as the harness reads it and no tag: an id, a handle with its address, `?` for none, and an address
    /// streak (`DialKeys.kt`'s strings, here one case each).
    @Test func everyDialKeyPrintsItsIdOrHandleAndNeverATag() {
        #expect(String(describing: DialKey.peer(.node(bob))) == bob.string, "a clear dial's key is the id the harness reads")
        #expect(String(describing: DialKey.peer(.form(handle))) == "~zzzz…7")
        #expect(String(describing: DialKey.tag(handle, nil)) == "~zzzz…7@?")
        #expect(String(describing: DialKey.address(here)) == "@AA")
    }

    /// A sighting whose handle has gone has no dial key, so no backoff on its address holds it off; it is dialable again
    /// once heard again (`backedOff`, `:92-104`).
    @Test func aSightingWithoutADialKeyIsNeverReadAsBackingOff() {
        let unresolved = SightingKey.form(handle)
        let gone = SightingKey.form(FormHandle(number: 8))
        let read = DialKeys.backedOff(sighted: [gone, unresolved], active: [.address(here)]) { key in
            key == unresolved ? .tag(handle, here) : nil
        }
        #expect(read == [unresolved])
    }

    @Test func aHeldLinkHoldsOffOnlyItsOwnProvenTagDial() {
        let dial = DialKey.tag(handle, here)
        #expect(DialKeys.heldDial(dial, proven: true) == dial)
        #expect(DialKeys.heldDial(dial, proven: false) == nil, "an unproven link holds off nothing")
        #expect(DialKeys.heldDial(.peer(.node(bob)), proven: true) == nil, "a clear dial's id is the live link's to hold off")
        #expect(DialKeys.heldDial(nil, proven: true) == nil, "a link the peer dialed")
        #expect(DialKeys.dialHeld(blinded: true, held: [dial]) { dial })
        #expect(!DialKeys.dialHeld(blinded: true, held: [dial]) { .tag(handle, RadioAddress("BB")) }, "another address still dials")
        #expect(!DialKeys.dialHeld(blinded: false, held: [dial]) { dial })
    }

    @Test func aDialThatBeganHeldCrossedNothing() {
        let linked: Set<SightingKey> = [.node(bob)]
        let crossing = DialRecord(kind: .ordinary, peerKey: .node(bob), linkedAtStart: false)
        let refused = DialRecord(kind: .headStart, peerKey: .node(bob), linkedAtStart: true)
        #expect(DialKeys.linkedNow(crossing, dialKey: .tag(handle, here), linked: linked))
        #expect(!DialKeys.linkedNow(refused, dialKey: .tag(handle, here), linked: linked), "an ordinary refusal: it backs off")
        #expect(DialKeys.linkedNow(nil, dialKey: .peer(.node(bob)), linked: linked))
        #expect(!DialKeys.linkedNow(nil, dialKey: .tag(handle, here), linked: linked), "an unresolved form's handle is never linked")
    }

    @Test func aFormKeepsOneHandleAndAFloodKeepsAtMostTheCap() {
        var keys = FormKeys()
        let first = keys.handle(for: tag) { _ in false }
        #expect(first.evicted == nil)
        #expect(keys.handle(for: tag) { _ in false }.handle == first.handle, "the same handle while it is remembered")
        #expect(String(describing: first.handle) == "~zzzz…0")
        var evicted: [FormHandle] = []
        for index in 0..<3000 {
            let low = UInt8(truncatingIfNeeded: index)
            let high = UInt8(truncatingIfNeeded: index >> 8)
            let flood = required(NodeId(bytes: [0xCE, 0x73, 0x90, high, low] + [UInt8](repeating: 0, count: 11)))
            if let gone = keys.handle(for: flood, pinned: { _ in false }).evicted {
                evicted.append(gone)
            }
        }
        #expect(keys.count == FormKeys.defaultCap)
        #expect(keys.evicted == evicted.count)
        #expect(evicted.first == first.handle, "least recently used out first")
        #expect(keys.existing(tag) == nil)
        keys.clear()
        #expect(keys.handle(for: tag) { _ in false }.handle.number == 3001, "numbering carries on across a clear")
    }

    /// The reviewer's second finding on phase 2a: a handle a live dial key names is never the one let go, so a flood
    /// cannot take the held-dial key of a held link and have the next sighting of its tag dial the held phone again.
    @Test func aPinnedHandleOutlivesAFlood() {
        var keys = FormKeys()
        let held = keys.handle(for: tag) { _ in false }.handle
        for index in 0..<2000 {
            let flood = required(
                NodeId(
                    bytes: [0xCE, 0x73, 0x90, UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)]
                        + [UInt8](repeating: 1, count: 11)))
            #expect(keys.handle(for: flood) { $0 == held }.evicted != held)
        }
        #expect(keys.existing(tag) == held)
        #expect(keys.count == FormKeys.defaultCap)
    }
}
