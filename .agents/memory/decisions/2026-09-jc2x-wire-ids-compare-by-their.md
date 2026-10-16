---
id: "2026-09.jc2x"
slug: wire-ids-compare-by-their
title: "wire ids compare by their bytes, never by Swift string equality"
date: 2026-09-25
topics: [wire, mesh, security]
---

# ADR 2026-09.jc2x — wire ids compare by their bytes, never by Swift string equality

Status: Accepted (2026-09-25)

**Context:** Swift's `String` equality, and its hashing, is canonical equivalence: `"K"` equals the Kelvin sign
`"\u{212A}"`, and `"é"` equals `"e"` plus a combining acute. Kotlin compares UTF-16 code units. Our CBOR
decoder accepts only valid UTF-8, which maps one-to-one onto those units, so two ids are the same frame on
Android exactly when their bytes match. A seen set keyed by `String` would let a crafted frame, with an id
Android treats as new, pass as a duplicate of a real frame's id. If the crafted copy reached a Swift node
first, the real frame would be dropped there unseen: not delivered, not relayed, not carried. Keyed the same
way, the message store would take the real DM for one already delivered.

**Decision:** `ExactKey`, the UTF-8 bytes of a string, keys every set and map built from frame ids or frame
keys: the router's seen set and pending relays, the link crossings memo, custody rows and tombstones,
message rows, parked frames and owed ticks. Custody eviction compares ids byte by byte, as SQLite's BINARY
collation does. Node ids need no wrapper: `NodeId(_:)` accepts only canonical lowercase base32, which has no
canonically equivalent spellings.

**Consequences / limits:** every new collection keyed by a frame id, or by a sender string before it has been
parsed as a `NodeId`, must key on `ExactKey`, and nothing but review catches one that does not. The SQL
store (P5) must keep SQLite's default BINARY collation on id columns. `ExactKeyTests`, `RouterTests`'
`aCraftedIdThatSwiftCallsEqualIsStillNew`, `CustodyStoreTests`' `idsThatSwiftCallsEqualAreTwoFrames`,
`RepositoryTests`' `messageIdsCompareByTheirBytes` and `CustodyRulesTests`'
`evictionOrdersIdsByTheirBytesNotByCanonicalEquivalence` guard it.

**Amended 2026-10-16, in phase P6a1 of ADR 2026-10.5sk9: an id reads back with every byte.** Comparing ids by their
bytes needs the bytes to come back from SQL whole. `Row.text` (`StoredText.swift`) decoded a stored string with
`String(bytes:encoding: .utf8)`, which drops a leading U+FEFF as a byte order mark, so an id stored as `EF BB BF` and X
read back as X. Custody listed such a frame in our digest as X, so every neighbour sent it again at each exchange, and
its quota evicted by the read-back id and missed the row; the group ratchet's cap ordered and deleted a U+FEFF group's
keys under another group's id. A crafted id, U+FEFF and then a real frame's id, could also stand in for that frame here:
our digest named the real frame, so no neighbour offered it to us, and the quota's delete could take the real frame in
the crafted one's place, the threat this ADR guards against. `Row.text` now decodes with
`String(validating:as: UTF8.self)`, as KnitWire's CBOR decoder does, and still throws on bytes that are not UTF-8, and
the cap deletes by the column bytes it read. `CustodyStoreByteKeyTests.anIdWithANulIsNotItsOwnPrefix` and
`GroupRatchetStoreTests.bothStoresEvictTheSameKeysAtTheCap` hold it over both store kinds.

Android does not keep the mark, so the Context's premise, that two ids are the same frame on Android exactly when their
bytes match, fails for an id that starts with U+FEFF or U+FFFE. knit-next's database driver binds every string as
UTF-16 (`sqlite3_bind_text16`), and SQLite drops a leading U+FEFF there and byte-swaps the rest after a leading U+FFFE.
On Android an id that starts with U+FEFF is one custody row with its unmarked twin, and its digest lists it unmarked; a
crafted twin that reaches an Android node before the real frame takes the real frame's row there (`ForwardSync.kt:75`).
This port keeps every byte on purpose, since dropping the mark would port the collision. Until knit-next binds ids
whole, or both platforms refuse such ids (a paired change), an iPhone sends such a frame again to each Android
neighbour at every exchange, and a soak that compares custody sets those ids aside (knit-next #178).
