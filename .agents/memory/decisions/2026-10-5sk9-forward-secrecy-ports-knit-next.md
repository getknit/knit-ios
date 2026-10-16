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
  sent (P5a sends it, below), and with the switch off it is declined, so no session starts that would outlive the flip.
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
  - Replaying an inbound frame whose open failed, from our own custody, is P5's (P5a keeps the copy that failed instead,
    below), and so are the two-engine tests the P4a reviews owe.
- **Guards:** `RatchetStoreTests` (knit-next's ten `RatchetRepositoryTest` cases, the unit and the eviction order, over
  both store kinds), `SQLRatchetStoreTests` (a refusing trigger, and what a deletion leaves in the files),
  `RatchetRetentionTests`, `RatchetRecordsTests`, `RatchetSessionsResetTests` (knit-next's twelve
  `RatchetSessionsResetTest` cases), `RatchetSessionsTests`, `RatchetSessionsDatabaseTests` (the facade over the
  database), `RatchetSessionsFloorTests`, `RatchetSessionsEvidenceTests` (the era gate inside the facade: a session it
  cannot read, a frame from before the era, a peer whose clock runs fast, an initiator's skew and its 48 h),
  `RatchetResetPolicyTests`, `RatchetTranscriptSessionTests` (A9's six session-layer transcripts),
  `MeshEngineRatchetTests`, `MeshControlRatchetTests` and `SchemaTests.v17KeepsEveryPeerAndStartsWithNoRatchetState`.

**Amended 2026-10-15, phase P5a (DMs received in the mesh):**

- **With the switch on, a DM-form v2 or v3 frame addressed to us opens through `RatchetSessions`, in one store unit
  with what it carries** (`MeshEngine+RatchetInbound.swift`; `decryptAndDeliverV2`, `InboundPipeline.kt:1008-1104`).
  - The unit holds the open's delta and either the message row with its inline acks, or what a ctl applies: receipts
    (5) under the forged-ack guard, which purge nothing; a DM-form reaction (6), last writer wins on `sentAt`; a sealed
    profile (8), its presentation only, on the presentation's watermark. A reset (1) is the open's own delta. The group
    form's codes (2, 3, 4) until P6, and any code this build does not know, commit the chain's advance and nothing else.
  - `deliverChat` is split in two (`MeshEngine+Delivery.swift`). The unit writes the row. The event, the typing cue,
    the photo's fetch or local copy and the acknowledgement wait until it commits. A v1 DM runs both halves at once, as
    before.
  - Kotlin judges two things on its peek, before it commits: a plaintext that will not decode or is too new, and an
    unsigned frame that is not a receipt. Here both are judged inside the unit, where answering `nil` abandons the
    open. The chain index stays unspent, so the signed copy of a frame refused unsigned still opens once the router's
    window has passed.
  - A ratchet DM is acknowledged with this build's cleartext receipt, the form Android sends an author who cannot read
    a sealed one. P5c seals it.
- **Refused before the engine, and never counted** (`:1017-1028`): a frame with no `r` header, v3 addressed to a group,
  a v3 nonce that is not empty, and a v2 nonce that is not 12 bytes. v3 reaches the engine as a `nil` nonce, set from
  the version after the empty-nonce check. A v2 group frame stays `.cannotOpen` until P6, and so does a sealed room
  post, which Kotlin would try in the DM arm with an empty thread.
- **The unsigned tick** (`:592-598`, `:664-667`, `:938-941`, `:1761-1768`). With the switch on, `verify` admits a
  `relay = false` DM-form chat to us from a pinned peer with an empty signature. It must carry v3 with `r` and no `g`,
  and open and decode as a `CTL_RECEIPT` before its unit commits. Any other unsigned frame drops as `.unsigned`,
  Android's `UNSIGNED_REFUSED`. The exists-gate is a signed frame's alone, so a forged tick naming a DM we hold earns no
  second receipt. The tick is never carried or relayed, and none of its failures counts toward a reset.
- **Failures** (`onRatchetFailure`, `:1775-1828`). Each typed failure has its own drop reason. A signed frame's
  `NO_SESSION`, `EPOCH_GONE` or `AEAD_FAIL` lets one copy of its id past the router's dedup (`Router.reopen`), since the
  peer answers a reset by sealing that frame again under the same id. It then goes to `noteUndecryptable`, outside any
  unit, with the envelope's signed `sentAt` as it arrived. When the heuristic fires, the engine seals a reset for
  `.unreadable` and sends it.
- **Sending a reset** (`sendSessionReset`, `:1914-1961`). `sealResetDm` seals it, always as v2, and it leaves the way
  Kotlin's `originate` sends a frame: a chat to the peer, signed once, carried in our own custody and flooded, with no
  message row. Nothing goes until the facade's unit commits, and a decline sends nothing. The control surface's
  `ratchet` with `reset` now sends through it too, as Android's bridge does (`MeshManager.kt:929`), and settles the
  mesh as every other send does, so the advert's digest cue moves with it.
- **A unit that fails** counts `.storeRefused`. Nothing is delivered, acknowledged or sent, and no chain moves. In
  Kotlin a failed transaction leaves the frame in custody, and nobody re-serves it before it expires. The replay is
  P5a's own:
  - The engine keeps the copy whose unit failed, with the route it came by, and opens that copy again at the next
    sweep (`RatchetReplay`). Custody cannot stand in for it. It keeps the first bytes stored under an id, and after our
    reset a peer re-seals its unacked DMs under their own ids, so for a re-seal custody holds only the seal that could
    not open; a copy handed to us point to point never reached it. For a frame off a link, the sweep's open is its
    first verdict, as every open is in Kotlin. The kept copies die with the process, so at start the engine opens every
    custodied ratchet DM to us that has no row.
  - A copy goes as soon as any copy of its id opens and commits, whatever its origin (`RatchetReplay.forget`). A ctl
    frame never has a row, and its kept copy, opened again past an era change, would apply a second time: a reaction or
    a profile at a later clamp, a reset into the parity path below.
  - The sweep decides the rest by the frame's row, read in a store unit of its own: a row that exists lets the copy
    go, a read the store fails fails the unit and keeps the copy, and with no row the copy opens again. What the row
    check does today is stop a second acknowledgement of a DM delivered before its copy failed, or deleted since; for a
    ctl frame it does nothing, and only `forget` lets one go, once another copy commits after it was kept.
  - An id kept twice keeps the later copy, but an unsigned copy never displaces a signed one. Only the live-link tick
    travels unsigned, under an id of its own, so an unsigned twin of a signed frame is a stripped capture, which would
    be refused at the sweep and lose the frame.
  - The copies live in memory, at most 1,000 and 4 MiB, a memory bound in custody's and the parking lot's units, held
    until the store answers. Past either bound the oldest copy goes first. What becomes of a copy that leaves memory,
    dropped by the cap or dying with the process before a sweep commits it, depends on what custody holds. Where our
    custody holds the frame as it came, the next start opens it with the era held and its first verdict lost. A re-seal
    is lost outright, at Kotlin's level: custody holds only the old seal, and both share a `sentAt`. A frame custody
    never stored comes back by a carrier's back-fill, as a first verdict. A live-link tick is lost, at Kotlin's level:
    its author sends it over the link once and drops it (`AckSync.kt:212`, `:648`), and only our post reaching that
    author again owes a fresh one.
  - The replay calls the chat handler directly, past the router's dedup.
  - A first verdict's id is also let past the router once, so a copy a neighbour's back-fill brings before the sweep
    is not taken for the one already seen. Without that, the router would drop it, and the two custodies would differ
    for the router's ten minutes.
- **The start's replay only delivers** (`RatchetInbound.Origin.startReplay`). Its frames' first verdicts, if they had
  any, came before the restart, and the floors that judged them died with the process.
  - A failure counts under its reason alone: never toward a reset, and with no copy let past the router. Our own
    reset leaves the old era's tail in our custody for a day, and from the 6 h floor on, every restart would otherwise
    buy a reset nothing justifies.
  - The open holds the era (`OpenContext.allowEraChange`, the port's own): an init the held session has not resolved
    neither races nor replaces it, flagged or not, and the frame is read under the roots held. Otherwise a reset our
    custody kept, stamped by a peer whose clock runs ahead, could take us back to a root the pair has left: its stamp is
    compared with ours. With no session held, an init still establishes one.
  - It applies no reaction (ctl 6) and no profile (ctl 8), and commits only the chain's advance for them. Both are
    ordered by a stamp `clampFuture` set at the first open, which a later open cannot reproduce: one first opened from
    a peer running more than five minutes fast would apply again higher and outrank a newer one. Only a reaction or a
    profile whose first verdict never committed is lost that way, as in Kotlin. A receipt (ctl 5) still applies; one
    applied before flips nothing new.
  - A start's replay whose unit fails is kept as one, so the sweep that opens it again gives it no first verdict.
- **The ratchet's sweep runs at start and then every hour** (`RETENTION_SWEEP_MS`, `MeshManager.kt:3510`), with the
  switch on, in a unit of its own and never inside a DM's: the SQL sweep truncates the write-ahead log once it commits,
  and no send may wait behind that checkpoint. A sweep the store refuses is logged and changes nothing else.
- **With the switch off, receiving is as before:** v2 and v3 still drop as `.cannotOpen` and the unsigned tick as
  `.unsigned`, nothing is stored or sent, and the ratchet's tables are not swept.
- **The alternatives, and why not:**
  - **Kotlin's two phases:** moderation runs after the row here, so nothing needs the peek, and one unit cannot race
    itself.
  - **Waiting for a neighbour to re-serve a failed frame:** our digest lists it, so none will.
  - **Replaying custody's copy of a failed frame:** custody keeps the first bytes stored under an id, so a re-seal's
    replay would open the seal that could not open, fail again, and lose the DM.
  - **Re-opening a sender's custodied frames whenever a first verdict moves its era,** for the frame a failed unit and
    a restart left stranded: new machinery for a store failure that spans a restart, where Kotlin re-opens nothing.
  - **Counting a failed unit's frame toward a reset:** the store failed, not the session, so the frame says nothing
    about the pair.
  - **The start's replay with the replacement floor held, and no more:** the race reads no floor
    (`RatchetEngine.kt:544-547`), so an init replayed while our own init is unanswered could still move the era.
  - **Skipping init-bearing frames custody received before the session began:** a responder's `establishedAt` is the
    peer's clock and custody's `receivedAt` is ours, so the two cannot be compared.
- **Limits:**
  - Each start opens every ctl frame still in our custody again. One from the era the pair holds drops as
    `DUPLICATE`. One from an era the pair has since left can open again under that era's draining root, since leaving
    it purged the receive state that spent it, for as long as custody keeps it (24 h). There a receipt flips nothing
    new, a reset's marker applies nothing, and a reaction or a profile applies nothing at all.
  - P5b's re-seal of our unacked DMs follows a reset's committed first verdict, however it opened (a root adopted, a
    race won or lost, a marker under the session held), as Kotlin's does (`InboundPipeline.kt:1137-1148`), and never
    the start's replay.
  - A frame whose unit failed and whose process then died before the sweep has no kept copy, and loses its first
    verdict, which is Kotlin's level. Where our custody holds it as it came, the next start opens it with the era
    held, so a frame that would have moved the era (a peer's flagged reset, a reinstalled peer's first DM) fails
    there. It waits for a start after the peer's next live frame has moved the era, and is lost if none comes within
    custody's 24 h. A re-seal is lost outright, a frame custody never stored comes back by a carrier's back-fill, and
    a live-link tick is lost, since its author sent it once over the link and dropped it. Kotlin re-opens none that its
    custody holds.
  - When P5c seals our receipts, `AndroidPeer.acknowledged`, which reads cleartext receipts, must count sealed ones
    too, in `aKeptFrameDeliveredBeforeTheSweepIsDeliveredOnce` (`forget`) and
    `aKeptCopyOfADMDeliveredBeforeIsLetGoByItsRow` (the row check); neither reads custody.
  - A ctl frame's copy kept after the frame had committed (a re-serve whose unit failed) has no row and no later
    commit to end it. Past an era change the sweep opens it under the draining root: a reaction or a profile from a
    peer more than five minutes fast applies again higher, and a reset meets the parity path below. Kotlin does the
    same with a re-serve that arrives after the era change, and a frame dated more than five minutes ahead is
    re-served until our custody keeps it.
  - A reset we adopted and then re-rooted away from can come back to a first verdict late: a carrier's back-fill after
    our custody refused or evicted it, or the sweep's replay of a failed unit's own first verdict, at most ten minutes
    late. Our re-root's init holds no anchor for it. Until the peer answers our re-root, the race takes it by node id
    (`RatchetEngine.kt:547`) and adopts it when the peer's id is the smaller; after, the replacement rule compares the
    peer's clock with ours (`:548-549`). Either can take us back to the root the pair left. knit-next has the same
    hole; keeping the resolving init's ephemeral for the root we drain, checked ahead of the race, would close it on
    both.
  - With the switch off, sessions made while it was on keep their keys until it is on again, since only then does the
    sweep run.
  - The arm treats a `joined` answer as a failed unit. Nothing opens a unit around the inbound path, so it never gets
    one.
- **Guards:** `MeshEngineRatchetInboundTests`, `MeshEngineRatchetResetTests`, `MeshEngineRatchetEraTests`,
  `MeshEngineRatchetControlTests`, `MeshEngineRatchetProfileTests` and `MeshEngineRatchetUnsignedTests` port
  `InboundPipelineTest`'s receive-side cases by name, beside P5a's own. `MeshEngineRatchetUnitTests` holds the tests the
  P4a reviews owed: a refused row over both store kinds and its replay, an unreadable photo, and the back-fill after a
  failed unit. `MeshEngineRatchetPairTests` covers a reset each way, a race, a reinstall, a re-seal whose unit fails,
  the start's replay and the sweep's schedule. `RatchetSessionsNestingTests` covers a settlement applied only after the
  outer commit, and never after a failure. `RatchetInboundTests` covers the pure rules. `RatchetPipelineVectorTests` and
  `RatchetCarolVectorTests` replay A9's `ctlPlane`, the pipeline's refusals and every frame Carol opens through the
  engine, against Android's own state. `MeshEngineRatchetStartReplayTests` covers the start's replay: a restart past our
  reset's floor with that reset's tail still in custody, a start's replay whose unit fails, a restart within the day of
  a re-root that outran a peer's fast clock, and a fast peer's older reaction and profile opened again after a newer
  one. `RatchetEngineTests`' held-era cases cover the engine's side of it. `MeshEngineRatchetCustodyTests` covers a
  flooded copy delivered from the copy kept, with no carrier serving it again, a sweep that cannot read the row, a kept
  frame delivered before the sweep, and a photo asked for only once its unit commits, each over the database.
  `MeshEngineRatchetKeptCopyTests` covers a kept reaction and a kept profile let go once another copy of theirs commits,
  an unsigned copy that never displaces the signed one, a copy of a DM delivered before let go by its row, the kept hop
  ranking the photo's pull-through, and a kept receipt applied once, over both store kinds. `MeshRatchetTests` pins the
  control surface's reset moving the digest cue.
  `MeshEngineRatchetUnsignedTests.withTheSwitchOffV2AndV3DropUnopenedAndNothingIsStoredOrSent` pins the switch off.

**Amended 2026-10-15, phase P5b (DMs sent in the mesh):**

- **With the switch on, a DM to a peer whose pinned profile carries `CAP_RATCHET` and a bundle is sealed with the
  ratchet** (`MeshEngine+RatchetOutbound.swift`; `sealEnvelopeFor`, `MeshManager.kt:1267-1308`). The pure
  `RatchetOutbound.scheme` decides from the switch, the pinned row and the content:
  - Off, every DM is v1, whatever the peer advertises. The switch-off path is today's code, textually.
  - On, the ratchet takes a DM to a peer with the bit and a bundle: compact v3 when the profile also carries
    `CAP_CRYPTO_V3` and the content has a canonical compact form, else the named v2 layout. A peer without the bit gets
    v1, and a DM waits (`pendingKey`) only for a bundle.
  - On, one read of the peer's pinned row decides, and the v1 arm seals to the bundle that read gave. A read that fails
    (`SQLPeerStore.peer` answers `nil`) leaves the DM waiting, and a flush whose read fails leaves every waiting DM
    waiting. A second read for the v1 arm could find the row the first missed and send a ratchet peer v1, uncounted and
    never upgraded. Kotlin's read throws when it fails, out of `sendChat`, and nothing is sealed (`MeshManager.kt:1290`,
    `PeerRepository.kt:138`).
  - The facade's `unavailable` (no session and no usable prekey, or a new epoch due with no base) and its `refusedKey`
    (a prekey X25519 refuses, which the peer signed: Kotlin throws out of `sendChat`, `:1189`, `:1295`) seal the same
    content v1 to the pinned bundle. It is counted as `dmSealedV1Fallback` and toward nothing else, and that DM is never
    upgraded. An identity key that v1 refuses too, a low-order point, abandons the unit, and the DM waits as today's v1
    send leaves it; Kotlin throws out of `sendChat` there (`:1307`) before it saves the row.
  - The counts are Android's (`MeshMetrics.Seals`): `dmSealedV2` counts every ratchet seal, v3 included, and
    `dmSealedV3` the compact ones. The control surface's `ratchet` reply carries them as `seals`.
- **The send unit.** The row is saved waiting first. Then one store unit, the outermost, seals through `sealDm` joined
  to it, signs the frame once, clears `pendingKey` and takes the frame into our own custody. The joined seal's
  settlement, the router's mark, the transport's send, the count and `.sent` all wait for that unit to commit.
  - A unit that fails leaves the row waiting, nothing on the air and the chain as it was, so no message key goes on a
    frame that never left. The heal seals it again: with the switch on, it flushes the waiting DMs of every pinned peer
    whose profile carries `CAP_RATCHET` (`retryWaitingDirectMessages`), which also sends one whose read of the peer
    failed. The rows are the truth, so a restart loses nothing.
  - Kotlin seals and commits, then saves the row and floods (`MeshManager.kt:1189-1235`). A Room failure there throws
    out of `sendChat`, and a crash between the commit and the flood leaves a chain hole. Here the chain, the cleared flag
    and our custody's copy commit together, and a frame whose unit committed outlives a crash before its send when
    custody keeps it, which serves it at the next digest.
  - The unit's one write in memory is the tombstone `CustodySync.admits` may set for a DM whose recipient's receipt came
    first: idempotent, and the verdict a later `carry` reaches anyway. `StoreTransactor`'s contract names it, so our
    custody's copy stays inside the unit.
  - A send unit opened inside a caller's unit answers `.joined` and sends nothing, since its frame cannot go before an
    outer commit the send never sees. Nothing opens a unit around a send.
  - The v1 path is as it was. With the switch off, or toward a peer without the bit, a DM is sealed, saved and flooded
    as before, from the same draws.
- **The re-seal after a received reset** (`resealRecentDirectMessages`; `resealRecentDmsTo` and `resealAndFlood`,
  `MeshManager.kt:3361-3407`).
  - When a reset's first verdict commits, however its open went (a root adopted, a race won or lost, a marker under the
    session held, `InboundPipeline.kt:1137-1148`), our DMs to that peer from the last day are sealed again under the
    session now held. That takes every one no receipt acknowledged and none still waiting.
  - A kept copy of a reset whose unit failed re-seals when the sweep's open of it commits, since that commit is the
    reset's first committed verdict. Only the start's replay (`RatchetInbound.Origin.startReplay`) never re-seals: it
    opens resets whose first verdict came before the restart and re-sealed then.
  - Each goes in a send unit of its own, under its own id and `sentAt`, sealed from its row, so an attachment keeps its
    name and size (knit-next `0fa6c548`). It signs the id again: one more signature for each committed first verdict
    of a reset from that peer within the day, with no per-id guard, in Kotlin as here (ADR 2026-09.2ved, amended).
  - It flies live. Custody keeps the first bytes stored under an id (`CustodySync.carryOwn`, `ForwardSync.kt:75`), so a
    re-seal is carried only where custody lost the original. A peer whose open of the original failed reopened the id
    at its router, so a re-seal that reaches it gets past it; a peer that holds the message's row meets the re-seal at
    its exists-gate, which acknowledges it without decrypting it.
  - A peer whose pinned profile lacks the bit gets its copies v1, as `sealEnvelopeFor` falls back, and a blocked peer
    gets none. The forced flush of our group seeds that follows a reset in Kotlin is P6's.
- **The switch has its launch paths.**
  - knit-peer's `--ratchet` turns it on, and its `main` loads the prekey ring kept beside the identity
    (`PeerState.loadPrekeys`), so the peer's profile carries the prekey and `0x15F`.
  - A Debug build's `-ratchet on` or `-ratchet off` sets it, and keeps the choice under a Debug-only defaults key,
    `debug.launch.ratchet`, for every launch after it that names none: the launches iOS makes by itself (after an
    install, at the first unlock after a reboot, and presumably a restoration). A running process keeps what its own
    start read, so a `devicectl` launch that brings it forward without `--terminate-existing` changes nothing. With
    neither, it is off, and a value other than `on` or `off` chooses nothing. Argv lasts one process, so a switch read
    from it alone would be off in those launches: the start's `syncPrekey` would republish the profile without the
    prekey, and Android would clear its pin and seal v1.
  - A kept "on" outlives the trial that set it, so every trial ends with `-ratchet off`, launched with
    `--terminate-existing`, and a check that the bridge's `prekeyId` reads null. While it is on, the phone stays out of
    groups whose other members are all Android phones running the ratchet: Android seals those in the group form,
    which this build drops until P6, seeds included.
  - The rule is pure, `LaunchOptions(arguments:storedRatchet:)`. `Launch` reads and keeps the choice as each try
    builds the environment, which succeeds only once protected data can be read. A try that reads the defaults just
    before the first unlock and the Keychain just after builds the mesh with the switch off; the trial's `prekeyId`
    check catches it.
  - A release build reads no argument and keeps nothing (ADR 2026-10.8cy5). Each toggle republishes the profile, as
    the P3 amendment has it.
- **A seam for the vectors:** `MeshEngine` takes the ratchet's engine on an internal initializer, so a replay passes A9's
  draws. The public one passes the system's, and the injected `random` never draws a ratchet key.
- **Decided at review (2026-10-15):** the crypto review accepted the five drifts from Kotlin above (the row saved
  before the unit, `refusedKey` sealed v1, the low-order identity key left waiting, the heal's retry, and `.sent` for a
  first ratchet seal), and the blobs and bluetooth reviews raised no objection. The reviews also settled three
  questions:
  - The heal sends a DM that waited on a ratchet peer we have since unblocked, the frame Android sends at that peer's
    next profile, sooner.
  - A DM to a peer whose identity key is a low-order point stays waiting. Each heal costs one abandoned unit, with
    nothing on the air or in custody.
  - `.sent` stays for a first ratchet seal. It only moves the app's revision, and no harness keys on it.
- **The alternatives, and why not:**
  - **Kotlin's order, seal and commit, then save and flood:** a store that failed after the seal would lose the row
    with the chain moved, and a crash before the flood would leave a frame no custody holds.
  - **The v1 fallback outside the unit, after abandoning it:** a second path to the same frame, with the row's flag and
    custody's copy committed apart.
  - **Retrying a failed send from a memo of failed ids:** a restart forgets the memo, and the rows already say what waits.
  - **A store query of its own for the re-seal's rows:** it would change every message store for a read that runs once
    per reset. The thread's rows, filtered by `RatchetOutbound.isUnacknowledged`, are the same set.
  - **`-ratchet` read from argv alone:** every launch iOS makes would run with the switch off.
- **Limits:**
  - Our acknowledgements stay cleartext until P5c, so a peer that only receives never seals under a session we started,
    and that session stays unconfirmed until the peer writes. Kotlin's sealed ticks confirm it at once. Our epoch
    numbers also climb more slowly than Kotlin's. A reset that restarts our numbering at 1 replaces our epoch 1's key, so
    a peer's frames still sealed on that epoch open only through the peer's re-seal; with sealed ticks they would mostly
    sit on a later epoch. `RatchetSessionLabTests` has a DM stand in for each tick.
  - A re-seal reaches only the nodes it meets live whose router has not seen its id within ten minutes. The reopen is
    the failing peer's alone, a relay that carried the original inside that window drops it, and every custody, the
    peer's included, keeps only the original, as in Kotlin. So a peer two hops away does not read DMs that crossed a
    relay within ten minutes before its reset. Kotlin's `resealRecentDmsTo` doc (`MeshManager.kt:3354-3360`) overclaims
    the same way, and `RatchetResealReachTests` pins the limit at Kotlin's level.
  - A frame whose unit committed survives a crash before its send only when custody keeps it. Custody keeps no DM that
    waited more than a day, which is dead on arrival, none past our 200 newest frames, and none past its 1,000
    newest, so a crash in that window loses such a frame while its row says sent.
  - A re-seal whose read or unit fails is lost, as Kotlin's is when Room throws. Its original drains in custody for its
    day.
  - The re-seal reads the whole DM thread to find its rows, once per reset from that peer.
  - A reset's copy re-opened past an era change as a first verdict (a carrier's back-fill after our custody refused or
    evicted it) re-seals again, as Kotlin's does: the parity path in the P5a amendment.
  - knit-peer compiles on Linux, and was built here. Only `AppEnvironment` and `Launch`, in the Knit target, need the
    Mac.
- **Guards:**
  - `RatchetOutboundTests` holds the pure rules.
  - `MeshEngineRatchetSendTests` ports `MeshManagerTest`'s dispatch and fallback cases by name, and flushes waiting DMs
    to a ratchet peer and to a pre-ratchet build.
  - `MeshEngineRatchetOneReadTests` covers a send and a flush whose read of the peer fails, over both store kinds: the
    DM waits, and the heal or the next flush sends it with the ratchet.
  - `MeshEngineRatchetSendUnitTests` covers a store that fails mid-send over both store kinds, the heal's retry and a send
    nested in a unit that fails, a DM that neither seal takes, and a heal that leaves a peer without the bit alone.
  - `MeshEngineRatchetResealTests` covers the three triggers, a race the iPhone loses, a reset whose unit failed (opened
    at the sweep, or let in again by a neighbour's copy, over both store kinds), the re-seal's set, a file's name and
    size, a peer pinned without the bit, whose copies go v1, a peer it cannot seal to, and a blocked peer.
  - `MeshEngineRatchetSwitchTests` pins the switch off: today's v1 from the same draws, nothing in the ratchet's tables,
    and a peer's reset that seals nothing again.
  - `RatchetSessionsNestingTests.aSealInsideTheCallersUnitIsJoinedAndStandsOnlyWithIt` covers the joined seal.
  - `RatchetSessionLabTests` (`SessionLabTest`'s eight scenarios outside the group form) and `RatchetRestoreLabTests`
    (`RestoreLabTest`'s two) run two engines on `EngineLab`, with the custodies checked after a re-seal. Our cleartext
    receipt purges each re-sealed DM from both custodies, which P5c's sealed receipt will not. `RatchetRestoreLabTests`
    also runs a crash stand-in over the database: a DM whose unit committed while apart goes from custody, in its one
    signature, at the next link.
  - `RatchetResealReachTests` runs three engines in a line for the re-seal's reach.
  - `RatchetSendVectorTests` sends every Alice-side seal of A9's `dm` that the pipeline makes by its rules through her
    engine, and the re-seal pair through two engines. `RatchetCarolVectorTests` sends Carol's DMs through hers.
  - `PeerRatchetTests`, `LaunchRatchetTests` and `MeshControlRatchetTests.theDumpCountsHowOurDMsWereSealed` cover the
    launch paths, the kept choice and the counts.

**Amended 2026-10-15, phase P5c (the tick ledger's sealed form):**

- **`AckSync` is knit-next's ledger whole** (`AckSync.kt` at `cbf2a487`), without the spool, the fast plane and
  `onReachable`. It stays a value that decides, while the engine sends (`MeshEngine+Ticks.swift`).
  - `owe`'s three-way rule is Kotlin's, keyed on `escalatable` (`InboundPipeline.kt:2857`). A linked author gets one
    tick over its link. An absent author who could read a sealed one gets the escalation batch for a group's tick, or
    the ride hold for a room's. Any other keeps the cleartext entry it had. A commons post would escalate too, and no
    radio delivers one here.
  - The caps, the 24 h TTL and the eviction are Kotlin's (`OWED_CAP`, `PENDING_CAP`, `ESCALATED_CAP`,
    `MAX_BATCH_ACKS`). Where Kotlin's hash maps leave an order to chance, the oldest stamp goes first, and ties go by
    arrival or by node id, so every run repeats.
  - One difference from the ledger before P5c, and one from Kotlin's. First, `owe` makes room at the cap before it
    takes any fresh entry, a linked author's included, as Kotlin does (`AckSync.kt:184-188`); the old ledger sent a
    linked author's tick and kept nothing. So at 500 owed entries, a tick to a linked author drops an absent author's
    oldest owed tick, as on Android. That is the one change on the air with the seams as shipped. Second, the four
    entry points that send (`owe`, `linked`, `retryPending`, `flushDueBatches`) sweep first, as the old ledger's two
    did, where Kotlin's `onNeighborAdded` and its debounce wake do not, so a tick past its day never goes. The riders'
    `takeRiding`, `giveBackRiding` and `rode` sweep nothing, as in Kotlin; the engine's ten-minute sweep bounds them.
- **The seams are `TickSealing`'s three**, which the engine holds as `tickSeals` (`MeshManager.kt:380-382`):
  - `canSeal`, whether an author could read a sealed tick (`:2066-2069`);
  - `sealTick`, one sealed tick signed `relay = false` for a live link (`:1925-1931`);
  - `originateTick`, one sealed tick flooded and carried, answering whether it went (`:1939-1959`).

  This build's are `NoTickSealing`: no author can read a sealed tick, so with the switch off or on every tick on the
  air is today's, but for the cap's edge above. P5d fills them under the contract the protocol's doc sets:
  - each answers "cannot seal" by itself with the switch off, since the ledger asks `sealTick` without `canSeal`;
  - each seals in a store unit of its own, the outermost, and answers only once that unit commits;
  - the fallback is the cleartext tick, never v1;
  - no seam touches the ledger, and `originateTick` takes no riders.
- **The riders are the ledger's to take.** A sealed batch carries its author's waiting room ticks, up to 64 ids in
  all, as `originateDeliveryTick` does (`MeshManager.kt:1948-1957`). The ledger takes them before it calls the seam, and
  gives them back if the seal fails. A seam that called back into the ledger would overlap the ledger's own access.
- **No back-off.** Kotlin's send toward an author with no link is `fastSend`, which on Bluetooth writes only to that
  author's own link (`BluetoothMeshTransport.kt:706-716`).
  - So here an owed tick, sealed or cleartext, goes only over a live link: at link-up, at the 60 s re-offer or at the
    heal. A sealed entry's bytes go once, over the link that ends it.
  - The doubling back-off that paces Kotlin's best-effort re-sends (knit-next ADRs 053 and 2026-09.6gk8) has nothing to
    pace here. On a phone with Bluetooth alone, Android's paces nothing on the air either.
- **The debounce is an engine deadline** (`AckSync.nextBatchDue`, ADR 2026-09.gq84). Kotlin arms a coroutine, and keeps
  the heal for a wake that died.
  - The heal alone would hold a batch out of custody for up to 15 minutes, where Kotlin's goes in 45 s. The ride hold's
    60 s is set above the batch's 45 s debounce (Kotlin's LoRa DM hold is the other 45 s hold it clears), so that a
    batch sealed in the same minute carries the room's ticks first
    (`AckSync.kt:772-777`).
  - The deadline costs nothing while no batch waits, which is always until P5d.
  - The ride hold has no deadline here. Its routes are the spool and the fast plane, so a due ride keeps waiting for a
    link or a carrier, and the heal's pass sends one over a link it finds.
- **The alternatives, and why not:**
  - **The seams as closures the ledger stores:** the ledger would capture the engine, a cycle, and stop being a value.
  - **A two-phase ledger that decides, then hears what the seal did:** each decision Kotlin makes around a seal would
    split in two, and the port would no longer read line for line against `AckSync.kt`.
  - **The back-off kept as state:** it would gate an attempt that sends nothing, and no test could see it.
  - **The heal alone for the debounce:** above.
- **Decided at review (2026-10-15):** the blobs and crypto reviews confirmed the four decisions above: the back-off left
  out, the debounce as an engine deadline, no deadline on the ride hold, and the riders the ledger's. They also settled
  two questions:
  - A ride hold that goes over a link stays one tick, as in Kotlin (Limits, below). Cutting it into ticks is a change on
    the sender alone, for knit-next to make and both platforms to take.
  - The footprint keeps its keys. `owedTicks` counts the owed entries and both holds. The escalated ids, trimmed to
    1,000, and the lent stamps, bounded by the holds, stay out of it, since a new key would break `PeerNodeTests`'
    pinned list.
- **Limits:**
  - A ride hold that goes over a link goes as one sealed tick, however many ids it holds, as Kotlin's
    `flushBatchOverLink` does, and a receiver applies at most 128 ids from one. A hold of more loses the rest of its
    ticks at the author, on both platforms. Kotlin cuts a hold into ticks only on the deadline's routes.
  - The ledger lives in memory, as Kotlin's does. A restart forgets its holds and its escalated ids, so a message
    re-served after one owes again, and may cost one more batch, which the author applies idempotently.
  - knit-next #96 still applies: a tick written to a link that died before the write is lost, not owed again.
  - The sealing that the P5a and P5b amendments name for P5c is now P5d's: the seams' seals, the sealed DM receipt,
    which drops our self-purge, and inline acks. P5e seals reactions, `CTL_PROFILE` and an init's answer.
- **Guards:**
  - `AckSyncTests` and `AckSyncRideDeadlineTests` account for `AckSyncTest`'s 26 cases and
    `AckSyncRideDeadlineTest`'s 10 by name. They port 24 and 3, and each suite's doc names the cases left to the spool
    and the fast plane: two of the first, seven of the second.
  - `AckSyncOwedTests` and `AckSyncBoundsTests` hold this port's: the riders, the caps and the order they evict in, with
    a linked author's tick at the cap among them.
  - `MeshEngineTickTests.withTheSeamsAsShippedEveryTickIsTodaysCleartext` pins today's bytes with the switch off and on.
    The rest of the suite runs the seams faked to seal over the engine (`EngineSeals`).
  - `TickLabTests` runs three engines in a line:
    - a group's tick reaching an absent author from a carrier's custody, at the link-up after it went;
    - the same tick relayed by the carrier while the author is linked to it;
    - a room's tick never carried;
    - with the shipped seams, every tick waiting for the link.
  - A group open keeps `acknowledge` in its post-commit half, as `announce` does: a standing rule for P6, which opens
    group messages inside a unit.
