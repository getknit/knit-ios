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
