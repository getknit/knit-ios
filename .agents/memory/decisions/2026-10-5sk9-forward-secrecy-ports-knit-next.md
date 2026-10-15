---
id: "2026-10.5sk9"
slug: forward-secrecy-ports-knit-next
title: "Forward secrecy ports knit-next's ratchet whole, dark behind one switch"
date: 2026-10-15
topics: [crypto, dm, groups, interop]
---

# ADR 2026-10.5sk9 — Forward secrecy ports knit-next's ratchet whole, dark behind one switch

Status: Accepted (2026-10-15)

**Context:** every DM and group message this port seals is v1, a fresh key wrapped to each recipient's static X25519
key, so whoever later takes that key opens every v1 message ever sent to it (ADR 2026-09.qsd9). The roadmap puts
forward secrecy before any public build. In knit-next it is five pieces that ship together:

- the DM epoch ratchet, v2, bootstrapped by X3DH off a signed prekey (knit-next ADR 016);
- the group form, a sender-key ratchet whose seeds ride the pairwise DM sessions (knit-next ADR 017);
- the sealed control plane, which carries receipts, reactions and profile updates as ctl DMs (knit-next ADRs 018,
  020 and 033);
- v3, with a compact plaintext, a derived nonce and an unsigned live-link tick (knit-next ADR 059);
- inline acks (knit-next ADR 054).

One bit covers DMs and the group form (`Protocol.kt:51-60`). Android seals the group form whenever every other member
of a group advertises it with a prekey (`MeshManager.kt:1344-1353`), and every build since 2.3.0 does so. Every one
of those builds also advertises the bit with a prekey of its own. Android starts a session just to seal a receipt
(`InboundPipeline.kt:2904-2948`). The Kotlin is about 4,200 lines, with 3,650 lines of tests, and nobody has written
keyed vectors for it (`.agents/context/crypto.md`). Kotlin lines here are at knit-next `ac491f4c`, past this port's pin.

**Decision:**

- **Port all five pieces.** That covers DM v2 and v3, the group form both ways, ctl codes 1 to 6 and 8, inline acks
  both ways, the answer an init is owed (IntroSync's answer half), and our own and our peers' prekeys.
- **Skip only what no fielded Android build needs from us:**
  - the spool's exports, since there is no spool here (ADR 2026-09.zwdp);
  - sending contact-card intros, which waits for Contacts;
  - `CTL_TRANSFER`, which Android sends only toward `0x800`, so it takes the unknown-ctl path;
  - unsigned tick sends, since a signed tick verifies on Android the normal way;
  - the LoRa and spool tick paths;
  - `gr` root gossip, which is decoded, kept raw and never sent. The cost is bounded: a 6 h grace on a group this port
    founded, and at most one correction per group and member every 15 minutes (`GroupRootPolicy.kt:49`,
    `MeshManager.kt:1623-1646`).
- **Phase order.** Keyed vectors come first, as companion change A9. Then:
  1. the codec and primitives;
  2. prekeys;
  3. a store unit that fails closed, and the DM engine;
  4. DMs in the mesh;
  5. the group form received, then the group form sent;
  6. A10, interop runs, and the flip.
- **The switch, `MeshConfiguration.ratchet`, off by default.** Every phase merges with it off.
  - **Off:** the iPhone puts the same bytes on air as before. It seals the ratchet toward nobody, even Android peers
    that advertise it, publishes no prekey, and drops a v2 or v3 frame as `.cannotOpen`. Pinning peers' prekeys runs
    anyway, since it sends nothing.
  - **On:** the signed profile adds `0x10`, `0x40` and `0x100` and carries our prekey. The HELLO and the advert stay
    `0xF`, because Android takes a peer's capabilities from its pinned profile alone (`CryptoScheme.kt:11-13`).
  - **Every toggle republishes the profile** (the P3 amendment below refines this: a never-edited profile stays at
    version 0) under a new stamp, with a version bump, as Android's prekey rotation does
    (`MeshManager.kt:996-1003`).
  - **Who can turn it on:** knit-peer, with `--ratchet`, and a Debug build, with `-ratchet`. A release build cannot,
    until the flip.
- **The flip is one change.** `Capabilities.local` becomes `0x15F` and the switch defaults on. That waits on four
  things: every promise in `crypto.md`'s ratchet section holds; A9 and A10 pass on Linux and in `test:macos`; knit-peer
  passes interop runs against knit-next `main` and the 2.9.0 and 2.8.0 APKs; and a Debug iPhone trial passes.
- **The Kotlin decides,** as `.agents/rules/interop.md` says, where it and `docs/FORWARD_SECRECY_RATCHET.md` or
  `docs/GROUP_FORWARD_SECRECY.md` disagree. knit-next's own crypto reviewer treats those docs as normative. The
  research for this port found ten places where they lag the Kotlin; each goes to knit-next as a doc fix.
- **One new unsigned shape, admitted only with `0x100` on:** the v3 live-link tick.
  - It must be a `relay = false` chat in DM form, addressed to us by a pinned peer. It is checked ahead of the
    exists-gate, and it must open as a v3 `CTL_RECEIPT` before anything commits. It is never custodied and never
    counts toward a reset (`InboundPipeline.kt:592-598`, `:1739-1768`).
  - This moves the trust boundary the crypto reviewer's shape 5 guards, on purpose.
- **A reinstall:** the Keychain keeps the identity and the prekeys, and every session dies with the database (ADR
  2026-09.tkww).
  - The iPhone sends no resets of its own then, because it has no peer list to send them to, and resetting every peer
    as it pins would reset strangers too.
  - The peers' next frames fail as `NO_SESSION`, the reset heuristic re-roots each pair, and the peer re-seals its
    last 24 h of DMs (`MeshManager.kt:3361-3407`).
  - A launch that finds a stored identity over an empty database (refined by the P3 amendment below) draws a fresh
    prekey and bumps the profile, as
    Android's restore does (`MeshManager.kt:1036-1047`), but without the resets that follow it there.
- **The alternatives, and why not:**
  - **DMs first, with groups left on v1:** the one bit makes Android seal the group form toward any iPhone that
    advertises it.
  - **A new bit for the group form:** builds already in the field would still seal it.
  - **One branch merged at the flip:** a single review of thousands of lines, and nothing proven along the way.
  - **Porting from the two docs:** they lag the Kotlin.

**Consequences / limits:**

- **Until the flip,** the iPhone stays on v1, and every claim that v1 has no forward secrecy stays true.
- **Evidence before the flip** is thin. The dark phases add paths no fielded phone runs, so knit-peer runs and the
  Debug trial are the only live evidence for them, and CryptoKit runs only in `test:macos` until the trial.
- **A reinstall after the flip strands every session** until the heuristic and the peer's re-seal recover it, and
  every TestFlight reinstall will exercise that path.
- **Fielded Android lags `main`.** knit-next `38e425b5` first shipped in 2.9.0, and `0f519d71` and `795b0883` are in
  no tag yet, so interop runs cover the release APKs as well as `main`.
- **The guards today:**
  - `LinkTests` and `MeshEngineProfileTests` pin `0xF`.
  - `MeshEngineDirectMessageTests.aRatchetDMIsCarriedAndRelayedButCannotBeOpened` pins the drop.
  - `PersonaTests` keeps the review gates in step with the paths.
- **The guards to come:** the DM phase adds a test that the switch off puts the same bytes on air, and the flip
  changes the pins above in the same change.

**Amended 2026-10-15, phase P3 (prekeys):**

- **Our prekeys live in the identity's own item** (`PrekeyRing`), as `{signingSeed, agreementScalar, prekeys: [{id,
  priv, createdAt, sig}]}`, so an older build still reads its identity and a reinstall keeps them. Each signature is
  kept from its mint, since CryptoKit's Ed25519 is randomized. A rotation reads the item, checks the identity in it,
  replaces `prekeys` alone, writes and reads back, and the ring changes only after that.
- **A rotation never reuses an id or drops what it cannot read.** It mints one above the highest id any stored entry
  names, read or not. Android's restore mints `max(stored) + 1` too, and its profile bump makes peers take the new key
  (`IdentityKeyStore.kt:195`, `MeshManager.kt:1011-1016`). It prunes only entries it
  reads, keeping the five highest ids, and writes every other entry back as it was stored without counting it toward
  the five: Android never mints over prekeys it cannot parse (`IdentityKeyStore.kt:136-137`), and such an entry may be
  a newer build's prekey that a peer's init names.
- **A publish names its prekey** (`OwnProfile.prekeyId`, schema v16), so one stamp is one payload. Start and every heal
  mint a due prekey with the switch on and republish as an edit when the newest differs, and a profile that still
  names one with the switch off is republished without it. A profile never edited, at version 0, is republished
  instead: a new stamp, its version left at 0. So every toggle moves the stamp, and moves the version once the profile
  has been edited.
- **The bits and the prekey ride together, or neither does.** `CAP_RATCHET` promises a published prekey, so a node with
  no ring, or whose store refused the first mint, publishes what it would with the switch off. The alternative, the
  bits whenever the switch is on, would claim a promise no Android build ever claims without a prekey.
- **Peers' prekeys pin on their own watermark** (`PeerRecord.prekey` and `prekeyProfileAt`), whatever the switch says,
  as `InboundPipeline.kt:3276-3345` does, capabilities included.
- **A reinstall** with the switch on mints a fresh prekey before its first publish, and that publish is not an edit.
  The mesh starts on onboarding's permissions page, before onboarding publishes the name (`OnboardingModel`), so the
  profile is at version 0 with no name. An edit would flood the empty name at a version every peer takes, and Android
  would write a rename line into every thread with us (`InboundPipeline.kt:1299-1301`). The republish at version 0
  leaves a peer that holds any edit of ours on the name and the prekey it has, which the ring still holds, and
  onboarding's edit then carries the fresh prekey with the name. Android's restore can bump the version because it
  brings the name back. A profile the store cannot read is neither a reinstall nor a profile to edit
  (`OwnProfileStore.loadIfReadable`), so nothing is minted or published until a heal reads it.
- **Not yet wired:** knit-peer's `main` loads no ring; P5's `--ratchet` must load one with `PeerState.loadPrekeys`.
- **Open before the flip: restoring the same phone from its own backup.**
  - **What comes back:** the `…ThisDeviceOnly` identity item and the onboarded flag. The database does not, because
    it is excluded from backups.
  - **What happens:** the mesh then starts with no onboarding and mints `max(stored) + 1`, which may be an id the lost
    item minted after the backup under another key. It publishes that prekey only at version 0, and every peer
    holding an edit of ours ignores it. Their inits would then name a prekey our ring lacks until the user next
    edits the profile.
  - **The fix:** onboarding's edit must follow every database that has never published, either by gating onboarding
    on the database or by keeping the onboarded flag in it. That is a product change outside P3, and it lands before
    the flip. While the switch is off, nothing changes on air.
- **Guards:** `MeshEnginePrekeyTests.withTheSwitchOffOurProfileIsTheBytesItWasAndNothingIsMinted` pins the profile's
  bytes with the switch off; `RatchetProfileVectorTests` feeds A9's `profiles` to one engine;
  `MeshEnginePrekeyReinstallTests` delivers a reinstall to a peer that pinned the first life, in both orders;
  `PrekeyRingTests`, `MeshEnginePrekeyIntakeTests`, `PrekeyStoreTests` and
  `SchemaTests.v16KeepsEveryPeerWithNoPrekeyAndOurProfileCarryingNone` keep the rest.

**Amended 2026-10-15, phase P4a (the store unit):**

- **The unit is `StoreTransactor.atomically`, on `MeshStores.transactor`.** Its body reads and writes stores and
  nothing else, and answers the work for after the commit as a value, or `nil` to abandon. The unit answers
  `.committed`, `.joined`, `.abandoned` or `.failed` (`Transacted`).
  - A unit opened inside another joins it, and a failure anywhere in it fails the outermost. A nested unit that
    abandons undoes only its own writes, as a savepoint does. A unit opened inside one that has already failed answers
    `.failed` without running its body.
  - Only the outermost unit answers `.committed`, and only that answer lets the work after the commit run. A nested
    unit's writes stand only if the outermost commits, so it answers `.joined` with its work, and its caller hands the
    work up through the outer body. A nested `.committed` would let a helper send on it, and if the outer unit then
    failed, the send's chain would be undone and its message key used again.
  - A unit in which a store failed answers `.failed` at every depth that sees the failure, whatever its body answered:
    a `nil` after a failure is no abandon.
  - Nothing opens a unit before P4c.
- **On the database the unit is the `KnitDatabase` itself** (`KnitDatabase+Units.swift`): one IMMEDIATE transaction on
  the writer's connection, with a savepoint for each nested unit and for each store write inside it.
  - GRDB's `write` traps when nested, so the unit and the stores inside it reach the connection through
    `unsafeReentrantWrite`, and `inSavepoint` opens the transaction or the savepoint. The file cites GRDB 7.11.1's
    lines.
  - A store's read inside the unit runs on the same connection, through `unsafeReentrantRead`, so it sees the unit's
    writes. A pool reader's snapshot would miss them, and the queue's `read` would trap.
  - A write decides whether it is inside the unit on the writer's queue. A write from another thread waits for that
    queue and runs after the unit, in its own transaction, so it never joins the unit or fails it. A read goes by its
    thread: only the unit's own thread reads inside it.
  - The closure the app hands `KnitDatabase` hears a unit's errors on the writer's queue, and so does the check a blob's
    removal makes as it commits, so it must never block on the main actor or touch the database. The app's only logs.
- **Any store error inside a unit fails it, a read's as well as a write's, except a blob's file error, which is
  reported and fails nothing.** The body may have decided on a store's fallback. An exception inside Room's transaction
  aborts it the same way on Android.
  - The store still answers its fallback and reports the error, once. After that nothing more in the unit runs or
    reports.
  - A commit that fails, and a BEGIN that cannot take the write lock, answer `.failed` too.
  - A blob's file is no part of the transaction: `SQLBlobStore` reports an error reading one, or writing the one
    `insert` keeps, and fails nothing. Failing a DM's unit on an unreadable photo would leave the DM undelivered, and
    fail it again at every re-serve. So a `nil` or `false` from a blob's bytes inside a unit may only mean doing nothing
    (as `notePlainHash` does), never a decision.
  - Outside a unit every store behaves as before (ADR 2026-09.nyya), save that a removed blob's file now waits for its
    row's removal to commit (Limits, below).
- **In memory the unit is a `MemoryTransactor`** over every memory store, each one `Checkpointing`: every unit copies
  the stores as it opens and puts them back if it abandons or fails. knit-peer's `FileOwnProfileStore` joins it, and
  rewrites its file only when a unit changed the profile. `MeshStores`' stores are `let` now, so none can be swapped out
  from under the unit made over them.
- **The alternatives, and why not:**
  - **Stores that throw:** every store protocol and caller would change, where ADR 2026-09.nyya keeps them synchronous,
    answering a fallback instead.
  - **Deciding "inside a unit" before reaching GRDB's queue:** another thread's write would see the open unit, and its
    error would fail a unit it never joined.
  - **Checkpoints at the outermost unit only:** a nested unit that abandons could not undo just its own writes.
- **Limits:**
  - A unit holds the database's writer from BEGIN to COMMIT, the ratchet's derivations included, as Room's transaction
    does on Android. Its body has to stay short.
  - `MemoryTransactor` serves one caller at a time. A memory store written from another thread while a unit is open
    loses that write if the unit is undone.
  - A blob's file is no part of the transaction, so a body leaves writing or removing a blob to the work after the
    commit. The blob stores stay whole if one does. `SQLBlobStore` writes a file before its row, and deletes one only
    when the row's removal commits (GRDB's `afterNextTransaction`), and only if no row names it by then: a nested unit
    that abandoned brings its row back. An undone unit so leaves at worst a file no row names, which reads as not held
    and goes at the next open's sweep. `MemoryBlobStore` is undone with the rest.
  - knit-peer stopped between a unit's save and its undoing keeps the unit's profile in its file.
- **Guards:** `StoreTransactorTests` runs the rules above over both store kinds. `KnitDatabaseUnitTests` covers other
  threads, a commit that fails, a transaction SQLite rolls back by itself and a BEGIN that cannot start, on a pool and
  on a queue. `PeerPartsTests.aUnitThatIsUndonePutsTheProfileAndItsFileBack` covers the file. `BlobStoreTests` removes a
  blob in a unit that abandons, fails or has already failed, and in a nested unit that abandons, over memory and the SQL
  store on a pool and on a queue. `SQLBlobStoreTests` covers a removal the database refuses, a file that waits for the
  outermost commit, SQLite's own rollback, and an index the commit cannot read.

**Amended 2026-10-15, phase P4b (the DM engine):**

- **The engine is Kotlin's `RatchetEngine`, whole and pure** (`Sources/KnitCrypto/Ratchet/RatchetEngine.swift` and its
  extensions). A session comes in as a value, and every change leaves as a `SealResult` or an `OpenDelta` for P4c's
  store unit to commit. Its ephemerals and epoch keys come from a key-pair source and its v2 IVs from an IV source,
  both the system's generator unless a test passes others, as knit-next's A9 seam does (`newIv`). Nothing calls it yet.
- **It takes this port's types,** so the identity's and the prekeys' private keys stay inside KnitCrypto's own types:
  our `IdentityKeys`, the `SignedPrekey` an init names, the peer's pinned `PublicKeyBundle` and verified `PeerPrekey`,
  and `NodeId`s. Our epochs' private keys are rows the store keeps, as Android's are. A canonical id's `<` is Kotlin's
  string order, which the race's tiebreak and the remnant guard compare by.
- **Where Tink throws out of Kotlin's engine, it throws `RatchetCryptoError`.**
  - `initiate` and `seal` throw on a peer key X25519 refuses. A signature does not rule one out: a peer signs what it
    likes.
  - `open` throws in the X3DH respond, on an `init.eph` or an identity key X25519 refuses. The caller refuses that
    frame with nothing committed and nothing counted toward a reset, as `InboundPipeline`'s `runCatching` records
    `DECRYPT_FAILED`.
  - An `ek` X25519 refuses stays the typed `BAD_HEADER` (`RatchetEngine.kt:456-460`), and neither is ever
    `AEAD_FAIL`.
  - The alternative, a sixth typed failure beside the five the reset heuristic maps, could be counted by mistake.
- **It is stricter than Kotlin's engine in two places, and the node's outcome is the same:**
  - A carried nonce that is not 12 bytes is `BAD_HEADER`. Kotlin's pipeline refuses it before its engine
    (`InboundPipeline.kt:1025-1028`), and AES-GCM here would only refuse it as `AEAD_FAIL`, which counts toward a reset.
    The pipeline's other shape rules stay P5's: a v3 envelope's empty nonce, and no DM form addressed to a group.
  - It reads a receive chain or a skipped key only for the header's own `se` and `n`, where Kotlin trusts its caller
    to pass no others.
- **The session keeps no `sendEpochExport`,** the spool's half, which Android stores and never reads back. The
  transcripts' `sendEpochExportSha256` is not compared.
- **`seal` answers `nil` in two cases:** a new epoch due with no base, and a session missing its send chain or,
  unconfirmed, its init, where Kotlin's `checkNotNull` throws. The second cannot happen by construction, so P4c's
  session store must round-trip every `SessionState` field, or a lost field would quietly turn every DM to v1. Neither
  `nil` means "send v1" by itself: a chat falls back to v1, a ctl to its cleartext frame, and a seed waits.
- **Open for P5:** what the iPhone does when a seal throws. Android lets the throw escape `sendChat`
  (`MeshManager.kt:1189`, `:1295`).
- **Guards:**
  - `RatchetEngineTests` ports `RatchetEngineTest`'s 43 cases by name and adds this port's: the nonce rule, the throws,
    the epoch filter, the replacement floor and a drain that runs out.
  - `RatchetSoakTests` runs the soak's property on five seeds of this port's.
  - `RatchetTranscriptTests` replays A9's engine-layer transcripts byte for byte, Carol's included. It names what
    waits: the five with a reset step for P4c, the pipeline's own refusals for P5, and `group` for P6.

**Amended 2026-10-15, phase P4c (the session store and facade):**

- **The store is `RatchetStore`** (KnitStore), knit-next's seam, with records of bytes, numbers, flags and node ids, since
  KnitStore does not depend on KnitCrypto. `RatchetRecords` (KnitMesh) is the one place they meet the engine's types.
  - `MemoryRatchetStore` is `Checkpointing`, so the memory unit undoes it with the rest.
  - `SQLRatchetStore` keeps schema v17: Android's four `ratchet_*` tables as its database v21 has them, `STRICT`, every
    string a UTF-8 `BLOB`. The session leaves out `sendEpochExport`, the spool's, and `updatedAt`, which nothing reads.
  - The row rules are `RatchetDao`'s: the session, a chain and a local epoch replace, a skipped key is inserted if absent,
    and a spent key goes by its full key, root tag included.
  - A deleted row is zeroed in the next write of its page, which reaches the file at a checkpoint, and each sweep runs
    a truncating checkpoint as it commits, unless a reader holds the log then (ADR 2026-09.nyya, amended 2026-10-15).
    Nothing calls the sweep before P5.
- **Retention is pure code** (`RatchetRetention`), which both stores apply, as `CustodyRules` serves custody. Android
  orders the cap's eviction by `createdAt` alone and leaves a tie to SQLite. Here a tie goes by peer, epoch, index and
  root tag, so the two stores evict the same keys. The order is local, and the pair never compares it.
- **The facade is `RatchetSessions`** (KnitMesh), which the engine owns.
  - Each call decides and writes inside one unit, and reads the store inside it too, so a store that cannot answer
    fails the unit rather than deciding on its fallback.
  - An open runs in one phase. Its changes commit with what the caller writes in `alongside` (P5's message row), or
    none do.
  - Each call answers `settled`, `joined` or `failed`. A joined answer hands its floor changes up as a `Settlement`,
    which the caller applies once its outermost unit commits; before then nothing it made is sent or delivered.
  - The floors held in memory (replacements adopted, our init's answer, our resets with no session row, the heuristic's
    frame ids, compared by their bytes) die with the process, as Android's do. Each moves only after a commit, save that
    a frame the heuristic counts joins its ids at once, as on Android: only their clearing waits for a commit.
- **It takes the peer's pinned bundle,** whose node id keys the rows, where Kotlin passes a peer id and an identity key
  apart: one value cannot name two peers.
- **The init's prekey is the one its `pkid` names** (`RatchetSessions.kt:140`). One under another id counts as none:
  the engine trusts what it is handed, and a wrong prekey would derive a wrong root whose `AEAD_FAIL` counts toward a
  reset.
- **A key X25519 refuses commits nothing and counts toward nothing.** A seal answers `refusedKey`, which a chat treats as
  having no session (v1), a ctl as its cleartext frame and a seed as a wait (P5). An open answers `rejected`, as
  `InboundPipeline`'s `runCatching` records `DECRYPT_FAILED`.
- **The reset's pure rules are `RatchetResetPolicy`'s:** the evidence that counts, the era gate (`isLiveEvidence`), the
  replacement floors and the plan, with the rule that decided it. Every reset seals v2, as `{"body": "", "ctl": 1}`.
- **`noteUndecryptable` runs the era gate itself, in Kotlin's order** (`InboundPipeline.kt:1835-1856`): a unit that only
  reads the session row, then, outside it, `isLiveEvidence`, and only then the frame id joins the heuristic's ids, at
  once, and the 6 h floor reads the later of the stamp the unit read and the one held in memory. A unit that fails
  counts nothing, and so does a call inside a caller's unit: a joined open or reset clears the ids only once that unit
  commits, where Kotlin clears them as an open commits and as a reset is sealed (`RatchetSessions.kt:207-211`, `:435`,
  `:466`).
  - Kotlin's `sessionFor` throws on a Room error, so nothing counts there either. With the gate left to the caller, over
    a read that answers none when the store fails, a frame from the era a reset abandons could enter the eight slots,
    and three such frames would re-root on that era's evidence (knit-next `d7487392`).
  - `sentAt` is the envelope's signed stamp as it arrived, never clamped to our clock (`InboundPipeline.kt:1897-1899`). A
    responder's `establishedAt` is the peer's own `init.at`, so a clamped stamp would class every live failure from a
    peer whose clock runs fast as pre-era (knit-next `cf447a9b`).
- **The control surface's `ratchet` command** dumps every pinned peer under the keys of Android's `RATCHET`, plus the
  prekey our profile names. With `reset` it seals one past the heuristic. Before P5 that reset is persisted and never
  sent, and with the switch off it is declined, so no session starts that would outlive the flip.
- **The alternatives, and why not:**
  - **Android's two phases,** a peek with no lock and then a commit: moderation runs after the row here, so nothing
    needs the peek, and one phase cannot race itself.
  - **A facade that refuses to run inside a caller's unit:** nothing can enforce it, so a joined answer carries its
    floors up instead.
  - **Android's eviction order:** the memory and SQL stores could evict different keys.
  - **The era gate in the caller, where Kotlin's pipeline keeps it:** the only session read the facade offered outside a
    unit answers none when the store fails, so that gate would fail open.
- **Limits:**
  - The facade serves one caller at a time, the engine's actor, as `MemoryTransactor` does.
  - A restart forgets the floors held in memory, as Android's do. The persisted `lastResetSentAt` is what survives.
  - A reset the control surface seals before P5 moves our session without the peer hearing of it. Our next frame
    carries the new init, and the peer adopts it as an unflagged replacement, past its hour.
  - Replaying an inbound frame whose open failed, from our own custody, is P5's, and so are the two-engine tests the P4a
    reviews owe.
- **Guards:** `RatchetStoreTests` (knit-next's ten `RatchetRepositoryTest` cases, the unit and the eviction order, over
  both store kinds), `SQLRatchetStoreTests` (a refusing trigger, and what a deletion leaves in the files),
  `RatchetRetentionTests`, `RatchetRecordsTests`, `RatchetSessionsResetTests` (knit-next's twelve
  `RatchetSessionsResetTest` cases), `RatchetSessionsTests`, `RatchetSessionsDatabaseTests` (the facade over the
  database), `RatchetSessionsFloorTests`, `RatchetSessionsEvidenceTests` (the era gate inside the facade: a session it
  cannot read, a frame from before the era, a peer whose clock runs fast, an initiator's skew and its 48 h),
  `RatchetResetPolicyTests`, `RatchetTranscriptSessionTests` (A9's six session-layer transcripts),
  `MeshEngineRatchetTests`, `MeshControlRatchetTests` and `SchemaTests.v17KeepsEveryPeerAndStartsWithNoRatchetState`.
