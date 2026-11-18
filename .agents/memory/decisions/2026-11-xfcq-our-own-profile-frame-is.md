---
id: "2026-11.xfcq"
slug: our-own-profile-frame-is
title: "Our own profile frame is kept, so an evicted stamp goes back as its bytes"
date: 2026-11-18
topics: [crypto, custody, profiles]
---

# ADR 2026-11.xfcq — Our own profile frame is kept, so an evicted stamp goes back as its bytes

Status: Accepted (2026-11-18)

**Context:** `MeshEngine.ownProfile()` answered our profile frame for the current publish stamp from custody's row, else
from `signedProfile`, the copy this process signed, else from a fresh signing. `signedProfile` lives in memory. After a
restart whose custody had lost the row to our own sender quota (ADR 2026-10.9e7g) before the 12-hour republish, the
start signed the same stamp again. CryptoKit randomizes Ed25519 signatures, so on the iPhone the new bytes always
differed, and the content could drift too: `currentProfileEnvelope` reads the prekey a publish names only while the
ring still keeps it, and the device tag as the build has it. Peers that held the stamp kept their first bytes, so one id
carried two sets of bytes, and in every DM scope two blobs (knit-next ADR 2026-09.y5f3). Linux signs deterministically,
so no test here saw it. knit-next closed the same residual with its ADR 2026-11.khhj (`c1dcef23d`), which supersedes
the "Not covered" residual of its ADR 2026-09.qztx.

**Decision:** we port khhj's signing rule. Our own profile frame for the current stamp is kept outside custody, byte
for byte, and a stamp is signed once.

- **Where it lives.** `own_profile_frame` (`slot = 0`, `sig` and `signed` as `BLOB`s, `STRICT`), under the migration
  `v25-own-profile-frame`. It is a table of its own, not columns on `own_profile`: `SQLOwnProfileStore.save` is an
  `INSERT OR REPLACE` that would null them. The name is not a bare `v25`, because GRDB keys a migration by its
  identifier, and a phone that ran this one as `v25` would skip another branch's `v25`. The database is excluded from
  backups, as khhj's settings keys are backup-transient. Never `UserDefaults`, which is backed up. `OwnProfileStore`
  reads it through `keptFrame()`, which answers a frame, none kept, or a failed read, and writes it through `keep(_:)`.
  knit-peer's `FileOwnProfileStore` keeps it in `profile-frame`, as the wire's own envelope around the two byte strings.
- **`ownProfile()`** (`MeshManager.signOwnProfileLocked`, `MeshManager.kt:6315-6345` at `c1dcef23d`) answers from the
  first of the following.
  1. Custody's row. It is also kept as the frame when the kept bytes differ, which is how the first start of this build
     fills it.
  2. `signedProfile`, a write-through cache. Without it, a store that keeps failing would make every link-up sign again.
     When the unit's read shows a kept frame other than the cached one, as a keep that failed leaves it, the cached frame
     is kept.
  3. The kept frame, accepted only if it decodes from `signed` as a `.profile`, its id is the current stamp's by
     `ExactKey`, its sender is us by `ExactKey`, and its signature verifies against our key. It is served as stored. A
     frame whose decode, type, sender or signature fails is forgotten and counts as none kept. That also covers another
     identity's frame after a replaced identity, with no clearing path. A frame of ours under another stamp is not
     forgotten: the fresh signing below replaces it.
  4. A fresh signing, kept, cached and carried.

  The stamp comes from `OwnProfileStore.loadIfReadable()`. A profile row that cannot be read answers `nil`, logged,
  never `load()`'s fresh profile at stamp 0. Custody's row and the kept frame are read in one store unit of their own,
  never nested in another, so a failed custody read never passes for "no row". A unit that joined another counts as
  failed.
  Whatever answers after a custody miss, the cache or the kept frame, goes back into custody through `carryOwn`, under
  the same quotas, byte cap and `admits` as every frame of ours. Nothing is minted or sealed, and nothing checks the
  capabilities. When either read fails and the cache lacks the stamp, the answer is `nil`, logged: an earlier process
  may have signed it. The start's seed, `pushProfile(to:)` and `signFreshProfile`'s fallback reach that case. The start
  ignores the answer, a link-up pushes nothing and the next link-up asks again, and an edit whose save did not land then
  floods nothing.
- **`publishEdit` and `republish`** sign through `signFreshProfile(publishedAt:)`, which never reads the kept frame: the
  stamp they just saved, `max(now, publishedAt + 1)`, cannot have a frame yet. An edit therefore still floods on a
  database whose kept frame cannot be read. If the store reads back another stamp, the save did not land, so it answers
  `ownProfile()`'s frame for the stamp the store does name, which may already have been signed.
- **khhj's watcher half has no counterpart here.** No path in this port treats a missing custody row as an edit. Edits are
  explicit (`updateProfile`, `publishEdit`). `republishIfCapabilitiesChanged`, `republishIfStale` and `syncPrekey`
  compare the stored profile, never custody, and `savePublished` only saves.

The alternatives were the issue's second option, minting a fresh stamp whenever the row is gone, and skipping the cache.
A fresh stamp costs a flood for every start that finds the row gone, and departs from Android's rule. Without the cache,
a failing store would sign at every link-up.

**Consequences / limits:**

- About 500 bytes in the database, and one write per fresh signing and per build's first start.
- A phone whose row was already evicted before this build signs once afresh at its first start, since nothing was kept
  yet. Android accepts the same limit.
- An evicted profile stays out of a full store until a caller re-stores it, as on Android: the start's seed and each
  link-up's push re-store it, and a full bucket may trim it again at once. A re-store whose only eviction is the frame
  it inserted still answers `changed`, so it bumps `custodyRevision`. That costs the spool's scopes a fold, not a byte.
- Debug only: Diagnostics' "replace identity" minting B over A, then A back under the same `publishedAt`, finds B's
  frame, which A refuses by its sender and signs once afresh. A frame A signed under that stamp before B may still be on
  peers.
- knit-peer's `pad-profile` forge reads the kept frame when custody lacks the row, as it does after every restart.
- The trap: never let a failed read of the kept frame or of custody fall through to a fresh signing of a stamp an
  earlier process may have signed, and never judge an edit by what custody holds.

Kept true by `MeshEngineOwnProfileFrameTests`, `MeshEngineOwnProfileFrameEdgeTests`, `MeshEngineOwnProfileFrameRepairTests`
and `SpoolOwnProfileFrameTests`. Every restart in them moves the device tag, so a second signing differs on Linux too.
The restart, first-start, failing-read, edit-after-eviction, overall-cap and both spool cases fail on the pre-fix rule.
Four cases pass on it and guard other edges: `aRingThatMovesWithinOneProcessChangesNoBytesUnderTheStamp` (the cache
answers within one process), `aKeptFrameThatNoLongerVerifiesIsReplacedByAFreshSigning` (a fresh signing was the old
answer too), `anEditWhoseSaveDidNotLandSignsTheOldStampNoSecondTime`, where on Linux only its log line can fail, and
`anotherIdentitysKeptFrameIsIgnoredAndTheNewIdentitySignsOnce`, whose "signs once" holds before the fix too: what it
tells apart is the foreign frame forgotten. `MeshEngineOwnProfileFrameRepairTests`' row-read and cache-repair cases fail
without the `loadIfReadable` guard and the cache's keep.
Also by `OwnProfileFrameStoreTests`, `FileOwnProfileFrameTests`, and `SchemaTests`'
`v25OwnProfileFrameKeepsOurProfileAndKeepsNoFrame`. The restart, first-start, flipped-signature and failing-read cases
also run on macOS, where CryptoKit randomizes.
