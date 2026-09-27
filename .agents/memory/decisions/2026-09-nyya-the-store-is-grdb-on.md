---
id: "2026-09.nyya"
slug: the-store-is-grdb-on
title: "the store is GRDB on SQLite under Data Protection, and SQLCipher waits"
date: 2026-09-26
topics: [store, storage, interop]
---

# ADR 2026-09.nyya — the store is GRDB on SQLite under Data Protection, and SQLCipher waits

Status: Accepted (2026-09-26)

**Context:** the app needs custody, peers, messages, accepted conversations and its own profile to survive a
relaunch. The mesh engine calls its stores synchronously from one actor (ADR 2026-09.gq84), and custody must
bound its carried set exactly as Android does (ADR 2026-09.p6nb). Spike (a) showed GRDB 7.11.1 building and
passing on Linux against the system SQLite, and cross-building for iOS. Two traps turned up on the way:

- **GRDB cuts a string at its first NUL.** It binds a Swift `String` with `sqlite3_bind_text(…, -1, …)` and
  reads one back through a C string. A frame id `"a\0b"` would be stored as `"a"`, the same row as a real
  frame `"a"`. That is the collision ADR 2026-09.jc2x keys ids by their bytes to prevent, reached a different
  way.
- **`CustodyRules` compared in Swift's terms.** It removed evicted ids through a `Set<String>` and matched
  group buckets with `==`, both canonical equivalence. An evicted `"idK"` also took a live `"id\u{212A}"` out
  of the count, so the overall trim kept a frame Android evicts. A sender could also pick a group id
  canonically equal to someone else's group and share that group's quota on iOS only. Both stores apply
  these rules.

**Decision:**

- **`KnitStoreSQL`** implements every `KnitStore` protocol on GRDB: `forward_store`, `peers`, `messages`,
  `accepted_conversations` and a one-row `own_profile`, all in one `knit.sqlite` in a directory of its own,
  opened as a WAL pool.
- **Every string is stored as UTF-8 bytes in a `BLOB` column, and every table is `STRICT`.** `STRICT`
  refuses a `TEXT` value in a `BLOB` column, so a store that binds a `String` by mistake fails loudly instead
  of keying a row by the wrong bytes. SQLite orders BLOBs with `memcmp`, which is how BINARY orders text, so
  `ORDER BY sentAt, id` means what it means on Android. The cost is a database that the `sqlite3` shell
  shows as blobs.
- **The custody store runs `CustodyRules` in Swift over the live rows**, the same code the memory store
  runs, rather than a second copy of the quotas in SQL. It loads the live entries on every insert, which is
  at most 1000 small rows. `CustodyRules` now keys evicted ids by `ExactKey` and matches senders and groups by
  their bytes.
- **The schema is an append-only list of migrations, written as literal SQL.** GRDB's table builder is not
  used, so a GRDB upgrade cannot change what a fresh install gets. v1 is frozen now, before any release: a
  later change is a new migration with a test that migrates rows written under the old schema.
- **Data Protection:** on iOS the directory and the file are `completeUntilFirstUserAuthentication`, because
  the mesh reads and writes while the phone is locked. On every Apple platform the directory is excluded
  from backups: nothing encrypts the file beyond Data Protection, and the identity its messages belong to is a
  Keychain item that never leaves the phone.
- **Errors are reported, not thrown.** The store protocols are synchronous and cannot throw, so a store that
  meets a database error answers as if nothing were there (`store` answers `false`, a read answers empty)
  and hands the error to the `failures` closure the app gives `KnitDatabase`. The mesh keeps running, and the
  app can say that storage is failing.

What stayed out, and why:

- **SQLCipher.** knit-next encrypts its database with it. Here its key would sit in the Keychain under the
  same after-first-unlock class the mesh needs, so it would guard the file no better than Data Protection
  already does. It returns when there is a reason beyond that.
- **Tombstones.** knit-next keeps purged ids in memory (`ForwardSync.acked`, a `SeenSet`), and so does
  `CustodySync`. A relaunch forgets them, on both platforms alike.
- **`message_receipts` and `met_peers`.** No MVP screen reads them. Each arrives as a migration with the
  feature that needs it.

**Amended 2026-09-27, schema v2:** `peer_profiles` keeps the signed profile each pin came from, one row per
pinned peer, as knit-next's database v16 does (its ADR 2026-09.g64k). It is a table of its own, as there: the
peer rows stay plain, and the proof can go when its pin does. Nothing in this port deletes a pin yet, so nothing
deletes a proof either. The first door that deletes pins must delete their proofs too. `SchemaTests`'
`v2KeepsEveryPinAndStartsItsProofsEmpty` migrates a v1 pin, and `RepositoryTests`'
`theNewestProofOfKeyIsKeptWhateverTheArrivalOrder` runs over both stores.

**Consequences / limits:**

- **A new string column is a `BLOB` bound through `StoredText`, in a `STRICT` table.** A query that binds a
  `String` to compare with one matches nothing and raises no error. Only the contract tests catch that.
- **Never edit a committed migration or its pin.** `SchemaTests.migrationsOnlyEverGrowAtTheEnd` and
  `everyMigrationLeavesItsPinnedSchema` fail on an edit, a reorder or a removal, and a migration without a
  pin. `everyTableIsStrict` fails on a table that is not `STRICT`. `grdbCutsABoundStringAtItsFirstNul` fails
  if GRDB ever binds a string's whole length; v1 stays as it is even then.
- **The SQL stores run the same contract tests as the memory stores:** `CustodyStoreTests` and
  `RepositoryTests` in `KnitStoreTests`, over every kind. `anIdWithANulIsNotItsOwnPrefix` and
  `messageIdsCompareByTheirBytes` pin the byte keying. `CustodyRulesTests`'
  `anEvictedIdTakesOnlyItsOwnBytesOutOfTheCount` and `groupsThatSwiftCallsEqualAreTwoBuckets` pin the rules
  fix.
- **A failing database degrades the app quietly unless the app listens.** `KnitDatabaseTests` checks that each
  failure is reported and answered empty. Showing it to the user is P6's job.
- **The protection code is compiled only for iOS, and checked only on Apple hardware.** Linux runs the
  directory's creation. `theDirectoryIsExcludedFromBackups` also reads the backup flag back on the Mac (P7),
  and the protection class needs a check on the iPhone (P8).
- **The Linux peer still keeps its stores in memory.** Pointing it at a database file is a small change, and
  it would let an interop run exercise this store over the air.
