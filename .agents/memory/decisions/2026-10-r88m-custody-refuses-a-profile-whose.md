---
id: "2026-10.r88m"
slug: custody-refuses-a-profile-whose
title: "custody refuses a profile whose signed bytes exceed 8 KiB"
date: 2026-10-30
topics: [custody, convergence, security, keys, blobs]
---

# ADR 2026-10.r88m — custody refuses a profile whose signed bytes exceed 8 KiB

Status: Accepted (2026-10-30). Mirrors knit-next ADR 2026-10.jgeg (`a0b52f865`, merged to knit-next's `main` from
`fix/profile-door-cap`, ahead of the pin `e63f15f4`; knit-next #234), a paired change shipped in the same release
(knit-ios #22). It has three
parts: custody's cap, below; the engine's door, the stored-proof sweep and the summed counter, under "The door"; and the
profile photo's ceiling, under "The photo ceiling". Amends ADR 2026-10.6n48, whose "still open" list named this cap, and
ADR 2026-10.nh55, which left peers' photos as they were.
Amended 2026-10-31 (knit-ios `fix/ios-photo-ask-ceiling`, paired change `ios-photo-ask-ceiling`, iOS alone moving):
"The photo ceiling" Decisions 3, 5 and 8 now port knit-next `a0b52f865`'s `recordWant` and `mergeCeiling`
(`BlobExchange.kt:2211`, `:2233-2253`), `want`'s refusal check (`:289`) and `Want.passedOver` (`:491-521`, `:3002`): a
neighbour's ask never lifts the ceiling, our photo want on an echo makes it photo-only, and a want remembers the holders
it passed over. Before, any ask cleared the flag, so a holder passed over could lift it by asking us for the hash.
Amended 2026-10-31 (knit-ios `fix/ios-avatar-push-mark`, paired change `ios-avatar-push-mark`, iOS alone moving):
"The photo ceiling" Decisions 2 and 5 now port knit-next `a0b52f865`'s `ceilingOf` and `refuseOver`
(`FileIntake.kt:344-363`, `:388-398`): only an ATTACHMENT kept under a photo-only want's ceiling at its header passes
its sender over. Before, a pushed AVATAR cut off at the ceiling marked its pusher whenever a photo-only want of the same
hash stood: trial run 20261031-021140 saw a 1,429,545-byte leftover photo pushed at link-up cut at its header, and
`photosOverCeiling` went from 0 to 1 with no ask made.

**Context:** a profile is the one frame every node pins, caches and serves to anyone who asks for its sender's key. Its
size was bounded only by custody's 60 KiB byte cap (ADR 2026-10.6n48) and the link's record size, so each pinned sender
could make every node hold, cache and re-serve up to 60 KiB of profile. The largest profile an honest build authors is
949 bytes of `signed` on iOS (a name and status at their limits, a photo hash, a prekey and every capability, measured
by `CustodyHeadroomTests`) and 1,017 on Android. A cap on one platform alone would split digests, so it is paired.

**Decision:**

1. **The cap.** `CustodyLimits.maxProfileSignedBytes`, 8,192 bytes, Android's frame ceiling on its fast and LoRa links.
   Only `signed` counts, never `sig`, as for the byte cap. A profile of exactly the cap is kept. Other types are
   untouched: a chat of the same size is kept.
2. **One predicate.** `CustodyRules.isOversizeProfile(type:signedCount:limits:)` is the rule. Admission applies it right
   after the byte cap and before the clock and the roster gate, refusing with `CustodyRefusal.profileOversize`. A profile
   over both caps is `.oversize`, so it is counted once, and the profile counter does not move. It binds every origin,
   our own profile included, and a refusal writes and evicts nothing.
3. **The sweep deletes what an older build stored.** Both `sweepExpired` also delete live profile rows over the cap,
   counted in the return so `MeshEngine.sweep` re-reads the digest cue, as the byte cap's delete does. The memory store
   runs the predicate. The SQL store's clause is `type = ? AND length(signed) > ?`, with the type bound as
   `StoredText.bytes(FrameType.profile.rawValue)`: `type` is a `BLOB` in a `STRICT` table, and a text literal never equals
   a blob, so `type = 'profile'` would delete nothing.
4. **One configured value.** `CustodyStore.limits` is public on both stores, so the engine's door reads the same cap
   custody applies, and a rig that lowers one lowers both.
5. **Counted apart.** `CustodySync.profileOversizeRefusedCount`, logged at `.debug` as
   `custody refused <id> (profile): <n> signed bytes over the profile cap`. The engine adds its door's count to it for
   `profileOversizeRefused`.
6. **`KeyExchange`'s cache is bounded,** this port's own rule: at most `KeyExchange.maxCachedProfiles`, 1,024 signed
   profiles, the least recently pinned or served dropped first (`ProfileCache`, O(1) a step, its order a function of the
   calls alone). A dropped profile is read back from the pin store at its next miss, as one after a restart is (ADR
   2026-09.g64k). Android's cache has no bound (`KeyExchange.kt:70` at `e63f15f4`). Nothing a peer sees depends on which
   profiles are cached here: `want` reads the cache as Android does, and the engine asks only for a sender it has no key
   for or whose signed profile it lacks. The cap above bounds each entry, and this bounds their number.

**Consequences / limits:**

- Until every node in reach is upgraded, an older node custodies and re-serves over-cap profiles at each digest
  exchange, and an upgraded node refuses them each time until their 24 h TTL. The byte cap had the same window.
- Once per node, between the upgrade and its first sweep, an over-cap profile taken before the upgrade still counts
  toward the quotas, as for the byte cap.
- Over-cap profiles are still relayed. Custody's refusal stops nothing but custody.
- The trap: a composer check looks like the place for this. The rule is custody's admission, which every node applies
  to the same bytes; a composer limit would bind only this port's frames.
- The engine's door before verify (contract section 2), deleting stored proofs over the cap (section 4), and the `Mesh`
  and `status` counter (section 5) are under "The door", and the photo ceiling (section 6) under "The photo ceiling".

**Kept true by** `CustodyRulesTests` (the 8,192 default, the edge, another type of the same size, over both caps, the
order before the clock, `sig` left out), `CustodyByteCapTests` (the edge over both stores, and a full store that
evicts nothing), `CustodyStoreTests.theSweepDeletesAProfileOverTheProfileCapAndKeepsOneAtIt` over both stores,
`CustodySyncTests` (the counter, and `.oversize` not moving it), `KeyExchangeCacheTests` (the bound, the order, the
refill from the pin store), `CustodyHeadroomTests` (our largest profile under the cap) and
`CustodyVectorTests.everyStepIsReproduced`, which replays knit-next's `custody-v1.json` (33 steps, a 1,024-byte rig
profile cap) over both stores: a profile at the cap kept, one a byte over refused with nothing evicted, and a chat of
that size kept.

## The door

**Context:** custody's refusal stops nothing but custody. Before it, `deliver` decodes a profile's payload for the key
that verifies it, and after it `handleProfile` pins the key, keeps the frame as the sender's proof of key in
`peer_profiles`, caches it in `KeyExchange` and serves it to anyone who asks for that key. Each of those holds the frame
whole, so the cap has to bind before any of them, and on every path that brings a profile in.

**Decision:**

1. **The door is the first statement of `MeshEngine.deliver`,** before `verify`: a frame of type `profile` whose `signed`
   is longer than `stores.custody.limits.maxProfileSignedBytes` is counted and returned from
   (`MeshEngine.refusesOversizeProfile`). It is not decoded, verified, carried, pinned, kept as a proof, cached or
   applied. It asks for no key and parks nothing: a profile never parks, and the door returns before the keyless branch,
   so it is no `.noSenderKey` drop, and a chat parked for that sender stays parked until a profile under the cap lands
   or the park ages it out. It is not a `DropReason`, which would need words a person reads. Exactly the cap is kept,
   only `signed` counts, and other types never meet it.
2. **One path.** Every profile comes through `deliver`: a flooded one from a link, a key request's point-to-point
   answer, a digest round's. None is parked or replayed from custody, and the router reads nothing of a profile's
   payload before `deliver`. The sealed profile (`CTL_PROFILE`) never pins or caches, and its own cap is out of scope.
3. **Still relayed.** The router's relay after `deliver` reads nothing `deliver` decided, so an over-cap profile is
   relayed as before, and the router has marked its id seen, as for a frame that fails `verify`.
4. **The cap is custody's configured value.** The door reads `CustodyStore.limits`, so a rig that lowers custody's cap
   lowers the door's (`MeshEngineProfileCapTests.theDoorReadsCustodysConfiguredCap`).
5. **Stored proofs over the cap go, and the pin stays.** `PeerStore.deleteProfileFrames(longerThan:)` deletes every
   `peer_profiles` row whose `signed` is longer than the cap, run by `MeshEngine.sweep` (so at the start and every
   600 s) with custody's value. The SQL store's clause is `length(signed) > ?`: `signed` is a `BLOB`, so `length` counts
   bytes. The pin is only its key, which stays valid, so it stays; it holds no proof to hand on, as a contact card's pin
   holds none, until its sender's next profile under the cap arrives. No migration: the rule is a function of the row.
6. **The cache never holds one, whatever runs first.** `KeyExchange`'s `storedProfile` read answers `nil` for a kept
   proof over the cap, so a key request served before the first sweep finds nothing to serve and asks on the requester's
   behalf, as for a key it lacks.
7. **One counter.** `MeshEngine.profileOversizeRefused` is the door's count plus `CustodySync.profileOversizeRefusedCount`.
   A profile the door refuses never reaches custody, so each is counted once; custody's part is our own profile and
   nothing else in practice. `Mesh.profileOversizeRefused` and `status`'s `profileOversizeRefused` read it. The door logs
   at `.debug`, `mesh refused <id8> (profile): <n> signed bytes over the profile cap`, never the payload.

**Consequences / limits:**

- A sender whose every profile is over the cap stays unpinned on an upgraded node: their other frames are dropped for
  want of a key, each may ask for it, and each answer is the same over-cap profile, refused again. The key request's
  cooldown and the answer budgets bound that.
- In a mixed fleet an older node pins such a sender and an upgraded one does not; an older node keeps serving the proof
  it holds, and upgraded nodes refuse it each time.
- The door runs before `verify`, so an unsigned frame can move the counter. It is a count only, and the router had
  already spent the frame's id on it, as it does for any frame that fails `verify`.

**Kept true by** `MeshEngineProfileCapTests` (exactly the cap pins, its status cut to 100; one byte over, flooded or
point to point, leaves no pin, proof, cache entry or custody row, no `.noSenderKey` drop, counts once and is relayed; a
lowered cap moves the door; a parked chat waits through an over-cap profile and lands on an in-cap one; two engines,
a carrier without the cap flooding and serving an over-cap profile, refused each time, and the in-cap twin pinning; a
kept proof over the cap is never served and the start's sweep deletes it while the pin stays),
`RepositoryTests.theSweepDeletesAProofOfKeyOverTheProfileCapAndKeepsThePin` over both stores,
`MeshControlTests.statusCarriesTheDetails`, and knit-next's own frames from `keyed-v1.json`: `aliceProfileAtCap`
(8,192 bytes of `signed`) re-encodes exactly and pins, and `aliceProfileOverCap` (8,193) is refused at the door
(`KeyedVectorTests`, `MeshEngineProfileCapTests`).

## The photo ceiling

**Context:** a profile names its photo by hash, and every node that pins the profile fetches the photo and shows it as
that peer's face. A pushed photo was kept to 1 MiB, but a photo fetched because a profile named it was kept to the 8 MiB
attachment ceiling, and a held blob of any size was adopted. Both platforms encode their own photo at 256 pixels,
quality 90. A 256-pixel noise image, the worst case for JPEG, encodes to at most 79,162 bytes with
`DeviceImageCodec`'s parameters (sRGB, 8 bits, high interpolation, ImageIO JPEG at 0.9), measured on the Mac's macOS
27.0.1 ImageIO, not on an iPhone. The rule is the paired contract's section 6 (revision 5), as knit-next ADR
2026-10.jgeg records it: a profile photo over 1,048,576 bytes is never kept or shown as a face, and each such hash is
fetched at most once per holder per session.

**Decision:**

1. **One constant.** `FileIntake.maxAvatarBytes`, 1,048,576, Android's `MAX_AVATAR_BYTES` beside
   `MAX_INCOMING_FILE_BYTES`. `LinkManager.Configuration.maxAvatarFileBytes` defaults to it, and the engine reads it.
2. **The link reports a file past its limit.** `FileIntake.Event.overLimit` is raised only when the limit the owner gave
   binds: on a chunk, or at a header whose declared whole blob (offset and size, each compared before the sum) is over a
   limit below `maxFileBytes`. A file the shared room cut short, or another header cut off, stays `.abandoned`, and
   names no holder. An attachment is never refused at its header, as Android's `begin` refuses none. Whether passing
   the limit marks the sender is decided once, at the header, beside the limit (`LinkManager`'s `IntakeCeiling`,
   Kotlin's `Ceiling` from `ceilingOf`, `FileIntake.kt:344-363` at knit-next `a0b52f865`): only an ATTACHMENT in
   `acceptFiles`' `photoOnly` set as its header is read, under a ceiling below `maxFileBytes`, marks. A pushed AVATAR
   never does, nor does an attachment under Android's ceiling, and a want made photo-only or widened mid-stream does
   not change what a stream already begun means. For a stream that marks, the link hands
   `LinkManager.Event.fileOverLimit(hash, from:)` to the engine with the link's own node id; for any other it hands
   nothing (`refuseOver` returns before `markHolder` when `!limit.marks`, `:388-398`). Every one is dropped and counted
   in `filesRefused`. The log keeps its line and appends `: over its limit`, then Android's facts (`overCeiling`,
   `:372-386`): `link <id> file <key12> dropped before its end: over its limit of <n>B, <KIND> <size|?>B[ from <off>]
   from <peer>`.
3. **A want's kind.** `wantBlob` and `OwnWant` take a `BlobExchange.WantKind`. A want of ours of `.photo` is
   `Want.photoOnly`; any other want of ours of the same hash (a row's want, an attachment) clears it for the want's
   life, so the larger limit wins. A neighbour's ask (an echo, or an ask on our want) never moves it, or a holder passed
   over could lift it by asking us for the hash; and our photo want on a want only asks made, the first want of ours on
   it, makes it photo-only (`Want.ownRecorded`, Kotlin's `ownWant`: `recordWant` and `mergeCeiling`, `BlobExchange.kt:2211`
   and `:2233-2253` at knit-next `a0b52f865`). Promoting an echo whose bytes are arriving is not a want of ours recording
   (Kotlin has none: its own want returns at on-the-way, `:295`), and `restartFromZero`'s fresh want is ours, an
   attachment's (`:2151`). A photo want of a hash refused this session records nothing and changes no standing want
   (`want`, `:289`): `MeshEngine.wantBlob` and `wantBlobs` check it before the on-the-way check, so it promotes no
   arriving echo either. The cleartext profile's want and the re-want's advertised branch pass `.photo`, the
   latter `.attachment` only when a row the re-want takes names the same hash: a message request's row, or a room post
   outside the bound, is no row the collector names, so an attachment want for it would fetch an over-ceiling photo at
   8 MiB only to let it go again, every re-offer. The sealed profile's want passes `.photo` too, through
   the cleartext profile's `followAdvertisedPhoto`.
4. **The links keep a photo-only want to the ceiling.** `MeshTransport.acceptFiles` takes a third set, `photoOnly`,
   kept to `maxAvatarFileBytes`; `syncAcceptedFiles` sends it whenever any of the three sets moves.
5. **Holder-keyed refusal, Android's shape.** A holder whose stream for the want passes the ceiling (an ATTACHMENT
   the link kept under the photo-only ceiling at its header, Decision 2), or whose `blobhas` claims a size over it, for
   a photo-only want: (hash, holder) is marked for the session in `PhotoRefusals`, the holder joins the
   cycle's failed holders, a standing ask on it is withdrawn, and every later step, re-want and new want leaves it out of
   its queries, asks and pulls (`BlobExchange.askable`). Each want also keeps the holders it passed over, at most 64
   (`Want.passedOver`, `BlobExchange.maxPassedOver`; Kotlin's `passOver` and `MAX_PASSED_OVER`, `BlobExchange.kt:491-521`
   and `:3002`), copied from the session's marks in the order they were made at every step while it is photo-only, so a
   mark `PhotoRefusals` has since dropped never lets that live want ask the holder again. The want goes on to the others, and with none left it sits as an
   exhausted want does. No holder's signal refuses the hash outright, not even the want's author's (contract
   revision 5): the author is whoever advertised the hash, and any peer can sign a profile naming someone else's photo,
   so the author is marked as any holder is. The holder is the link's node id the ask went to, never a signer.
   `PhotoRefusals` keeps at most 1,024 pairs and 1,024 refused hashes, the oldest dropped first, and the engine forgets
   both at every start, the `Mesh`'s after a stop included. A relink under the same node id stays marked. Counted in
   `BlobCounts.photosOverCeiling`, `photosOverCeiling` in `status`, and logged as
   `blob photo <hash8>… from <holder> <why>: passed over`. A pushed AVATAR cut off at the ceiling is none of these: it
   answers no want, so it marks nobody, withdraws no ask (no `blobcancel`), steps no want and moves no count, even with
   a photo-only want of the same hash standing (contract `ios-avatar-push-mark`).
6. **No resume past the ceiling.** A photo-only want's `blobreq` never names an offset past the ceiling: such a prefix
   is dropped and the ask is from byte 0.
7. **Adoption is the backstop.** `isAdoptablePhoto` reads `size(of:)`, false when unread or over the ceiling.
   `photoFrom`, the sealed `photo()` and `adoptAvatar` show only an adoptable blob. A held blob over it is declined
   (`declinePhoto`): refused as a photo for the session, since held bytes prove the size, and then released, which removes
   it unless a message row or a carried frame names it. An echo's bytes that land over the ceiling are declined but not
   released: its asker is still to be served, and the 30-minute sweep of unnamed blobs takes them after.
   `blobsTheRowsName` decides a peer's shown or advertised hash by what we hold: a held blob is named unless its size is
   over the ceiling, whatever the session refused, so a later in-ceiling push of the same hash stays as a face; a blob
   not held is named unless it is refused, which decides only whether a file of it is taken in. A failed size read keeps
   it named.
   **A face adopted before the ceiling is cleared, shared law** (knit-next ADR 2026-10.jgeg, Android's
   `sweepLocalStorage`): the 600 s sweep, and so the start, clears every peer's shown photo whose held blob is over the
   ceiling, refuses the hash as a photo for the session, and releases the blob. The pin
   stays, and the monogram shows. The advertised hash stays named in the row but no want or re-want fetches it again.
   `receiveFile` rejects an AVATAR push, or a photo-only ATTACHMENT, over the ceiling whatever link brought it.
8. **Echoes are their askers'.** An asker's ask for a refused or marked hash makes an echo as before. An echo nobody
   else wants stays at the attachment ceiling: the asker's want is its own. Our photo want of a refused hash leaves it
   alone (`BlobExchange.kt:289`); our photo want of any other hash makes it photo-only, and its marked holders are left
   out of its steps (`:2233-2253`).

**Consequences / limits:**

- A neighbour that lies about a photo's size, or streams junk under its hash, costs one fetch from that neighbour per
  session, the author included; it cannot hide a photo an honest holder carries. Only held bytes refuse a hash.
- A feed already running can't be stopped from the receiving end (`FramedLink.kt:474`, knit-next ADR nsr7, #197): its
  bytes keep arriving until its END and are read past, not kept.
- An echo nobody of ours wants as a photo can still pull an over-ceiling blob through for its asker, bounded by the echo
  budget (ADR 2026-10.7kxj), and that blob is never shown here as a face.
- A forged profile naming a large attachment's hash as its photo makes a node that is pulling that attachment through as
  an echo, with no want of its own, cap it at 1 MiB: each holder sends one cut copy per session and is passed over, and
  the asker is not served from here. Android pays the same.
- A blob over the ceiling that a carried frame names in the clear (`carriedBlobs`, a sealed profile's hash beside its
  seal) stays held until that frame leaves custody, and is never shown.
- The refusals are per session: after a restart each marked holder may cost one more fetch.
- **A neighbour asked to pull a photo through fetches it whole.** The `blobreq` is frozen and can't carry the ceiling,
  so a neighbour we ask to pull a photo through wants it under the attachment's ceiling and fetches all of it before it
  serves us, and only then does our link stop at 1 MiB and pass that neighbour over. The cost exists today, and Android
  records the same.
- A file's limit is fixed at its header. When a want of the same hash as an attachment arrives while a photo-only copy
  is streaming, that stream is still cut at 1 MiB, its `fileOverLimit` is ignored (the want is no longer photo-only, so
  nobody is passed over), and the holder is asked again at its floor: one extra fetch, as on Android.
- **A pushed AVATAR's cut-off steps no want.** A photo-only want the push met waits for a timer it armed earlier or for
  the 60 s re-offer, and nothing is stranded: the pusher is still asked at the want's own pace. Android does the same:
  the header skip (`FileIntake.kt:155-156`) and the chunk abort (`:222-226`) both call `refuseOver`, which returns at
  `:396` (`if (!limit.marks) return`), and `skip()` and `abort()` send nothing to `BlobExchange`. Even a marking cut only
  records `partials.markHolder`, which `passOver` reads at the next step (`BlobExchange.kt:491-520`). This port steps a
  marked want at once (`MeshEngine.overPhotoCeiling`), as before.
- Group photos and message attachments keep their ceilings. Block behaviour is unchanged.

**Headroom:**

| Headroom | iOS | Android |
| --- | --- | --- |
| Largest cleartext profile, `signed` bytes (cap 8,192) | 949 | 1,017 |
| Own photo, 256 px, quality 90 (ceiling 1,048,576) | 79,162 (noise, macOS ImageIO with `DeviceImageCodec`'s parameters; not on device) | 54,775 |

**Kept true by** `FileIntakeLimitTests` (the header and chunk cases, the room's abandon), `LinkFilePhotoCeilingTests`
(a photo-only fetch past the ceiling reported once with nothing landed, a push refused at its header naming nobody,
Kotlin's `aPushedAvatarOneByteOverThePhotoCeilingKeepsNothingAndOneAtItIsKept` and
`anAvatarHeaderDeclaringMoreThanThePhotoCeilingIsSkipped` under a standing photo-only want, the mark read at the header
both ways, the shared room reporting nobody), `MeshEngineAvatarPushMarkTests` (a push past the ceiling through a real
link marking, withdrawing and stepping nothing while the fetch's own stream still passes the holder over), `BlobPhotoCeilingTests` (the flag, an ask that never lifts it, our photo want on an echo, a promoted echo and a fresh
want from zero, a refused photo want leaving an echo alone, both signals, the author passed over like any holder, a
passed-over holder that asks, the want's own passed-over set outliving the session's mark and its 64 bound, a held
copy's refusal, the bound), `MeshEngineAvatarCeilingRowsTests` (a message request's row never makes the photo an attachment, an in-ceiling
push of a refused hash kept past the sweep, an echo's oversize bytes served to its asker) and
`MeshEngineAvatarCeilingTests` (two holders, the author passed over, a peer advertising another's photo unable to hide
it, three re-offers that never ask a marked holder, a passed-over holder's `blobreq` leaving the ceiling in place, a
refused photo want answering false with an echo standing, a message's want keeping the attachment limit, an oversize held photo never shown and gone, the pre-ceiling face cleared,
the sealed profile's want under the ceiling, and a sealed profile's oversize held photo never shown and let go once
its unit commits).

