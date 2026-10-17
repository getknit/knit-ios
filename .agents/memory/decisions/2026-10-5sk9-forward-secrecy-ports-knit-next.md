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

**Amended 2026-10-16, phase P5d (receipts and ticks sealed):**

- **With the switch on, our acknowledgements take Android's sealed form toward an author who can read one**
  (`MeshEngine+RatchetReceipts.swift`; `sealDmReceipt`, `InboundPipeline.kt:2895-2958`; `sealDeliveryTickEnvelope`,
  `sealDeliveryTick`, `originateDeliveryTick` and `canSealTickTo`, `MeshManager.kt:1859-1966` and `:2066-2069`, at
  knit-next `cbf2a487`).
  - One read of the pinned row decides who can read one: `CAP_RATCHET` and a bundle that decodes, and no prekey, as
    `canSealTickTo` reads it (`RatchetOutbound.receiptPlan`). The switch comes first. A DM's receipt reads the row
    inside its seal's unit, so a read that fails fails the unit; a tick's seam reads it just before.
  - Each is a `CTL_RECEIPT` DM to the author under a fresh id and `sentAt` now, both drawn inside the unit once the row
    is read, as Kotlin draws them after its read. It is compact when the profile reads v3 and every id it names is
    canonical, else v2. A tick names one id in `ack` and a batch in `acks`. A DM's receipt names the DM in `ack` and
    the room ticks riding it in `acks`.
  - The live-link tick is signed `relay = false` and never carried. Kotlin sends a v3 one unsigned (ADR 059), and this
    port sends nothing unsigned, as the decision above has it. The group's escalated batch and the DM's receipt are
    originated: signed `relay = true`, taken into our custody inside the seal's unit, and flooded after it.
  - Each seal stands in a store unit of its own, the outermost, with `sealDm` joined to it. It answers the wire or
    `true` only once that unit commits, and settles after. A unit that fails or is abandoned, and a facade that cannot
    seal, write nothing and put nothing sealed on the air. The fallback is the cleartext receipt or tick, never v1,
    which a build without the ratchet would store as an empty bubble (`InboundPipeline.kt:2898-2900`).
  - A seal asked for inside a unit its caller opened joins that unit. It puts nothing on the air then, but its chain
    advance, and for an originated form its custody row, stand or fall with that unit. If the outer unit commits, the
    frame stands in our custody unflooded and unmarked, and the next custody exchange serves it. A joined
    `originateTick` answers `false` all the same, so the ledger also keeps the ids as cleartext entries, and that tick
    goes in both forms. No key is used twice, since the advance commits with the frame. Nothing opens a unit around
    these calls today, and the standing rule for P6 keeps `acknowledge` out of one.
  - No blocked gate on a tick (`MeshManager.kt:1863-1865`). A blocked sender's DM is never delivered, so it earns no
    receipt of either form.
- **The sealed DM receipt drops our self-purge** (ADR 2026-09.p6nb, amended). Carriers cannot read it, so the DM stays
  in every custody, ours included, to its TTL. While our custody holds it, our digest lists it, so no neighbour's
  back-fill serves it to us. A copy still reaches us two ways, and each past the router's window is answered with one
  more sealed receipt, as Kotlin does (`InboundPipeline.kt:946-955`). Our quotas may evict it first, and then every
  holder next to us serves it. Or a node that lacks it and links to two holders (a returning phone's or a newcomer's
  back-fill, or a carrier whose quota evicted it) relays the first copy it gets to the other holder before that holder's
  own copy crosses: a served frame floods on (`ForwardSync.kt:14-15`), a serve stamps nothing in the server's seen set,
  and every node it reaches past its router window relays it on, holders included (`MeshEngine.swift:225-237`,
  `MeshRouter.kt:113-114`). So the recipient answers that copy wherever the re-flood finds it, though it still holds the
  DM. The P5c crypto review traced the alternative: our custody purging a DM every carrier keeps would have our digest
  omit it for its whole day, a carrier re-serve it every ten minutes past the router, and the exists-gate answer each
  copy with a new sealed receipt, about 144 a day for every delivered DM. An author who cannot read one and a facade
  that cannot seal get the cleartext receipt, which still purges and self-vaccinates. Every receipt goes at once:
  Kotlin's LoRa hold of a DM's receipt (`DmAckCoalescer`) has no plane here.
- **A store that fails sends no receipt,** sealed or cleartext, as Kotlin's throw out of `sealDmReceipt` sends none
  (`PeerRepository.kt:138`, `RatchetSessions.kt:50`, `:247`, `:259`, swallowed at `InboundPipeline.kt:304`). That holds
  for a failed read of the author's row and for a seal's unit that answers `.failed` (`SealedReceiptAttempt.failed`):
  nothing is purged, and the riders go back. That DM's ✓✓ waits until a copy reaches us again, as after Kotlin's throw:
  our digest lists the DM, so only the two paths above bring one. A tick whose seal fails on a store keeps its cleartext
  entry, as P5c has it, since a cleartext tick purges nothing; Kotlin's throw sends none there either.
- **The engine holds `RatchetTickSeals`, the seams `AckSync` asks, whatever the switch says.** Each answers "cannot
  seal" by itself with the switch off, since the ledger asks `sealTick` without `canSeal`. `NoTickSealing` is gone. The
  alternative, `NoTickSealing` held with the switch off, would leave the seams' own gate untested by any engine.
- **Riders.** Room ticks waiting for a ride toward an author cross on two more frames sealed to it anyway: up to eleven
  on its DM's receipt (`DmAckCoalescer.MAX_LORA_TICK_ACKS - 1`, `InboundPipeline.kt:2924`), and up to four inline on our
  DM's first seal toward a profile carrying `CAP_INLINE_ACK`, within Kotlin's LoRa body budget for that DM
  (`inlineAcksFor` and `LoraSizeHint`, `MeshManager.kt:2004-2026`). Inline acks ride the ratchet's plaintext only, never
  the v1 fallback, and never a flush or a re-seal, as in Kotlin. Each carrier takes them before its unit, and within the
  same call says they rode only once its unit commits with a ratchet seal, or gives them back with their stamps. The
  seams take none: the ledger takes a batch's. This port has no DM coalescer, so only room ticks ride.
- **A receipt asked for inside a caller's unit sends nothing then,** sealed or cleartext
  (`SealedReceiptAttempt.heldBack`), and gives its riders back. If that unit commits, the joined seal's receipt still
  goes at the next exchange, as above, carrying the riders it gave back, which the author then applies twice,
  idempotently. Nothing asks for one there; a group open in a unit must keep `acknowledge` in its post-commit half (P6).
- **The replay's keep-and-drop rule needs no change.** A kept copy's DM delivered another way stays in our custody now,
  and neither the sweep, which lets the copy go by its row or by `forget`, nor the start's replay, which skips a DM with
  a row, acknowledges it again.
- **The counts.** `RatchetSealCounts` stays the DMs': Kotlin also counts a v3 receipt or tick in `dmSealedV3`, and this
  port does not, so a trial's `dmSealedV3 >= 1` still means a v3 DM. The receipts get Android's own counters
  (`MeshMetrics.Receipts`, as `RatchetReceiptCounts`), counted where Kotlin counts them and reported in the control
  surface's `ratchet` reply beside `seals`, not in the footprint, whose keys `PeerNodeTests` pins:
  - `receiptsSealed`, each committed seal of a receipt or tick;
  - `receiptsSealedFallback`, each seal the facade could not make toward an author who could read one, a store's
    failure not counted, as Kotlin's throw counts nothing;
  - `receiptsCustodied`, each escalated batch;
  - `receiptsRidden`, each room tick that rode, which the ledger counts in `rode`, the one call every carrier makes, as
    Kotlin calls `onReceiptRidden` beside each `rode`.

  The other four are left out: `receiptsCoalesced`, `receiptsSpooled` and `ticksUnsigned` have no plane or form here,
  and `receiptsResent` counts the ledger's re-sends, which this port leaves uncounted.
- **A9.** Carol's ticks are the sealed receipts her engine makes as it opens, checked byte for byte under the frame ids
  Kotlin's pipeline minted, which the replay hands her engine. `ctlPlane`'s Bob acknowledges sealed, and the state is
  compared on what his opens leave, since the file lists none of his seals. The `dm` send replay lists no receiver's
  ack-back, so while an engine opens a plain DM there the peer's row reads as a build without the ratchet.
- **Decided at review (2026-10-16):**
  - The crypto and blobs reviews split on a store that fails. The crypto review preferred the cleartext receipt, which
    shows carriers one delivery during a store failure, as every author without the bit already gets, and purges
    uniformly. The blobs review preferred Kotlin's posture, since the cleartext receipt's own purge reads the store that
    just failed, and a purge that misses leaves our custody serving a DM every carrier purged. The caller chose parity
    with Kotlin, above.
  - Both reviews accepted merging P5d dark with the reinstall race pinned, on condition that the roadmap names both of
    its orderings and blocks the flip on them. The switch is off by default, and Release builds cannot turn it on (ADR
    2026-10.8cy5). The fix waits for the maintainer.
  - Accepted as written: `dmSealedV3` left to the DMs; the receipt asked for inside a unit, with the correction above;
    the `dm` replay's peer row read without `CAP_RATCHET`; and a reinstalled node's heuristic firing sooner, since the
    peer's carried ctl frames count toward its three failures, which makes the race the likelier ordering.
  - The receipt counters went in because a trial needs them: the soak's oracle reads our sealed receipts against the DMs
    delivered.
  - The re-reviews found more, stated here and on the roadmap. A back-fill fed by two holders reaches a recipient that
    still holds the DM, so the re-ack has a second path, and its re-flood reaches the recipient anywhere the flood
    goes; both are pinned at Kotlin's level. The candidate fix for the reinstall's opener closes the lost DMs but, when
    the node's id is the larger, not the split, unless it also sends a flagged reset at once. A room tick the node seals
    before the opener lands can hold that reset back, and the roadmap names the guard's two options for the
    maintainer.
- **The alternatives, and why not:**
  - **The receipt's row read before its unit:** a read that fails there answers as if no row were pinned, so the
    cleartext receipt and its purge would go during a store failure.
  - **A seal refused when a unit is open:** it needs a query on `StoreTransactor`, for calls nothing makes inside a
    unit.
- **Limits:**
  - **A reinstall gets the last day's DMs back from custody,** since nothing purges them, and a responder also gets its
    peer's opener, the DM its init rode. That opener breaks the pair in either order it can come in. Both orderings
    are pinned as known issues in `RatchetRestoreLabTests`, and both block the flip. The roadmap holds the candidate
    fix and the second half it needs, for the maintainer (`.agents/memory/roadmap.md`).
    - **The opener before the reset.** After a short history, fewer than three failing frames come ahead of it in the
      back-fill, so the opener lands before any reset. `establish` answers it with the prekey the Keychain kept and
      rebuilds the old root as a fresh responder with `sendEpoch` 0 (`RatchetEngine.kt:56`, `:519-533`), and the node's
      next seal mints its epoch 1 again under a new key (`:837`). The peer's `climb` finds its row for that epoch on
      that root, so no fresh derivation runs: what falls below its cursor drops as `DUPLICATE`, never counted, and the
      rest fails on the old chain. The pair heals only through a reset at either side's third failure, after silent
      drops: the peer's frames fail at the node too. Only the reset's receiver re-seals. If the peer resets, a DM it
      dropped as a duplicate is lost when the re-seal comes within the router's ten minutes of it, since a `DUPLICATE`
      reopens nothing and the peer's custody holds the copy it cannot open. If the node resets first, nothing re-seals
      its own DMs, and every one the peer dropped is lost for its day. The node's receipt for the opener is lost either
      way, since a ctl frame is never re-sealed, which costs the opener's ✓✓ nothing when the first install's receipt
      reached the peer, as in the lab. In the lab, the node's receipt for the opener and its first DM drop as
      duplicates, and its second DM fails; the peer's two DMs then give the node its third failure, so the node resets
      first and its own DMs never read.
    - **A room post between.** A peer that posted in the room after its opener has the node tick that post before the
      opener lands, since the back-fill serves newest first, and the sealed live tick starts a session with a plain init
      (`sealLiveTick`, then `sealDm`). When the node's id is the smaller, its init wins the race at the node and the
      peer takes it as a replacement, so the pair heals with no reset. When it is the larger, the peer's remnant guard
      refuses the init and reads its frames read-only, the opener wins the race at the node, and the pair breaks as
      above. The lab pins both orders, the larger as the known issue.
    - **The opener after the reset.** Custody serves newest first, so with a longer history the opener comes after the
      third failure has reset the pair. It then meets the node's unanswered reset in the race, which goes by node id
      alone (`RatchetEngine.kt:547`, `:653-705`) before the stale-init check (`:549`). When the peer's id is the
      smaller, the reinstalled node takes the old root back while the peer adopts the reset, which is exempt from the
      remnant guard (`:560-570`, knit-next ADR 024). Each then reads the other under the root it keeps draining, era
      effects stop, and the split lasts until those roots expire after two days.
    - Kotlin has the same rules and never meets either, because its restore keeps the message rows and its exists-gate
      stops the opener; its clear-data mints a new identity. Only an iOS reinstall keeps the identity and prekeys and
      loses the rows. The rules are shared, so knit-next should check its restore.
  - A delivered DM earns one more sealed receipt in each router window in which a copy reaches its recipient: from our
    own eviction, or from a re-flood. Any node that takes a served copy from one holder while linked to another sends it
    on, and every holder past its window relays it, so a phone returning next to two holders can buy one more receipt
    for each delivered DM it takes, from that DM's recipient anywhere the flood reaches. That is up to about 144 in a
    DM's day, more if 4,096 ids churn through a seen set first, each flooded and carried for a day and taking a row in
    the acker's 200, as in Kotlin. Bounding the re-ack is knit-next #176's, for both platforms to take (the roadmap).
  - A re-sealed DM's receiver keeps whichever seal reached its custody first, and its sender the original: one id, two
    sets of bytes on two nodes, which the digests, comparing ids, do not see. Kotlin does the same.
  - A receipt or tick for an id the compact codec cannot carry goes v2
    (`aTickAckingANonCanonicalIdToAV3AuthorFallsBackToV2`).
  - A ride hold or a batch flushed over a link is one tick however many ids it holds (the P5c limit), and a live-link
    tick carries no riders, as Kotlin's `sealDeliveryTick` takes none.
- **Guards:**
  - `MeshEngineSealedReceiptTests`: `InboundPipelineTest`'s receipt cases by name, the prekey path, a facade that cannot
    seal, a store failure over both store kinds in the seal's unit and in the row's read, a receipt asked for inside a
    unit that is abandoned and one that commits, and a blocked sender.
  - `MeshEngineSealedTickTests`: `MeshManagerTest`'s tick cases by name, a seal the facade cannot make, and a store
    failure over both store kinds. `MeshEngineSealedTickUnitTests`: each seam inside a unit that is abandoned and one
    that commits, and a batch due inside a committed unit going in both forms.
  - `MeshEngineInlineAckTests`: `MeshManagerTest`'s inline cases, a failed unit over both store kinds, the heal's flush
    and the re-seal carrying none, and the budget. `RatchetOutboundTests`' P5d cases.
  - `MeshEngineTickTests.withTheSwitchOffEveryTickTowardARatchetAndroidIsTodaysCleartext` and
    `MeshEngineRatchetSwitchTests.withTheSwitchOffReceiptsAndTicksTowardARatchetAndroidAreTodays`: the switch off, the
    real seams, an Android peer with `0x15F` and a signed prekey, frame for frame against today's from the same draws.
  - Engines on both ends: `TickLabTests.aSealedGroupTickReachesAnAbsentAuthorFromACarriersCustodyAndFlipsEachTick`, with
    Carol's one point-to-point serve and all three custodies compared; `SealedReceiptLabTests`, with no second receipt
    past the router's window, the quota eviction's one receipt per window, and one more receipt from a two-holder
    back-fill, next to the recipient or two hops from it; `RatchetRestoreLabTests`' pinned orderings, the opener-first
    one in both node-id orders, with and without a room post the node ticks before the opener lands.
  - `RatchetCarolVectorTests`: A9's Carol ticks byte for byte.
  - `MeshControlRatchetTests.theDumpCountsOurReceiptsUnderAndroidsNames`: the reply's keys.

**Amended 2026-10-16, phase P5e (the presentation plane sealed):**

- **With the switch on, the rest of the DM ctl plane we send is sealed** (`MeshEngine+RatchetPresentation.swift`, at knit-next
  `cbf2a487`: `sendReaction`, `sealReaction` and `sealDmReaction`, `MeshManager.kt:2174-2276`; `broadcastSealedProfile`,
  `currentProfilePayload` and `sendCtlDm`, `:2812-2951`; IntroSync's answer half, `IntroSync.kt:97-115`, `:185-196`,
  `:221-240` and `:352`, wired at `MeshManager.kt:345-355` and `:517-519`).
  - **A reaction in a DM** with a peer whose pinned row carries `CAP_RATCHET` and a bundle goes as a `CTL_REACTION`, never
    the cleartext frame and never v1. The row is applied first, as today, and the frame carries the row's stamp, which last
    writer wins compares on both phones. The room's reaction always goes as the cleartext frame. Toward a peer who cannot
    read one, and when the facade cannot seal, the cleartext frame goes, counted. A store that fails sends neither, as
    Kotlin's throw sends neither, and the row stays applied.
  - **Our sealed profile,** the presentation at our version and never the key or the prekey, goes beside the cleartext
    profile, never instead of it, to every peer we hold a confirmed session with. It goes after each edit of what we present
    (`publishEdit`, as `watchProfileChanges` follows `broadcastProfile`, `:2687-2688`) and at each heal, after the republish
    (`:974`). It is deduped per peer and version in memory, seeded at start and marked by a sealed answer (decided 11 and
    12), goes to nobody at version 0, and carries our photo's hash beside the seal, the hash alone (knit-next ADR 035). A
    photo's edit queues the photo's push on every link before it (decided 13).
  - **The answer an init is owed.** A frame whose header still carries its sender's init, opened and committed as its first
    verdict, is answered with our sealed profile at our current version, version 0 included: once per init, again only after
    an hour, and once more for an init marked as a reset (knit-next #87). The answer needs a verified prekey pinned beside
    the bits (`canSeal`, `:345`), so an init that opens before one pins is owed. The answer goes when such a profile pins,
    before the frames parked for it land, and a profile without the ratchet forgives the debt (knit-next `937cf785`). It
    bypasses the fan-out's dedupe, as `sendIntroTo` does, and once sealed marks it (decided 12). The intro send half
    (contact cards, `pending`, `grace`, the spool's pair scopes) waits for Contacts.
- **Every ctl of ours takes one seal** (`sealControl`, `MeshEngine+RatchetControlSeal.swift`): P5d's, lifted, with a stamp
  and a cleartext hash added. It runs in a store unit of its own, the outermost. The peer's row is read inside it, `sealDm`
  joins it, and the frame is signed once and carried inside it, then marked and flooded after `.committed`. `.joined`,
  `.failed` and `.abandoned` put nothing on the air. A9's Carol ticks still seal byte for byte.
- **The target set** is the confirmed sessions, which `RatchetSessions.confirmedPeers` reads in a unit of its own over
  `RatchetStore.sessionPeerIds`, Kotlin's (`RatchetStore.kt:20`, `RatchetDao.kt:24-25`), in node id order on both stores.
  There is no schema change.
- **The counts** are Android's. `reactionsSealed` and `reactionsSealedFallback` join `RatchetSealCounts`, which now holds all
  five of `MeshMetrics.Seals`. `introsAnswered`, the one of `MeshMetrics.Keys` this port counts, is `RatchetAnswerCounts`. The
  control surface's `ratchet` reply carries them in `seals` and in a new `answers`.
- **Decided:**
  1. Only a first verdict is answered, never the start's replay, which only delivers, as Kotlin answers only in its
     commit and never re-opens its custody. A frame from the era we hold whose first verdict committed drops at the
     start's replay as `DUPLICATE`, so none is answered twice. The frames that open there and deliver are the ones a
     failed unit or a closed switch left unread: their first verdict never committed, and none was answered. Each is
     left to its sender's next frame or to our first frame under the session, so the initiator stays unconfirmed that
     much longer, up to its re-send floor when its only frame was a ctl (an Android contact card's is 20 h,
     `IntroSync.kt:349`, which reaches this port only after the flip). That is no worse than Kotlin. An answer owed when
     the process ends dies with it, as Kotlin's floors and debts do (`IntroSync.kt:97-115`).
  2. A store that fails, and a seal asked for inside a caller's unit, send nothing and keep the debt owed with no floor.
     Kotlin keeps the debt when its `canSeal` throws, but a throw out of `sendIntro` sets the floor and loses the answer
     for the hour. One unit that reads and seals cannot tell the two apart, so the debt is kept. A seal the facade could
     not make toward a peer who could read one drops the debt and the floor together, as Kotlin's failed send does
     (`IntroSync.kt:239`).
  3. The answer's floor runs on our monotonic clock, where Kotlin's reads the wall clock. It compares only our own stamps.
  4. A group's reaction goes in the clear and counts nothing until P6b seals the group form. That is a drift from
     Kotlin, which seals it when every member can read one and counts a fallback when not (`:2189`, `:2227-2247`).
  5. `dmSealedV3` stays the DMs' count. Kotlin counts a v3 reaction or profile there too (`:2263`, `:2930`), so a trial's
     `dmSealedV3 >= 1` still means a v3 DM.
  6. The fan-out runs after an edit of what we present and at each heal. A prekey's edit waits for the next heal, which
     is how Kotlin's rotation reaches its sessions too.
  7. `sessionPeerIds` is ported, for the fan-out alone.
  8. `MeshEngine.presentation.answersInits` is the A9 replays' seam: internal, on by default, as the internal
     `ratchetEngine:` initializer is. The file comes from Kotlin's pipeline alone, which wires no answer
     (`onPeerFrameOpened`'s default, `InboundPipeline.kt:206`), so a replay turns it off to seal the file's frames byte for
     byte. Nothing outside KnitMesh can turn answers off.
  9. The reply's `seals` keys and its `answers` are additive.
  10. A reaction's frame carries its row's stamp while its seal runs on our clock, as a re-seal keeps its frame's `sentAt`
      (P5b).
  11. A relaunch re-sends nothing, a deliberate difference from Kotlin. `start()` seeds the fan-out's dedupe with our
      profile's version as the last run left it, for every confirmed session (`seedSealedProfileVersions`), before the
      prekey's sync, so a rotation due at start is still sent at the next heal. Kotlin's `sentProfileVersions` starts
      empty, so its first heal after a restart sends the version to every session once more (`MeshManager.kt:2836-2838`),
      and the iPhone relaunches to restore Bluetooth far more often than Android's foreground service restarts (ADR
      2026-10.mueg). The seed forgoes a sealed copy for a session that confirmed after the last fan-out to it, or that a
      failed seal left owed. That session takes the version from the cleartext profile, which reaches everyone and which
      both writers order on the version alone (`InboundPipeline.kt:1346-1349`, `:3285-3287`), and this port has no spool
      where only the sealed copy would reach. A store that cannot list the sessions seeds nothing, and the first heal
      sends the version once more, as Kotlin's does. This cut and 12 give up Kotlin's heal copy as a second confirmer of
      an unconfirmed initiator, so such an initiator confirms on our answer to its next init-bearing frame: after the
      floor within a run, at once after a relaunch.
  12. A sealed answer marks the fan-out's dedupe with the version it carried. Kotlin's `sendIntroTo` leaves it alone
      (`:2883`), so its next heal sends the same version again; the answer is that version's sealed profile, so here the
      heal owes the peer nothing more of it. An answer that is lost is given again at the init's floor while the init
      still rides. A deliberate difference, for the reason 11 gives.
  13. A photo's edit pushes before the sealed copies, as Kotlin's `broadcastProfile` pushes before
      `watchProfileChanges` runs `broadcastSealedProfile` (`:2787`, `:2687-2688`). `setAvatar` floods the cleartext
      profile, queues the photo's push on every link, and only then fans out the sealed profile. A link sends a file
      behind the frames written before it, so on a link with no file streaming each neighbour has the push's header
      before a sealed copy names the hash in the clear, which an Android carrier would otherwise want and query for while
      the push sat queued (`InboundPipeline.onCarriedFrame`, `:2050-2067`). Behind a file already streaming, the push
      waits for that file's END while the sealed copy goes between its chunks, as on Android, and the carrier's query is
      answered SENDING from the queue. The first cut of P5e fanned out inside the edit, ahead of the push.
- **With the switch off** nothing changes on the air: a reaction is today's cleartext frame from the same draws, and nothing
  seals, answers or reads the ratchet's tables.
- **Claims.** With the switch on, a DM's reaction leaves the clear. Our presentation also goes sealed to each confirmed
  session, but the cleartext profile still floods our name, status and photo's hash to everyone, that session's peer
  included, so none of it leaves the clear. Kotlin's doc says the sealed copy takes them off the cleartext plane
  (`MeshManager.kt:2819-2820`), which over-claims in the same way. A sealed profile carries our photo's hash beside the
  seal, as Android's does, so a carrier can tell it from other sealed frames when we have a photo. Every shipped build
  still sends its reactions in the clear, as ADR 2026-10.ehe6 says, until the flip.
- **The alternatives, and why not:**
  - **Answering from the start's replay as well:** frames from the era we hold drop there as `DUPLICATE`, so it would
    answer the inits a failed unit or a closed switch left unread, and add at most one answer per init from an era the
    pair has since left, under the floor. Neither rule is worse than Kotlin's; this one keeps the replay a delivery, as
    Kotlin answers in its commit alone.
  - **Kotlin's dedupe as it is,** empty at each start and left alone by an answer: each relaunch's first heal would add
    a row of ours per confirmed session to every custody in reach, and each new session one more.
  - **The dedupe kept in the database:** it would send only the copies the seed forgoes, which present nothing the
    cleartext profile does not, at the cost of a table on both store kinds and a write in every seal's unit.
  - **The debt dropped on a store failure, as Kotlin's `sendIntro` throw drops it:** a store that fails for a moment would
    cost the answer for the hour.
  - **The fan-out over every pinned ratchet peer:** a unit for each at every heal, where one read lists the sessions.
  - **A group's cleartext reaction counted as a fallback now:** the count would say a seal was tried, and none is until P6b.
- **Limits:**
  - **The reinstall race fails another way** (the P5d limits). With a room post between and the node's id the larger,
    `RatchetRestoreLabTests` still records the known issue, since its pin is the fix's oracle, but answers change how the
    pair fails. The node answers the stale opener's init, which drops at the peer as a duplicate and shifts the node's next
    frames one index, so its receipt and its two DMs are three `AEAD_FAIL`s and the peer resets. The node drops the peer's
    reset as `DUPLICATE`: it lands inside the node's flagged-replacement floor and is read under the held root, where se=1
    n=0 is spent (the crypto reviewer's shape 17). The peer answers the node's tick init, one more failure at the node,
    whose heuristic resets. The peer takes that reset's first verdict, keeping its own reset's root, which wins the race as
    the smaller id, and re-seals its DMs, which the node reads once it adopts that root. The sessions agree on the peer's
    new root, but the node's two DMs are lost, since nothing re-seals them. Of the pin's expectations, `:207` now passes,
    `:215` now fails, and `:206` fails as before (`.agents/memory/roadmap.md`).
  - **Two resets apart, in two orders, are knit-next #89's.** Both rules are Kotlin's, the fix is knit-next's to choose,
    and the port follows. `RatchetSessionLabTests.bothResetWithinASecondAndEachAnswersTheOthersFlaggedInit` pins both
    orders as known issues (`.agents/memory/roadmap.md`). A meeting where both resets come by back-fill converges in both
    orders.
    - **The larger id's reset dated first and landing last loses the smaller id's pre-reset DMs** (the order the
      maintainer's note_766 posts on #89). The smaller id's reset, written just before they meet, crosses the new link
      live, while the larger id's comes by back-fill. The larger id loses the race, and its `prevRoot` becomes its own
      reset's root (`RatchetEngine.kt:655-700`, `:668-670`), so it can no longer open the smaller id's DMs sealed before
      the resets. Its answer and re-seals reach the smaller id first and confirm it in its newer era. The larger id's
      reset, whose init is older than that era, then gets no first verdict (`RatchetEngine.kt:547-549`), so the smaller
      id never re-seals those DMs: they are lost for their day, with no ✓✓. The pair still agrees on the smaller id's
      root, each side sent one reset, and nothing resets again. The candidate remedies are a reset's sender re-sealing
      once its reset is answered, or a flagged init we cannot open counting as the peer's reset for re-sealing.
    - **The smaller id's reset dated first splits the pair** (#89's own order, the defection). Both reset while apart,
      the smaller id's reset dated first. The larger id loses the race on it and answers at once, and the smaller id
      confirms on that answer. The larger id's reset then lands, newer than the smaller id's era, and `FLAG_RESET`
      exempts it from the remnant guard (`RatchetEngine.kt:560-570`, `:574-594`; the port's
      `RatchetEngine+Resolve.swift:72`, `:137-140`). So the smaller id adopts it as a replacement, onto the root the
      larger id has left. The pair splits onto two roots, both confirmed and both responders, each reading the other only
      through the root it drains, for 48 h, then dark until a heuristic reset. This is the lab repro #89 asks for.

    P5e's answers cause neither order, but they widen both to every pair whose larger id answers before its own reset
    arrives, as Kotlin's IntroSync does. Without an answer, each order needs a frame of the larger id's under the new root
    that the smaller id opens before that reset, such as a re-seal of a DM it has not read yet. With answers off, the lab
    converges in both orders when neither side holds unacked DMs, and in #89's own order even when both do, since the
    larger id's re-seals are copies of DMs the smaller id has already read, which it never opens again.
  - **The photo's hash beside the seal acts on Android alone** (the Claims above). Nothing here reads it: this port has
    no carrier pull yet (ADR 2026-10.ym9y). On Android a carried CHAT frame's cleartext `attachmentHash` feeds the
    carrier pull (`ForwardRepository.kt:95-99`, `MeshManager.kt:2351-2372`) and keeps the bytes while any carried frame
    names them (`BlobRepository.kt:100-112`). So after a photo change our old sealed profiles keep the superseded hash
    named for their day: every Android node keeps that photo, and an Android newcomer back-filled with them pulls it.
    This port drops a replaced photo at once (`releaseBlob(replaced)`; `referencedBlobs()` counts no carried frame), so
    we answer NONE where an Android author would serve, and an Android asker with no Android holder in reach re-asks
    for the day (ADR 2026-10.m9uq). With the switch off nothing names it. Keeping the photo while our custody carries a
    live frame of ours naming it is the blobs plane's change, before the flip (`.agents/memory/roadmap.md`).
  - **What each event adds to every custody in reach.** Every sealed profile and answer is originated, so each is a row
    of ours for its day, counted in our 200 and in each node's 1,000, and purged by nothing: a ctl earns no receipt on
    either platform, and a sealed receipt purges nothing (ADR 2026-09.p6nb, amended). N is our confirmed sessions:
    - a reaction or a retraction: 1, in place of the cleartext reaction, which was carried too;
    - an edit: N;
    - each weekly prekey rotation: N, at the next heal, though the copy presents nothing new, since the sealed profile
      carries no prekey;
    - a new session: the responder's answer and the initiator's copy at its next heal. When we answer, our next heal adds
      nothing, one row less than Kotlin's (decided 12);
    - a reset, a flagged reset, each hour an init keeps riding, and each relaunch while one rides: 1, our answer;
    - a relaunch: nothing more (decided 11).

    Nothing bounds N by recency, here or in Kotlin (`exportedRoots`, `RatchetSessions.kt:576-591`), and this port
    sweeps no session: the ratchet's sweep drops keys, chains and epochs only, and `RatchetSessions.forget` has no
    caller. Sessions grow through P5d's sealed live ticks, which open one with every linked ratchet author whose room
    post we tick and every one that ticks ours. So if every pair in a room of M ratchet phones links within a day, the
    sessions alone add about M(M−1) rows to each node's custody among iPhones, past its 1,000 near M = 33, and up to
    1.5·M(M−1) where Kotlin answers, since its next heal sends the version its answer carried again (past 1,000 near
    M = 27). That comes before any edit, rotation or Android restart's N. The sessions and the relaunches are unmeasured.
    Once our 200 fills, our oldest frames go from every custody at once, undelivered DMs to an absent contact among
    them. An answer to an init that came over the initiator's own link could go point to point (`relay = false`), as
    the live tick it answers did; that changes the frame's form, so it is a knit-next suggestion for the maintainer.
  - A reaction whose store failed leaves its row applied and the peer unaware until our next reaction there, as Kotlin's
    optimistic row does after its throw.
  - A peer whose pinned profile dropped the bit keeps the fan-out trying it at every heal, one read each, as Kotlin's
    refusal in `sendCtlDm` keeps it unmarked.
  - The sealed profile carries no board, since this port binds none.
- **Guards:**
  - `RatchetAnswersTests`: `IntroSyncTest`'s answer cases by name, and its intro-send cases accounted for as deferred.
  - `MeshEngineSealedReactionTests`: `MeshManagerTest`'s DM reaction cases by name, the group's drift, a non-canonical id,
    a store failure in the seal's unit and in the row's read over both store kinds, and the seal inside a unit that is
    abandoned and one that commits.
  - `MeshEngineSealedProfileTests`: the confirmed target set, the heal's catch-up, version 0, the photo's hash, a
    relaunch sending nothing, a rotation due at the relaunch still sent, a seed whose store failed, the answer marking
    the dedupe, the photo's push before the sealed copy, a peer whose profile dropped the bit, a store failure over both
    store kinds, and the fan-out inside a unit.
  - `MeshEngineInitAnswerTests`: an Android initiator confirmed by the answer, the floor, a reset's new init, a marked
    init, an owed and a forgiven debt, the start's replay, a store failure over both store kinds, our profile unreadable,
    a seal the facade cannot make, and an answer inside a unit.
  - `RatchetPresentationLabTests`: an answer alone confirming its initiator, a sealed reaction and its retraction applied,
    `ProfileUpdateLabTest`'s cases by name, the sealed copy alone among them, and the blobs review's custody: three
    custodies agreeing with a carrier without the switch among them, each sealed frame held once in each, and the rows
    a relaunch and a new session add in two custodies.
  - `SealedControlUndoTests`: a reaction, a profile and an answer, each in a unit that fails and in one its caller
    abandons, over both store kinds, leave our custody as it was.
  - `RatchetSessionLabTests.bothResetWithinASecondAndEachAnswersTheOthersFlaggedInit`: both sides resetting within a
    second and answering each other's flagged init, in five meetings: linked and apart in both orders, and #89's own.
    #89's two orders are pinned as known issues, the lost DMs' with the sessions' agreement asserted outside the pin.
  - `MeshEngineRatchetSwitchTests.withTheSwitchOffReactionsProfilesAndAnswersTowardARatchetAndroidAreTodays`: the switch
    off, the real seals, an Android peer with `0x15F` and a signed prekey, frame for frame against today's.
  - `RatchetOutboundTests`' P5e cases, `RatchetStoreSessionPeerIdsTests.sessionPeerIdsListEveryPeerHeldInNodeIdOrder`,
    `RatchetSessionsTests.confirmedPeersAreTheSessionsThatConfirmed` and
    `MeshControlRatchetTests.theDumpCountsOurInitAnswersUnderAndroidsName`.

**Amended 2026-10-16, phase P6a1 (the group form's engine, store and facade):**

- **The engine is Kotlin's `GroupRatchetEngine`, whole and pure** (`Sources/KnitCrypto/Ratchet/GroupRatchetEngine.swift`
  and `+Types`, at knit-next `cbf2a487`). A chain comes in as a value, and every change leaves as a `SealResult`, an
  `AdoptOutcome` or an `OpenDelta` for the facade's unit to commit. Its seeds come from a seed source, as Kotlin's
  `GroupRatchetEngine(newSeed)` (`GroupRatchetEngine.kt:26-28`), and its IVs from an IV source, A9's `newIv`: the
  system's generator unless a test or a replay passes others, never the mesh's injected `random`. It holds no
  key-request state, which is the facade's. Nothing in the mesh calls it, so nothing changes on the air, switch on or
  off.
- **It differs from Kotlin's engine in four places.** The first three change nothing a node does, and the fourth keeps
  a frame Kotlin loses:
  - The group id is a parameter of each call. No chain carries it, nor the epoch's `export`, the spool's half, as P4b's
    session keeps no `sendEpochExport`.
  - `open` reads a receive chain or a stored key only for the header's own `se` and `n`, and tries the chains newest
    mint first, where Kotlin trusts its caller to pass no others.
  - An IV source that is not 12 bytes throws `RatchetCryptoError.sealing` out of the seal: this port's 12-byte guard
    refuses it (`RatchetCrypto.seal`), where the JVM's GCM accepts any IV that is not empty and a JVM receiver opens the
    frame with the IV it carries. Only a test passes one, since Kotlin's own seal draws 12 bytes (`AesGcm.randomIv`,
    `Crypto.kt:45`), and the facade then answers `unavailable` with nothing written.
  - **A stored key is spent by its full key,** `(group, sender, epoch, mintedAt, index)`. The open's delta names the
    mint of the key that opened the frame (`consumedSkippedMintedAt`), as P4c's DM delta names its root tag. Kotlin's
    names the index alone (`consumedSkippedIdx`), and its store deletes every mint's key there
    (`GroupRatchetRepository.kt:97`, `GroupRatchetDao.kt:77-84`). So a receiver holding both mints of one epoch, a wiped
    sender's two eras with the old seed adopted first, loses for good one frame per index the eras share: that frame
    finds no key, both chains are past its index, and it drops as `DUPLICATE` at every re-serve for its 24 h. Kotlin's
    doc prices the loss as a benign `AEAD_FAIL` and a key request (`GroupRatchetStore.kt:76-78`), but `DUPLICATE` never
    feeds the heuristic, and a re-sent seed is `alreadyKnown` and never rewinds a chain. Filed as knit-next #177. The
    difference is the receiver's own: nothing changes on the wire, and no vector moves, since no A9 state holds two mints
    of one epoch.
- **Unlike P4b's DM engine, it has no shape rule for a carried nonce, as Kotlin's group arm has none**
  (`InboundPipeline.kt:961-962`; the DM arm's rule is `:1025`). A nonce that is not 12 bytes fails as any AEAD refusal
  does, `AEAD_FAIL` where a chain is held, never `BAD_HEADER` (`GroupRatchetEngine.kt:273-277`, `:320-321`), and an
  `AEAD_FAIL` feeds the key-request heuristic, which costs at most one request an hour. The JVM's GCM fails a 12-byte
  frame's nonce cut or lengthened the same way, but opens a frame sealed under an IV of another length, which this
  port's 12-byte guard refuses (`RatchetCrypto.open`). No Kotlin sender seals one, so only a member's crafted frame
  meets the difference.
- **The store is `GroupRatchetStore`** (KnitStore), with records of bytes, numbers, flags and node ids, the group id and
  the sender passed beside them. `GroupRatchetRecords` (KnitMesh) is the one place they meet the engine's types.
  - `MemoryGroupRatchetStore` is `Checkpointing`, so the memory unit undoes it with the rest.
  - `SQLGroupRatchetStore` keeps schema v18: Android's four tables as its database v23 has them (`group_send_chains`,
    `group_recv_chains`, `group_skipped_keys`, `group_key_sends`, `GroupRatchetEntities.kt`), `STRICT`, every id a UTF-8
    `BLOB`, with Android's indexes. The send chain leaves out `export` and `updatedAt`, as v17's session does.
  - The row rules are `GroupRatchetDao`'s and `GroupRatchetRepository`'s: a send chain and a receive chain replace, a
    skipped key is inserted if absent, and the outbox never lowers a sent or an acked epoch (`GroupRatchetDao.kt:28-29`,
    `:52-53`, `:74-75`; `GroupRatchetRepository.kt:117-145`). A spent key goes by its full key, above, where Kotlin's
    takes every mint's key at its index.
  - A retired chain is a row with an empty seed and chain key and its count at the cap, its number and mint kept
    (`GroupRatchetRetention.retired`, knit-next ADR 2026-10.xgwj). `retireSendChains`, `deleteKeySend` and `purgeGroup`
    stay on the store for the roster's units in P6a2 and P6b, as Kotlin's `GroupRepository` calls the store directly
    (`GroupRepository.kt:133-134`, `:163`, `:191`, `:211`).
- **Retention is pure code** (`GroupRatchetRetention`), which both stores apply. A skipped key lives 48 h from its
  creation and a receive chain 48 h unused. Our newest send chain always stays, retired or not, so the numbering only
  rises but after a wipe, and the previous one drains 48 h past the newest's mint. The group's skipped keys are capped at
  2,000, apart from the DM's. Android orders the cap's eviction by `createdAt` alone; here a tie goes by group, as bytes,
  then sender, epoch, mint and index, so the two stores evict the same keys, now that the SQL store reads a group id
  back whole (below). The SQL sweep runs a truncating checkpoint as it commits, as the DM's does.
- **The SQL stores read a string back with every byte it was stored with.** `Row.text` decoded with
  `String(bytes:encoding: .utf8)`, which drops a leading U+FEFF as a byte order mark (measured on this toolchain), so an
  id stored as `EF BB BF` and X read back as X. It now decodes with `String(validating:as: UTF8.self)`, as KnitWire's
  CBOR decoder does, and still throws on bytes that are not UTF-8. The cap's eviction also deletes each key by the
  column bytes it read, never a string made of them again. Before, the SQL store ordered and deleted a U+FEFF group's
  keys under another group's id: the two stores evicted different keys, the delete matched nothing or another group's
  key, and the store stayed over the cap. The same decode fixes a bug already on `main` in custody: a frame whose id
  starts with U+FEFF was listed in our digest without it, so every neighbour sent it again at each exchange, and the
  quota evicted by the read-back id and missed the row. A crafted id, U+FEFF and then a real frame's id, could stand in
  for that frame: our digest named it, so no neighbour offered us the real one, and the quota could delete the real one
  in the crafted one's place (ADR 2026-09.jc2x, amended 2026-10-16).
- **Android still drops the mark, and this port keeps it on purpose.** knit-next's database driver binds every string
  as UTF-16, and SQLite drops a leading U+FEFF there and byte-swaps the rest after a leading U+FFFE, so on Android such
  an id is one custody row with its unmarked twin, and its digest lists it unmarked. Dropping the mark here would port
  the collision. Until knit-next binds ids whole, or both platforms refuse such ids (a paired change), an iPhone sends
  such a frame again to each Android neighbour at every exchange, and a soak that compares custody sets those ids aside
  (knit-next #178).
- **The facade is `GroupRatchetSessions`** (KnitMesh), shaped as P4c's `RatchetSessions`.
  - Each call on the store decides and writes inside one unit, reads the store inside it, and answers `settled`,
    `joined` or `failed`. An open's changes commit with what `alongside` writes, or none do.
  - An adoption belongs inside the open of the `CTL_GROUP_KEY` DM that carried it, as Kotlin's `adoptSeeds` runs inside
    the DM's commit (`GroupRatchetSessions.kt:115-118`), and answers `joined` there. Each seed goes by
    `(epoch, mintedAt)` against the newest mint held, so a re-serve is acknowledged again with no chain moved. The
    roster gate is the caller's, which holds the group's rows.
  - A seal reads, mints when the advance rules say, seals and persists in one unit. A minted seed comes back for the
    caller to distribute and record in the outbox before the frame floods, which is P6b's.
- **The floors are held in memory, as Kotlin holds them** (`GroupRatchetSessions.kt:36-43`), and die with the process:
  - At most four fresh adoptions a day per group and sender (`:274`), the bound on the skipped keys a sender can make us
    bank. The floor moves only on `settle`, after the outermost commit, where Kotlin stamps it inside the transaction, so
    a rollback here costs none of the day's four. It reads only what has settled: the caller settles each DM's open
    before the next one opens.
  - The key-request heuristic: three distinct frame ids of the last eight, and one request an hour per group and sender.
    The ids join at once, on the drop path outside any unit, as Kotlin's do. `markKeyRequested` is the caller's, once its
    request's unit commits.
- **`noteUndecryptable` runs the 48 h age gate itself,** on the frame's signed `sentAt` against our clock, before the
  ids, where Kotlin's pipeline runs it just before the call (`InboundPipeline.kt:1700-1701`), as P4c moved the DM's era
  gate into its facade. The comparison is loose, as custody's dead-on-arrival guard is: an ancient replay never spends
  the request budget.
- **The sweep runs in a unit of its own,** and nothing schedules it yet. The engine is to run it beside
  `RatchetSessions.sweep`, at start and every hour, as Android's `sweepKeyRetention` runs both (`MeshManager.kt:988-993`),
  which P6a2 wires with the group store in `MeshStores`.
- **The alternatives, and why not:**
  - **Kotlin's in-transaction stamp of the adoption floor:** a joined adoption whose outer unit fails would spend a floor
    for chains that were never stored.
  - **A facade wrapper for every store write:** the roster's retirements and purges belong in the roster's units, which
    call the store as Kotlin's do.
  - **Android's eviction order:** the memory and SQL stores could evict different keys.
- **Limits:**
  - The facade serves one caller at a time, the engine's actor.
  - A restart forgets the floors, as Android's do: a sender can be adopted four more times that day.
  - A wiped sender's old era is lost at a receiver that meets the re-mint's seed first, at Kotlin's level, and A9's
    `groupRestoreRemint` pins it. The old seed is `stale`, refused and not acked, and that era's unopened frames drop:
    as `DUPLICATE` where the new era's chain has passed their index, and as `AEAD_FAIL` where it has not. Both eras open
    only at a receiver that adopted the old seed first, and there, since the fourth difference above, every frame of
    both opens.
  - A sender that lost its state and re-mints under a clock set back before its old mint is `stale` at every receiver
    that still holds the old era, until that era's chains go unused for 48 h, at Kotlin's level.
  - A9's `groupSeal.minted` is always `null`: `GroupTranscript.kt:205` writes the seed and then overwrites it, since
    `JsonObjectBuilder.put` answers the previous value. The replays read a mint from the seal's `groupSeed` draw, and
    the generator's fix goes to knit-next.
  - Kotlin's soak still models a departure by deleting the leaver's chains, from before `0f519d71`. This port's soak
    retires them, as production does.
- **Guards:**
  - `GroupRatchetEngineTests`: knit-next's fifteen `GroupRatchetEngineTest` cases by name, and this port's: the header's
    own chains and keys, the nonce, the IV source, the mint, and a wiped sender's two eras keeping their own keys at an
    index they share (`bothErasOfAWipedSenderKeepTheirOwnKeysAtAnIndexTheyShare`).
  - `GroupRatchetSoakTests`: the soak's property on Kotlin's six seeds, drawn through this port's generator, one run at
    the roster cap of eight.
  - `GroupRatchetStoreTests`: twelve of knit-next's fifteen `GroupRatchetRepositoryTest` cases by name, over both store
    kinds, and this port's: the unit, group ids compared by their bytes, the holdings, a retirement where we never
    sealed, the insert-if-absent rule and the spend by the full key
    (`aKeyIsInsertedOnlyWhereNoneIsStoredAndASpendTakesItsOwnMintsKeyAlone`), the outbox, and the eviction order both
    stores agree on, a group id that starts with U+FEFF included (`bothStoresEvictTheSameKeysAtTheCap`).
    `GroupRatchetSessionsStoreTests` has the other three, which seal through the facade.
  - `GroupRatchetRetentionTests`, and `SQLGroupRatchetStoreTests`: a write the database refuses, an open outside a unit,
    the retired row's empty blobs, and what a deletion leaves in the file and its log.
  - `GroupRatchetSessionsTests`, with two eras' opens at the indices they share over both store kinds (old n 5, new n 5,
    new n 3, then old n 3: `aSpendLeavesTheOtherErasKeyAtTheIndexTheyShare`), `GroupRatchetSessionsUnitTests` (a joined
    adoption, seal and open, an outer unit that fails, a store that fails, the sweep's unit) and
    `GroupRatchetSessionsFloorTests` (four adoptions a day, the key-request heuristic and its age gate).
  - `RatchetGroupTranscriptTests` replays A9's six group transcripts at the engine, and `RatchetGroupVectorTests` the
    same six through both session layers, over both store kinds.
  - `SchemaTests.v18KeepsEveryGroupAndSessionAndStartsWithNoGroupRatchetState`.
  - `CustodyStoreByteKeyTests.anIdWithANulIsNotItsOwnPrefix`, over both store kinds: a frame id that starts with U+FEFF
    is listed, read and kept as itself.

**Amended 2026-10-16, phase P6a2 (the group form received in the mesh):**

- **With the switch on, the iPhone opens what fielded Android seals to a group whose other members all advertise
  `CAP_RATCHET` with a prekey** (`MeshManager.kt:1344-1353`), and adopts the seeds those members send it. It seals
  nothing in the group form: every group message of ours stays v1 until P6b. Kotlin lines here are at knit-next
  `cbf2a487`.
- **Wiring.** `MeshStores` carries the group store: `MemoryGroupRatchetStore` inside the memory unit, and
  `SQLGroupRatchetStore` on the iPhone's `KnitDatabase`. The engine holds a `GroupRatchetSessions` over it, whose seeds
  and IVs come from the system's generator. knit-peer is untouched, since it builds `MeshStores.inMemory`.
- **The sweeps.** The group store's retention sweep runs beside the DM ratchet's, at start before the replays and then
  hourly, each in a unit of its own, on the wall clock (`sweepKeyRetention`, `MeshManager.kt:988-993`). The seed park
  expires in the 10-minute sweep beside the key-wait park (`sweepExpired`, `:2333-2334`).
- **A seed rides a `CTL_GROUP_KEY` DM and is adopted in that DM's open unit,** for a group we hold, have not left, and
  whose effective roster has the sender, and only when it carries keys (`adoptGroupSeeds`, `InboundPipeline.kt:1535-1548`).
  A root-only seed commits the chain's advance alone, its `gr` kept raw. Once the outermost unit commits, the facade
  settles before anything else opens (the next DM's adoption reads the floor as it stands), then a `CTL_GROUP_KEY_ACK`,
  always v2, goes in a seal of its own, best effort (`ackGroupSeed`, `:1554-1585`), then the sender's group frames in our
  custody open again. A `CTL_GROUP_KEY_ACK` moves the outbox's row in its own DM's unit (`:1213-1217`). A key request
  (ctl 3) commits the advance alone: its answer re-seals our current seeds, which needs P6b's send chain.
- **The roster gate decides before anything commits,** as Kotlin's peek does (`holdGroupKeyForUnknownGroup`, `:1058`,
  `:1454-1478`). This port opens in one phase, so a seed for a group we hold no row for, or from a sender we hold as
  departed, abandons its open, the chain index unspent, and is then decided outside any unit:
  - At its first verdict it pins the roster it carries through `reconcile`, the one door every roster takes, with
    Kotlin's checks (the id derives from the founding set, we and the sender are in it, the cap, the rejoin guard;
    `pinRosterFromSeed`, `:1490-1497`), and opens again on the ordinary path once that row admits the sender. Otherwise
    it parks in `PendingGroupKeys` (1 h, 64 seeds, 16 a group, in memory, as Kotlin's), and a group whose park is full
    takes the ordinary path, where the frame commits with nothing adopted, as Kotlin's does. The second open costs one
    more decryption on this path alone.
  - Every roster that lands releases the parked seeds whose sender the row admits, past the router, each opened again as
    it came (`replayHeldGroupKeys`, `:1505-1527`). A departed sender's seed waits for that sender's own rejoin, in place,
    its clock untouched.
  - Out of our own custody at start, such a seed is left unopened rather than parked: the park is in memory and the
    frame is in custody, and the group's first sight opens it (below). That is how the park meets P5a's start replay.
    That replay runs before the start's group replay, so a seed whose unit failed before a stop adopts first, and its
    instant replay opens the frames it keys. The other order would count those frames as keyless again, and three of
    them would ask for a key the sender already sent.
- **Seeds and acks apply at every origin,** the start's replay included, unlike a reaction or a profile there (P5a): an
  adoption goes by the sender's own `(epoch, mintedAt)` against the newest mint held, never a stamp of ours, so a seed
  opened again is acknowledged again with no chain moved, and an ack only raises the outbox's epoch.
- **A group's first sight opens again every ratchet DM our custody holds from its effective roster,** oldest first
  (`replayCustodiedSeedDms`, `MeshManager.kt:1772-1830`), except the seed whose own roster is making the row and, by a
  rule of this port's own, the seeds that same landing just released, which Kotlin's replay would open a second time,
  to a `DUPLICATE`.
  It holds the era, as the start's replay does, where Kotlin's opens them as first verdicts: our custody keeps a day of
  these frames, and one whose first verdict committed in an era the pair has since left would open under its draining
  root and, as a first verdict, apply a reaction or a profile again, re-seal for a reset, or race the session with its
  old init. A seed that never committed opens all the same, unless it carries an init the held session has not resolved;
  with no session held, its init founds one.
- **A v2 frame addressed to a group opens after its roster's reconcile, through `GroupRatchetSessions`, in one unit with
  its message row or, of the ctls, a group reaction (6) alone; every other ctl commits the advance** (`:1598-1663`).
  - A frame with no group header is `GROUP_RATCHET_BAD_HEADER`. A v3 frame addressed to a group stays
    `RATCHET_BAD_HEADER`, and so does a DM-addressed one with only `g`, as P5a made them.
  - Our own frame, which custody serves back after a reinstall, drops as `GROUP_RATCHET_NO_KEY` before the open and asks
    nobody: we hold no receive chain of ours, and Kotlin's request goes nowhere since we never pin ourselves (`:1702`). A
    departed member's frames open and feed the heuristic, as Kotlin's do; a non-member's never pass the roster.
  - A group reaction applies at every origin: a group key is spent by its full key, and a chain is swept only after 48
    hours unused, by when every frame it opened has left custody (a day past its stamp), so only a frame's first open
    can apply it.
  - The four refusals have drop reasons and words of their own. `NO_KEY` and `AEAD_FAIL` feed the key-request heuristic
    outside any unit, on the frame's signed `sentAt` as it arrived. When it fires, a `CTL_GROUP_KEY_REQ` to a pinned peer
    with `CAP_RATCHET`, v2, with its prekey where no session is held, goes in a seal of its own, and `markKeyRequested`
    follows its commit (`maybeRequestGroupKey`, `:1694-1730`).
  - A unit that fails counts `storeRefused` and delivers nothing. The frame stays in custody, where the hourly replay
    opens it. No copy is kept in memory as P5a keeps a DM's: nobody seals a group frame twice under one id, so custody's
    first bytes are the frame.
- **The three custody replays** (`replayCustodiedGroupFrames`, `MeshManager.kt:1739-1770`): the sender's group frames
  after its seed is adopted, every DM above at a group's first sight, and every undelivered group frame at start and,
  with the switch on, every hour (`GROUP_REPLAY_MS`, `:3511`). Each runs after the outermost commit and settle, goes past
  the router, reads each frame's row in a unit of its own first (a read that fails skips the frame until the next
  replay), and reads custody without writing it. Only other members' group frames are replayed, as Kotlin's
  `liveGroupChatFrames(me)` reads them. That now holds at start with the switch off too, where our own frame used to
  meet the exists-gate or drop as `.cannotOpen`. Kotlin runs the hourly replay on every build; here it waits for the
  switch, so nothing changes with the switch off, and the flip ends the difference. Custody never reads group-ratchet
  state: a refusal and a failed unit change what we deliver, never what we carry, and ctl 3 and 4 are ordinary sealed
  DMs that purge nothing.
- **Android's counts** (`groupSeedsHeld`, `groupSeedsReplayed`, `groupSeedsAdopted`, `groupKeyRequestsSent`) are
  `MeshEngine.groupCounts`. The control surface's `ratchet` reply carries no group state yet.
- **With the switch off nothing changes:** a seed DM and a group-form frame drop as `.cannotOpen`, nothing reaches the
  group store, the park stays empty, and nothing goes on the air. The hourly replay and the group sweep do not run.
- **The alternatives, and why not:**
  - **Kotlin's two phases for the seed's gate:** one phase opens and commits in one unit; a second open on the rare
    path costs a decryption, not a second code path for every DM.
  - **Parking at the start's replay:** the park would be filled at every start from custody, and released as first
    verdicts frames whose first verdict may have committed before the restart.
  - **The first sight's replay as first verdicts, as Kotlin's:** above.
  - **A kept copy for a group frame whose unit failed:** custody holds the same bytes, so the hourly replay suffices.
- **Limits:**
  - A departed sender's parked seed lost to a restart waits for that sender's re-send or a key request, since a rejoin is
    no first sight, at Kotlin's level.
  - A seed carrying an init the held session has not resolved, met only by the first sight's replay, waits for the
    sender's re-send.
  - A group frame delivered by the instant replay inside the roster's reconcile is acknowledged a second time by the
    exists-gate when the outer pass reaches it, as in Kotlin.
  - A group's first sight opens again every consumed ctl DM its members' custody copies hold, each dropping as
    `DUPLICATE`, and the hourly replay opens every undelivered group ctl frame again the same way, as Kotlin's do.
  - A restart forgets the adoption floor, the heuristic's ids and the park, as Android's do.
  - P6b owes the send path: the group seal, the seed outbox and its flush (15 min per group, member and pairwise root;
    a reset forces it), the answer to a key request, the rejoin rekey and its hourly floor, and `retireSendChains`,
    `deleteKeySend` and `purgeGroup` in the roster's units.
  - knit-next's `InboundPipelineTest` rig records the two custody replays as calls (`custodyReplays`,
    `seedCustodyReplays`), so its `aSeedThatOutransItsGroupsFirstFrameIsParkedAndAdoptedWhenTheRosterLands` and
    `aParkedSeedLeavesTheChainWhereItWasSoItsReServeStillOpens` do not run them. With the real replays, the first would
    meet the released seed again at the first sight (a `RATCHET_DUPLICATE` this port avoids) and the second would open
    the group's first frame at once from the custodied seed. The ports here read what the real replays do.
- **Guards:** `PendingGroupKeysTests` (knit-next's seven `PendingGroupKeysTest` cases by name, and two of this port's);
  `GroupRatchetInboundTests` (the pure rules); `MeshEngineGroupRatchetTests` and `MeshEngineGroupSeedTests` (knit-next's
  `InboundPipelineTest` group-form receive cases by name, `:4208`, `:5735`, `:6415-6905`, `:6963-7471`, with `:6926` as
  P6b's half and `:6943` left to P6b); `MeshEngineGroupRatchetEdgeTests`, `MeshEngineGroupSeedParkTests` and
  `MeshEngineGroupKeyRequestTests` (this port's own: an ack moving the outbox, our own frames coming back, a plaintext
  that will not decode, a seed the start's replay leaves in custody, a parked seed served again, a full park, a request
  toward a member without the ratchet and one whose unit fails);
  `MeshEngineGroupRatchetPairTests` (the reviews' trials over the database: a group frame before its seed, a refused
  row and the hourly replay, the memory unit restoring the group store, a frame id led by U+FEFF, a wiped sender's two
  eras in both orders, each replay sending no copy of its own; a seed DM whose unit fails, a replay whose row read
  fails); `MeshEngineGroupRatchetRestartTests` (a restart with a parked seed, one whose seed was the first contact, and
  the start's order);
  `MeshEngineGroupRatchetScheduleTests` (the switch off, a group sweep the store refuses, and `MeshManagerTest`'s
  `healRunsTheRetentionSweepsAndTheCustodyReplayOncePastTheirHourNotOnEveryCall`); `GroupRatchetLabTests` (the receive
  half of `GroupFirstMessageLabTest`, `SessionLabTest.aMemberWhoMissedTheSeedAsksAfterThreeUnreadableFrames` and
  `GroupMembershipLabTest`'s overtaking seeds); `StoreTransactorTests`, whose contents now read both ratchet stores.

**Amended 2026-10-16, phase P6b (the group form sent in the mesh):**

- **With the switch on, the iPhone seals the group form when every other member advertises `CAP_RATCHET` with a valid
  prekey, and sends each epoch's seed to each member, pairwise, before the frame** (`sealEnvelopeFor`'s group arm,
  `sealGroupRatchet`, `groupRatchetEligible`, `distributeGroupSeed` and `sendSeedDm`, `MeshManager.kt:1304-1409` at
  knit-next `cbf2a487`). Every other frame stays v1, decided frame by frame. With the switch off nothing changes on the
  air or in the stores.
- **One read decides, all or nothing per frame.** The send's unit reads every other member's pinned row once
  (`GroupRatchetOutbound.form`). The group form needs each of them to have a bundle, the bit and a prekey that verifies;
  otherwise the frame goes v1 to the bundles that read returned. A member whose id does not parse keeps the group on v1
  and gets no wrap, as the v1 seal always skipped it. A blocked member is still a member: withholding their seed would
  reveal the block (ADR 2026-10.5wgg).
- **The send unit follows P5b's.** The message's row is saved waiting first. One store unit, the outermost, then holds
  the group seal and any mint, each new seed's DM-ratchet seal to every member with its outbox row (`markKeySent`), every
  signature, our custody's copy of each frame, and the cleared `pendingKey`. Only after it commits do the seeds settle
  and go on the air, then the frame, then the counts (`groupSealedRatchet`, `groupSealedV1Fallback`, `groupSeedsSent`)
  and `.sent`. If the unit fails, the row stays waiting, nothing goes on the air, and the heal seals it again
  (`retryWaitingGroupMessages`), as P5b's heal retries a DM. Each frame is signed once, inside the unit.
- **A seed that will not seal undoes the mint.** The group-form attempt is a unit nested inside the send's. If the DM
  ratchet will not seal a seed to one member (no session and no usable prekey, a new epoch due with no base, a prekey
  X25519 refuses), the nested unit is abandoned. That undoes the mint, the group chain's advance and the seeds already
  sealed, and the frame goes v1 in the outer unit, counted as `groupSealedV1Fallback`. Kotlin keeps the mint and floods
  the seeds it already sealed (`MeshManager.kt:1333-1339`). Its next send then reuses that chain toward the member who
  never got the seed, and that member reads nothing until a re-send or a key request. Here no group frame is ever sealed
  under a seed that some current member was never sent.
- **Seed DMs** are `CTL_GROUP_KEY` ctl DMs, always in v2's named form. They carry `keys` and the group's founding roster
  (`toFoundingInfo`: the founding set, the creator and the name, never the photo, spec C-3.2-16), and never a root (`gr`,
  which this ADR leaves out). They flood and sit in custody like any chat, but never make a row, are never acknowledged
  as a message, and purge nothing (ADR 2026-09.p6nb). A first distribution has no floor, as in Kotlin.
- **The re-sends** (`flushPendingGroupKeysFor` and `redistributeGroupKey`, `MeshManager.kt:1444-1484`). Our newest seed
  goes again to a member whose outbox row shows it unacknowledged, in every group we share with them and have not left.
  That happens when their profile arrives, at each link-up and at each 60-second re-offer (`:2467`, `:2521`). It also
  happens after their reset's first verdict, right after the P5b re-seal, forced past the outbox's ack
  (`InboundPipeline.kt:1144-1148`). A key request's first verdict is answered after its DM commits, with every seed we
  retain, when we hold the group, have not left it, and the requester is on its effective roster. The answer never
  advances the epoch. The start's replay answers no request and forces no flush, just as it re-seals nothing. Each
  re-send is its own unit: it reads the seeds and the member's row, checks the floor, seals, and writes the outbox row
  and our custody's copy. The flood, the floor's stamp and the count wait for the commit.
- **The seed floor** (`GroupSendFloors`, `seedSendFloorOpen`, `:1838-1849`) is 15 minutes per group and member under one
  pairwise root. It lives in memory on our monotonic clock and dies with the process. The root is fingerprinted by its
  tag (`RatchetCrypto.rootTag`), never kept. Kotlin stamps the floor as it checks it, and this port differs in two ways.
  The stamp waits for the unit's commit, so a failed unit stamps nothing and the next trigger tries again. And the stamp
  names the root the seed went under, read after the seal, where Kotlin names the root it read before, so a seed that
  starts a session is not sent again at once under that session's new root. A seal that cannot be made once the floor is
  open still stamps it, as Kotlin's does.
- **The profile's flush runs before the waiting messages' flush.** Kotlin runs it after `flushPending`
  (`InboundPipeline.kt:3220-3221`), but Kotlin never holds a group message waiting. Here a waiting message that mints at
  that moment sends its own seed, and the profile's flush would otherwise send the same seed again straight away.
- **Sealed group reactions** (`sealGroupReaction`, `MeshManager.kt:2227-2247`) go in the group form as `CTL_REACTION`,
  dated by the row's clock, when every other member can read it, with the seed sent as for a message. Otherwise they go
  as the cleartext frame, now counted as `reactionsSealedFallback` as Kotlin counts it, which ends P5e's drift.
- **The roster's units carry the group form's state** (`GroupRepository.kt:108-194`):
  - A departure's roster shrink, its notice, `retireSendChains` and `deleteKeySend(leaver)` commit in one unit.
  - A member's own rejoin retires our send chains in the reconcile's unit when its rekey is due: with the switch on, at
    most once an hour per group and member (`rejoinRekeyDue`, `InboundPipeline.kt:2308-2321`), held in memory on our
    monotonic clock and stamped after the commit.
  - Our leave's deletes, tombstone and `purgeGroup` commit in one unit.

  A retired chain keeps its number (knit-next ADR 2026-10.xgwj). The roster's writes were not in units before, and now a
  unit that fails writes nothing and counts `storeRefused`. A rejoin carried by a chat frame is not delivered, and the
  frame waits in our custody for the start's replay, and with the switch on for the hourly one. A `groupleave` or a
  `groupupdate` whose unit fails waits the same way since phase P7a, where Android loses it (below, Limits). Our own leave
  answers `false` with the `groupleave` already on the air, since today's order sends that first.
- **Which writes wait for the switch.** The departure's retire, the rejoin's retire and our leave's purge run whatever
  the switch says. They only ever take key material away, they write nothing on a store the switch never wrote to, and
  they stop a Debug toggle from leaving behind a chain whose seed the leaver holds, or one the rejoiner would get with
  every frame it missed. Only the rejoin floor waits for the switch: with it off every rejoin retires, and no floor is
  stamped.
- **Kotlin's `forgetSelf`** drops outbox rows that older builds wrote for their own node. No build of this port writes
  one, since every seed target and re-send skips our own id, so it is not ported. The port has no local group delete, so
  `delete`'s purge has no caller here.
- **The control surface** still carries no group state. `MeshEngine.groupCounts` holds all seven of Android's counts for
  P7's oracle.
- **Alternatives, and why not:**
  - **Kotlin's order, keeping the mint when a seed will not seal:** the next send would seal under a seed a current
    member was never sent, the one case the all-or-nothing rule exists to prevent.
  - **The v1 fallback in a second unit after abandoning the first:** two reads of the members' rows, and a second path to
    the same frame. The nested unit keeps one read and one unit.
  - **Gating the departure's or the rejoin's retire on the switch:** a chain minted while the switch was on would outlive
    a departure seen while it was off, and once the switch is back on it would seal again under a seed the leaver holds.
    Across a rejoin seen while it was off, the next flush would send the rejoiner the seed of every frame it missed.
  - **Floors on the wall clock, as in Kotlin:** this port's floors live in memory on the monotonic clock, which a clock
    change can neither reopen nor shut.
- **Limits:**
  - A first distribution stamps no floor, as in Kotlin, so a linked member that has not acknowledged by the next
    60-second re-offer gets the seed once more.
  - A group message waiting for a key, or one whose unit failed, is retried at every heal. While no key is pinned, that
    retry is a unit that reads the members' rows and writes nothing.
  - With the switch on, the re-offer's flush opens one read-only unit per neighbour and group.
  - The floors die with the process. After a relaunch each unacknowledged seed may go once more, and a rejoin soon after
    rekeys again.
  - While the switch is off, which is every build until the flip, Android's group info reads "Legacy encryption" for any
    group with an iPhone in it. ADR 2026-09.n393's consequence holds until then.
  - **A departure lost to a failed unit stays lost until the next start** (both reviews of P6b), and with the switch on
    until the next hourly replay. Our digest lists the `groupleave`, so no neighbour serves it again, and until the
    replay takes it the leaver stays on our roster, no retire runs, and a mint in between sends them a seed. Since
    phase P7a the replays take our custodied `groupleave` and `groupupdate` frames (below); one that leaves our custody
    first, past its day or evicted, is lost for good. Kotlin's replay takes group chat alone (`MeshManager.kt:1739-1764`),
    so Android loses it for good.
  - **A member who never acknowledges costs a seed every 15 minutes while linked,** as in Kotlin. A leaver whose leave
    we never saw refuses our seeds unanswered (`adoptGroupSeeds`, `InboundPipeline.kt:1543`), so the re-offer sends
    them a new seed DM under a fresh id each time the floor opens: up to 96 a day per group and member. Each one floods,
    sits in every carrier's custody for a day and counts against our quota of 200 there, which then evicts our oldest
    frames. Reported as knit-next #183; the port keeps Kotlin's rule until a fix lands on both.
  - **A member who flaps leave and rejoin** makes us mint at each departure (no floor) and at each due rejoin (hourly).
    Past `maxAdoptionsPerDay` (4), receivers refuse our new seeds for the rest of the day, and the group form goes dark
    for them. That is Kotlin's level, and the port matches it.
- **Guards:**
  - `GroupRatchetOutboundTests`: the pure rules (the form, the owed seed, the founding roster, both floors, a rejoin).
  - `MeshEngineGroupSendTests`: `MeshManagerTest`'s group-send cases by name (`:2128-2485`: all capable, the founding
    roster, the chain reused, an incapable member, an unpinned member, blocked members, the eligible group reaction), and
    a seed that will not seal.
  - `MeshEngineGroupSeedSendTests`: `aKeyRequestReSendsCurrentSeedsOncePerFloor`,
    `aForcedFlushBypassesTheStaleAckGuardAfterAPeerWipe`, `aSeedSentUnderARootTheMemberHasLeftDoesNotHoldBackTheNextOne`,
    `InboundPipelineTest.aSessionResetAlsoReSendsGroupSeeds`, the request's P6b half, each trigger, what is never re-sent,
    and a re-send whose unit fails.
  - `MeshEngineSealedReactionTests.aGroupReactionWithAnIneligibleMemberFallsBackToTheCleartextFrame`.
  - `MeshEngineGroupRosterUnitTests`: the departure's, the leave's and the rejoin's units over both store kinds, each
    failing whole; a rejoin seen with the switch off retires a chain the switch minted; and a departure lost to a failed
    unit, which the next start's replay recovers since P7a.
  - `MeshEngineGroupSwitchTests`: with the switch off, the same frames from the same draws, nothing in the group store,
    and no floor.
  - `GroupSendPairTests`: an iPhone author and an iPhone receiver over SQL, with an Android reader. The first send, a
    frame that outruns its seed, a member that missed its seed and asks, a send unit that fails and the heal, and the
    rejoin rekey's floor.
  - `GroupSendLabTests`: `GroupMembershipLabTest`'s leave rekey, rejoiner's seed and both #167 cases, and
    `GroupFirstMessageLabTest`'s three first messages, with iPhone authors.
  - `GroupSendSoakTests`: three iPhones on Kotlin's six seeds, under a courier that drops, reorders, duplicates and
    holds, with a departure mid-run.
  - `TickLabTests`' sealed group tick, now under the session the seed began.

**Amended 2026-10-16, phase P7a (a lost departure replayed):**

- **The start's replay, and with the switch on the hourly one, take our custodied `groupleave` and `groupupdate`
  frames from others,** in the same pass and order as the group chats (oldest received first), past the router and with
  no hop, through `handleGroupLeave` and `handleGroupUpdate`. The instant replay after a seed lands stays chats only.
  It runs whatever the switch says at start, as the chat replay does. This is a deliberate difference from Kotlin,
  whose `replayCustodiedGroupFrames` reads group chat alone (`MeshManager.kt:1739-1764` at knit-next `cbf2a487`), so a
  roster frame whose store unit fails is lost there for good: it stays in custody and the digest, and nobody serves it
  again. No wire, vector, schema, label, floor or capability moved, and Android needs nothing.
- **A replay never undoes a later state.**
  - A departure already recorded changes nothing, since `GroupRoster.depart` answers nil for someone already departed.
  - A leave no newer than its sender's rejoin changes nothing either, by `depart`'s `leftAt > rejoinedAt` rule.
  - A `groupupdate` that changes nothing opens no unit and announces nothing.
  - One new rule covers the case those miss. When a leave was lost, its sender was never departed here, so their newer
    frame arrived as an ordinary one and left no rejoin stamp. Replaying the leave would then take them off, though their
    own later frame brings them back in either order. So a leave is skipped when the leaver acted after it, by either
    of two records, each compared on the leaver's clock and bounded as `clampFuture` bounds it:
    - our custody holds a newer chat or `groupupdate` of theirs in that group that lists them as a member
      (`GroupRoster.outlives`);
    - the group's thread holds a newer row of theirs: a message, or the rename or rejoin line only their own frame
      writes (`GroupRoster.actedAfter`, over `messages(in:)`). This is the durable half (the crypto review of P7a).
      Custody trims a busy group's bucket (200) oldest first, and a leave's envelope names no group, so the leave sits
      in no group bucket and can outlast the frame that outlives it. The thread is read in a store unit of its own, and
      a read the store fails holds the leave back until the next replay, since its fallback of no rows would depart a
      member who stayed (both reviews of P7a's fixes).

    Only the leaver's own frames and rows count, so a member still removes only themselves and nobody keeps anyone else
    on the roster. A rejoin carried only by a seed DM is sealed, so neither record sees it. A seed comes only with a
    group frame of that epoch, and that frame counts.
- **A replay counts nothing its first verdict already counted.** A blocked sender, a refused roster and an
  undecodable leave are counted only at the first verdict (`.firstVerdict`). Replayed, they log at debug and count
  nothing, so `status.dropped` does not climb at every start. A store that still fails counts `storeRefused` again,
  because that is a new failure. A group chat replayed from a blocked sender still counts `.blocked` at every start, as
  it did before.
- **After an unblock,** a leave or roster frame the member sent during the block applies at the next start, as a
  group message from that time already surfaces (ADR 2026-10.5wgg, amended). Android never applies a blocked member's
  leave. The leave is the member's own signed act, so this port departs them.
- **A leave that came before its group** now applies at the next start if the group has landed by then and our custody
  still holds the leave. ADR 2026-09.n393 mirrored Android's loss on purpose, and that mirror ends here (n393, amended).
  Android peers already disagree on this case, depending on the order the frames reached each one.
- **Custody is unchanged.** `isCarriable`, the carry, the digest and the quotas read no roster and no group-ratchet
  state. The replay reads custody and writes nothing to it, and with the switch off it puts nothing on the air. Where
  the switch was never on, it writes nothing to the group-ratchet store: the departure's retire and the rejoin's run
  whatever the switch says, as in P6b, and find no rows to retire.
- **The cost.** Every start, and with the switch on every hour, runs `depart` or `reconcile` once more for each live
  roster frame from others in our custody. That is a read, plus `seedsMayLand` for an accepted `groupupdate` with the
  switch on. Nothing is written for a frame already applied. The outlived check scans custody and reads the group's
  thread only for a leave that would depart someone (the group held and not left, the sender not blocked, an active
  member, the leave newer than their rejoin), so a leave already applied, or a self-signed leave for a group that does
  not exist, costs a row read and no scan (the blobs review of P7a).
- **Limits:**
  - A roster frame that leaves our custody before the next start, past its day (`sentAt + 24 h`) or evicted by a quota,
    is lost for good, as before.
  - A rejoin carried only by a `groupupdate` leaves no row unless it renamed the group. If that frame has left our
    custody while the lost leave has not, the replay still departs the member until their next frame brings them back.
    So does a rejoin whose only row the user deleted: a deleted message's row is gone, and only custody's copy then
    speaks for it.
  - A photo with no clock (`photoUpdatedAt` absent, as builds before the field send it) is taken by a replay while no
    photo is held, as a first verdict takes it. A tie against a held photo never moves it in either case.
  - A tie on a name's or a photo's clock goes to the incoming frame at a first verdict, as Kotlin's does
    (`InboundPipeline.kt:2042-2045`), so the pair converges as Android does. A replay keeps the row on a tie
    (`GroupRoster.keepsTies`), and changes the name or the photo only for a strictly newer clock. Two renames on one
    millisecond therefore stay as their first verdicts left them, and no start writes a notice for them. A group chat
    replayed from our custody carries a roster too, so it follows the same rule, and its roster's refusal or blocked
    creator is no longer counted again at each start. The blocked-sender gate on chats, in `handleChat`, still counts
    and ticks at every start, as it did before P7a.
  - Kotlin keeps the hole. It is worth a knit-next issue, and P7's note for knit-next names it.
- **Guards:**
  - `MeshEngineGroupRosterUnitTests.aDepartureLostToAFailedUnitIsRecoveredByTheNextStartsReplay`, over both store kinds:
    Carol is departed after the restart, the next mint seeds Alice alone, and Carol gets no seed.
  - `MeshEngineGroupRosterReplayTests`: an old leave after its sender's rejoin; a lost leave outlived by its sender's
    newer chat (both kinds); a departure already recorded (no write, no notice, no drop, nothing above debug); a refusal
    and an undecodable leave counted once; a blocked sender's leave counted once and applied after the unblock; a lost
    rename applied at the next start and only once (both kinds); the switch off recovering at start with nothing more
    on the air (both kinds); the hourly replay recovering with the switch on, and not with it off.
  - `MeshEngineGroupRosterReplayEdgeTests`: a lost leave whose outliving chat the group's custody bucket evicted
    (`maxPerGroup` 3) keeps Carol, her outbox row and our chain (both kinds), and so does a start whose read of the
    thread fails, and the start after it (both kinds); a lost departure recovered at start against
    a control whose departure committed, with a peer linked: the same frames on the air, no custody row written, and
    with the switch on the same hourly frames and no drop (both kinds, both switch states).
  - `GroupLeavePairTests.aLeaverWhoseDepartureWasLostReadsNothingSentAfterTheRestart`: over SQL, Carol (an Android
    reader) read the group before her leave; after the lost departure and a restart, the group-form frame carries no
    wrap, Carol gets no seed and opens nothing, the outbox has no row for her, and Alice opens it.
  - `GroupRosterReplayRulesTests`: `outlives`, `actedAfter`, a replay keeping the row on a tie where a first verdict
    takes the incoming frame, and a replay taking a photo with no clock while none is held.
  - `MeshEngineGroupRosterReplayTests.twoRenamesOnOneClockChangeNothingAtLaterStarts` (two first verdicts, two
    restarts) and `aTiedRenameReplayedAloneDoesNotTakeTheRowBack`; without the replay's tie rule both fail.
  - Mutation-checked: without the new frame types in the filter, the restart, rename, unblock and hourly tests fail.
    Without `depart`'s rejoin guard the rejoin test fails, without `outlives` the outlived test fails, and without the
    first-verdict gate the refusal and block tests fail. Without `actedAfter` the eviction test fails, without the
    no-photo clause the photo case fails, without the new frame types the pair test fails, and with the thread read
    outside its own unit the failed-read case fails.

**Amended 2026-10-16, phase P7b (A10's iOS half):**

- **`ios-emitted-v1.json` now carries the iPhone's ratchet frames,** additively. Its six frames, Carol's identity and
  the safety number are byte-identical, and only `about` grew. Carol's v1 profile takes a literal `0xF` in place of
  `Capabilities.local`, so the flip cannot move a frame Android pins as "no ratchet". Its committed bytes were already
  `0xF` and did not change.
- **What it adds.** Eleven entries: ten frames Carol's engine makes, each with a `sealed` block giving its `v`, its form,
  `se`, `n`, `pe`, the prekey its init names, its exact plaintext and that plaintext's fields, and her hand-built ratchet
  profile, which carries `prekey`, `capabilities` and `version` instead:
  - `carolRatchetProfile`, the only hand-built one: her signed profile with the flip's bits (`0x15F`, a literal) and
    carolSpk1, at version 2;
  - Carol's DMs to Bob in one session, which her engine starts: the v3 opener with its init (`carolRatchetDmToBob`), a v3 DM
    carrying a room post's tick inline (`carolInlineAcksToBob`), then, once Bob's reply confirms the session, a sealed
    receipt with a second tick riding in `acks`, a sealed profile (ctl 8), and a reaction and its retraction (ctl 6), all
    v3;
  - for a group of Alice, Bob and Carol: a v2 `CTL_GROUP_KEY` seed DM to each member (an init to Alice, the session to Bob),
    carrying `keys` and the founding roster and never `gr`, then a group-form message and a group-form reaction (ctl 6).

  A new `ratchet` section says how to open them. It lists A9's three prekeys with their private halves (test keys), the
  draws Carol's engines took in order, and Bob's one seal, his v3 reply on one fixed key. It also gives each reader's steps
  in order (`replay`): a fresh `RatchetSessions` beside a fresh `GroupRatchetSessions`, opening and committing at each
  frame's `sentAt`, adopting a seed DM's seeds, and sending nothing back.
- **Made by the engine, from fixed draws.** Carol's `MeshEngine` makes every frame but the profile, with the switch on. Its
  ratchet takes keys and IVs, and its group form seeds and IVs, from `fixtureBytes` seeds 184–193. Bob's reply takes seed
  194, Bob's frame ids take seeds 36–38, and the engine's generator (seed `0xA10`) draws only frame ids. So every frame,
  v2 and the group form included, comes out the same on every run apart from its signature: each is rebuilt and
  compared, then its signature verified. The profile's prekey signature is the one exception: it is taken from the committed copy
  once it verifies, because CryptoKit randomizes it.
- **One test seam in product code.** `MeshEngine`'s internal initializer takes the group engine
  (`groupRatchetEngine`) beside the DM engine, as P5b's seam does. The public initializer passes `GroupRatchetEngine()`,
  the system's generator, and nothing else changed.
- **Left out, and why:**
  - an init's answer and anything sealed while Carol is the responder: Kotlin's half would have to replay Bob's opener on
    his draws. The answer is the sealed profile above, and `RatchetCarolVectorTests` already checks Carol's responder
    seals against A9's `aliceInitiatesToCarol`;
  - a reset and the re-seal: `RatchetSendVectorTests` already sends A9's through this port's engine, byte for byte;
  - the live-link tick: the receipt's seal and plaintext, signed with `relay = false`;
  - ctl 3 and 4: the same `sealControl` path, with a `gk` that `wire-v1.json` pins. A group key ack needs a seed sent to
    Carol, which brings in Bob's group draws. It can be added on the same file later.
- **What Android's half must check** (`IosEmittedVectorTest`, under knit-next's rules). Each frame verifies under Carol's
  bundle and re-encodes at both layers. The ratchet profile pins carolSpk1 and `0x15F` through the ordinary door. Each
  reader takes its `replay` steps with A9's prekey, with Bob's seal on his listed draw coming out as the listed signed
  bytes. Each open gives the entry's `plaintext` exactly, and the seeds adopted open the group form for both readers.
  Three details from the crypto review, for whoever writes those cases:
  - `adoptSeeds` answers `AdoptResult(ackEpoch, freshChains)`: check `ackEpoch == 1` and `freshChains == 1`, called
    inside `commitOpen`'s `onOpened`, as the pipeline calls it.
  - For Bob's seal, decode the listed wire and compare the resealed `EncEnvelope`; the entry does not spell out the
    `ChatContent` around it.
  - Deliver `carolRatchetProfile` straight after `carolProfile`. If the sealed profile (version 1756200016000) comes
    first, the name and status read as stale, though the prekey still pins.
- **Still owed:** `scripts/sync-vectors.py --export` and the knit-next session that adds those cases and a README row.
  The iOS checks already pass under CryptoKit (`test:macos`, 2026-10-16).
- **Guards:** `EmittedVectorTests`, which now lives in `KnitMeshTests` beside the engine's fixtures:
  - `theCommittedRatchetFramesAreCurrent`: every entry and the section, against a fresh run;
  - `bobAndAliceOpenTheCommittedRatchetFrames`: the committed frames through `AndroidPeer` and `GroupFormReader`, by the
    committed steps;
  - `bobsEnginePinsCarolsCommittedRatchetProfile`, with Bob's switch on and off;
  - `carolsRatchetDMsSayWhatTheScenarioDid` and `carolsGroupFormFramesSayWhatTheScenarioDid`: each frame's form, header
    and fields, and the draw order;
  - `theRatchetChecksTellACurrentFrameFromAStaleOne`: a run at another clock, a profile with other bits or another
    prekey, and a frame for Bob read as Alice all fail.
