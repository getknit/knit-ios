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

**Amended 2026-09-30, schema v3:** groups (ADR 2026-09.n393). `messages` gains `kind`, so a group thread can hold
status lines, and every older row reads as an ordinary message. `groups` holds a row for each group, and
`group_members` holds its roster in order, with each member's leave and rejoin clocks. knit-next keeps those clocks
in status lines instead. Adding a column rewrites the stored `CREATE TABLE` text, so the v3 pin was taken from a
run. `SchemaTests`' `v3KeepsEveryMessageAsAnOrdinaryOneAndStartsWithNoGroups` migrates a v2 row, and
`GroupStoreTests` runs over both stores.

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

**Amended 2026-10-03, for photos (ADR 2026-10.nh55):** schema v4 adds a `blobs` table that only indexes the blobs
held. The bytes live in files named by their hash, in `Blobs/` inside the database's directory, which gives them its
protection class and backup exclusion (`SQLBlobStore`). Bytes kept inside SQLite would leave the file at its high-water
mark for good: 128 MiB of carried photos would stay 128 MiB, since only a VACUUM gives the space back, and a VACUUM
cannot run inside a migration. A blob's file is written whole before its row. The sweep when the store opens removes a
file no row names and a row whose file is gone. `SQLBlobStoreTests` pins that, and `RepositoryTests` pins that a
republish keeps our photo's column.

**Amended 2026-10-04, for the content filter (ADR 2026-10.e4kz):** schema v7 adds `messages.moderation`, what the filter
made of a message's words: 0 clear, 1 flagged (knit-next's codes) and 2 waiting, this port's own, for a message the
engine stored and the app has yet to screen. A partial index on `seq` where it is 2 serves the launch's sweep; the code
is written into that query, since SQLite uses a partial index only for a term it can see matches. Every row stored
before v7 reads as clear. `SchemaTests.v7ShowsEveryMessageAsItWas` migrates a v6 row, and `MessageModerationTests`
runs over both stores.

**Amended 2026-10-15, for the ratchet's store unit (ADR 2026-10.5sk9, amended for P4a):**

- **The database is also the unit a ratchet change commits in.** Inside a unit a store's error still answers the
  fallback and is still reported, once, and it also fails the whole unit, which undoes every write in it. A session's
  advance kept without the message row it carried would have spent that message's key for good.
- **A blob's file error is the exception.** The file is no part of the transaction, so the error is reported and fails
  nothing. A `nil` or `false` from a blob's bytes inside a unit may only mean doing nothing (as `notePlainHash` does),
  never a decision.
- **A blob's file goes only when its row's removal commits:** at once outside a unit, at the outermost commit inside
  one, and only if no row names the hash by then. Before, `SQLBlobStore.remove` took the file whatever became of the
  row, so a removal the database refused or a unit undid left a row that read as held with no bytes behind it.
- **The closure the app hands `KnitDatabase`** can run on the writer's queue, for an error inside a unit or one met as
  a write commits, so it must never block on the main actor or touch the database.
- Outside a unit nothing else changes. `KnitDatabaseUnitTests` keeps both halves, and `BlobStoreTests` and
  `SQLBlobStoreTests` keep the files.

**Amended 2026-10-15, for keys that must die (ADR 2026-10.5sk9, phase P4c):**

- **Deleted rows are zeroed on every platform.** Every connection, the writer's and each reader's, sets
  `PRAGMA secure_delete = ON` (`KnitDatabase`), which overwrites a deleted row with zeros, and every page a deletion
  frees. Apple's SQLite defaults to FAST, measured as 2 on the Mac's 3.54.0: it zeroes a row only where that costs no
  extra write, and leaves freed pages on the freelist as they were. Linux's system SQLite is built with it on, and
  Android's database is SQLCipher (sqlcipher-android 4.19.1, knit-next `gradle/libs.versions.toml:43`, on core
  4.19.0), whose `sqlcipherCodecAttach` forces it. In WAL mode the zeroed page goes to the log, and the file keeps the
  old page until a checkpoint copies the new one over it.
- **The write-ahead log is truncated after the ratchet's sweep.** The log keeps the frames that wrote a row, its keys
  included, until it is reset and overwritten. `SQLRatchetStore.sweep` truncates it with
  `PRAGMA wal_checkpoint(TRUNCATE)`, which also copies the zeroed pages over the file, once the outermost transaction
  it wrote in commits, through GRDB's
  `afterNextTransaction`, as a blob's file waits for its row's removal: never on a rollback, never inside a
  transaction, whether the sweep runs alone or inside a unit. A reader holding a snapshot of the log makes the
  checkpoint answer `SQLITE_BUSY`, which is expected, and the next sweep truncates. Any other error is reported and
  fails nothing.
- **Why now:** the ratchet keeps keys that must die. What its sweep retires and what an open spends is the forward
  secrecy window (`RatchetRetention`), so it must leave the file, and not only the tables.
- **SQLCipher still waits.** Its key would sit in the Keychain under the same after-first-unlock class the mesh needs,
  so it would guard the file no better than Data Protection does. The reason it now has, keys that must die, is met by
  these two.
- **Limits:**
  - Between sweeps either file can hold a key deleted or replaced since the last one: the log its insert and every
    chain key a seal or an open replaced, the file the page an earlier checkpoint wrote. Nothing calls the sweep before
    P5, which runs it at start and at most hourly, as Android does, and a reader on the log when it commits puts the
    truncation off to the next sweep.
  - The zeros cost writes: over FAST, one more page write for each page a deletion frees that was not being written
    anyway, an overflow page or the pages a bulk delete empties, as custody's sweep and the ratchet's do. The blobs
    review measured a full custody sweep of maximum-size frames at about 2,000 more pages, 7 ms to 20 ms, on Linux.
    Nothing was measured on a phone.
  - `secure_delete` zeroes a row where it lies when it goes, and every page a deletion frees, but not an older copy of
    a cell that a page's rebalance left in its unused space (`rebuildPage`, SQLite 3.53.4's `btree.c`). Rarely, such a
    copy outlives the sweep until the space is reused or the file is vacuumed: a probe on Linux's SQLite kept 1 or 2 of
    about 5,840 replaced chain keys. Android's SQLCipher pages carry the same leftover on the same core. A `VACUUM` now
    and then would close it by rewriting the whole file through the log. On 2026-10-15 the maintainer held it for a
    paired change with knit-next, so both platforms close it the same way (`.agents/memory/roadmap.md`, "Deferred by
    design").
  - What the flash keeps of blocks the file system frees or rewrites is beyond SQLite's reach.
  - Only `test:macos` reads the setting back on Apple's SQLite, and nothing reads it on the iPhone's. The pragma is set
    whatever the default is.
- **Guards:** `KnitDatabaseTests.everyConnectionErasesWhatItDeletes` reads `secure_delete` on a pool's writer and
  reader and on the queue in memory, which only the Mac's run can fail. `SQLRatchetStoreTests`'
  `whatTheRatchetDeletesLeavesTheFileAndItsLog` searches the database's files for a spent key, keys the sweep expired
  and a retired epoch's private key, after a sweep alone and one in a unit, and fails without the truncation.
  `theLogIsTruncatedOnlyAsTheOutermostUnitCommits`, `aReaderOnTheLogPutsTheTruncationOffToTheNextSweep` and
  `anyOtherCheckpointErrorIsReportedAndFailsNothing` keep the rest.
