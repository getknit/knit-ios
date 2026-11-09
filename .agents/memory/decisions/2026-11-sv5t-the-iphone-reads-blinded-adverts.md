---
id: "2026-11.sv5t"
slug: the-iphone-reads-blinded-adverts
title: "The iPhone reads blinded adverts"
date: 2026-11-07
topics: [ble, mesh, privacy, wire, crypto]
---

# ADR 2026-11.sv5t — The iPhone reads blinded adverts

Status: Accepted (2026-11-07). Mirrors the reader half of knit-next ADR 2026-11.xp6d and its five amendments
(knit-next #285), at the pin `cad69c77b`; knit-ios #42, with #43 folded in. Android leads and has merged, so no vector
moves here.
Amends ADR 2026-09.6es2 (who dials is judged on advertised forms), ADR 2026-10.6eyf (the head start toward a blinded
peer), ADR 2026-10.mueg (a seek dial to a tag), ADR 2026-11.hpmt (a tag dial requires a proof) and ADR 2026-09.xzpt (a
blinded GATT payload is a stranger).

**Context:** since xp6d an Android debug build airs a rotating tag in advert bytes 1–16 with `FLAG_BLINDED` (`0x08`),
not its node id. The tag is the `zzzz` prefix and 108 bits of `HMAC-SHA256(presenceKey, "knit/advert/v1/slot" ‖ owner
id ‖ u64be(slot) ‖ u8(restart))`, a slot being 15 minutes, and a direct contact holding the key resolves it. Release N
ships the readers and the keys; release N+1 turns writing on and waits on this reader. At `a180338` the iPhone read a tag
as a node id (`NodeId(bytes:)` never fails), and every per-peer map keyed on it:

- each tag was a new peer, with a new dwell and backoff streak, and an address entry nothing pruned but
  `forgetEverything`, about 96 a day per blinding neighbour;
- a link to a blinding phone scored −127 at the budget, its RSSI read under a real id that was never heard;
- the head-start and seeking dials went to tags, and Android refused both as `blind=legacy` (its HELLO lacked
  `CAP_BLIND_ADVERT`), where `Role.dialer(NodeId)` would have failed the reply anyway;
- so a backgrounded iPhone with no link could never link to a blinding phone, which after N+1 is every Android.

**Decision:** the iPhone reads tags, and stays a clear phone. CoreBluetooth gives no service data, no advertising sets
and no say in the address's rotation, and the iPhone's id rides its GATT payload, so its writer is a later ADR
(knit-next `NEXT_WIRE_BREAK.md` item 13).

- **The wire.** `AdvertPayload` reads `FLAG_BLINDED`, and drops a blinded payload whose bytes lack the prefix; a clear
  one stays an id whatever its bytes. `Hello` reads `t` and `a` behind a valid nonce, in any order, as exactly the
  letter and 32 lowercase hex digits, a letter appearing twice being absent; it writes `a` on every dial and never `t`.
  `LinkRecord` reads tag 9, `TAG_NEXT`, exactly 16 bytes, and nothing here writes it. `BlindTag` derives tags in
  KnitCrypto. ctl 11's `pk` is typed as kotlinx types it, with #43's `lang`, `reads` and `md`.
- **Resolving a form** ports `AdvertAliases`, `ExpectedTagTable`, `FormKeys`, `DialKeys` and `KeyChurnLimiter` with
  their constants, less Kotlin's own-tag step, since this port airs no tag (the writer's ADR brings it back): direct
  contacts' expected tags over the window (the last 8 hours of slots and the next half hour, every restart), then
  claims learned on proven links (a tag dial's proof, `TAG_NEXT`), then hints (a dialer's `t`). An unresolved form is held under a handle, `~zzzz…<n>`, which is also what every log line prints.
  Presence, addresses, the PSM and backoff follow the resolved id or the handle, so a rotation never makes a new peer
  of a contact and never leaves a stale PSM.
- **Who dials.** The iPhone is clear, so `AdvertOrder.iDial` never sends it to a blinded advert. Its own overrides
  stand and dial a tag when they do: ADR 2026-09.6es2's exception (a peer that reads no GATT payload cannot find us,
  so we dial it), ADR 2026-10.6eyf's head start (a flagged peer that would dial us, given 24 s first) and seeking, which
  dials whatever the order. A tag dial carries `a` = the tag, expects no id, requires a proof, and takes the proven id.
  Its failure is booked on the tag and the address, never on the id the reply named.
  **Amended 2026-11-07:** a tag dial whose responder proves an id this node refuses (knit-peer's `deny-link`) is closed
  before our PROOF, so neither side registers a link, and books no backoff, since the refusal is our policy and a
  streak would outlive `allow-link`. Its `.tag(handle, address)` key is marked instead, and that tag at that address is
  not dialed again while the id stays refused: one dial per rotation, address and mesh start, and one more after the
  tag goes 90 s unheard or the cap lets its handle go. The lab iPhone on `1d6affd` redialed such a tag at every
  advert, 1 to 3 s apart.
- **The responder** honours a proof-offering dialer's `t` and `a` in its order check, so a blinding Android whose real
  id sorts below ours is admitted. It records the dialer's `t` as a hint for the link. The iPhone has no responder rows
  of its own: Android's held-link row is inert while a phone's own form is clear, and the legacy-dialer row is the
  blinding side's.
- **The one departure from xp6d: a hint suppresses the iPhone's dials.** Android lets a hint suppress nothing, because
  the dial it costs is healed by the held-link row: the peer refuses with no reply and resends its tag over the held
  link, and the resend becomes a claim. That row never fires on an iPhone's link, which carries `CAP_DOORBELL`
  (`BleAdmissionPolicy.heldLinkRow`'s `!heldDoorbell`). A blinding Android dials every clear advert, so it judges an
  iPhone's dial out of order: it refuses the dial when it heard the iPhone within 12 s, and otherwise, against a held
  link 30 s old or more, replaces its link with it. The iPhone, keeping its older link, would then close the newer, and
  both links would be gone. So a sighting attributed to a linked id is busy: by key while that id holds a proven link,
  by claim while the claimant's link is the one held, and by hint while the hint's own link is held. As a safety net, a
  tag dial that proves an id we already hold a proven link to keeps the new link and retires the old one, as Android's
  replace does. Every dial to a blinded advert is a tag dial, booked on the tag's handle and the address, whether a key
  resolves it or not.
  **Amended 2026-11-11:** a claim whose link has ended yields to the hint the same id gave for the same tag on the link
  held now. Before this, a peer that dialed back in after a drop was redialed on its own tag until the old claim
  lapsed, up to a rotation period plus the linger: the dead claim answered first and held nothing off, and nothing
  healed it, since the held-link row skips a doorbell link. The lab saw six refused redials in six minutes
  (`linux-peer.md`, the writer's dongle runs). A dead claim and a live hint that name different ids still answer by the
  claim.
- **The presence keys, received only.** A ctl 11 is stored inside the ratchet open that delivered it, from any sender
  with a peer row who is not us, under Android's era rule (`PresenceKeyPolicy.receive`: a new active root replaces the
  held keys, a drain never starts an era, at most three kept). Only direct contacts' keys are listed to the radio:
  DM-kind ids the user accepted, verified or wrote to, less anyone blocked by id or by device tag, and less us. That is
  `Acquaintances` with blocks applied. iOS has no commons, and with no Remove contact or unaccept (un-verify and delete
  both keep the thread accepted), only a block shrinks the set today; it unlists the contact at once and deletes its
  keys. A session's first pass deletes every non-contact's keys.
- **The bit.** `CAP_BLIND_ADVERT` (`0x80000`) joins `Capabilities.local` only once tag 9 and ctl 11 both read, since
  Android sends both to any peer whose HELLO or pinned profile carries it and does not resend a ctl 11 the peer dropped
  until its next generation, root or restart.

The alternative a reader reaches for first is a full mirror, minting and sending the iPhone's own keys too. Until the
iPhone airs a tag nobody can use them, and each ctl 11 tells a listener on a link read in the clear (knit-next #286)
that the two phones are direct contacts. The maintainer chose receive-only on 2026-11-07; the sender, the generation
clock and #42's backup question go with the writer ADR. Mirroring Android's hint rule exactly was weighed too: it would
cost an iPhone a refused or link-replacing dial at every rotation of every linked stranger.

**Consequences / limits:**

- **What it does not stop.** The iPhone's GATT payload and its HELLO name it in the clear, as before. A device that
  advertises a tag can be dialed by a seeking iPhone, which writes its HELLO before any proof.
- **A forged hint.** A linked Sybil telling us a stranger's tag holds off our dials to that stranger while its link is
  held, one stranger per link. A flagged stranger at the front still dials us itself (it reads our GATT payload); an
  unflagged one, or any stranger while the iPhone is in the background, cannot link to us until the Sybil's link ends.
  A contact's key outranks any hint. Android accepts the same residual for claims. Since 2026-11-11 it covers a Sybil
  that claimed the tag on a link since ended and tells it again when it dials back in.
- **A peer that missed its announcement.** A rotation the iPhone heard of from nobody, with the peer held, leaves the
  new tag unattributed; a dial to it is refused, or replaces the link once (the safety net). Until the bit ships, every
  rotation is one: Android sends `TAG_NEXT` only to a peer carrying it.
- **A locked hour's announcements.** Android writes `TAG_NEXT` without ringing the doorbell, so a suspended iPhone reads
  a backlog of them at its next run and keeps only the newest of the read. Back at the front in the last few minutes of a
  slot (a quarter to a third of the time), that is the next slot's announcement, and the one for the tag on air is
  dropped: a stranger's current tag stays unattributed (a contact resolves by key). The head start, or 6es2's exception
  toward an unflagged phone, then dials it once, Android replaces its link, and the safety net retires ours: one link
  swap per such wake. Keeping the newest announcement per slot, each applied by Android's `TagNextSends.appliesAt`
  against the wall clock at read time, would close it.
- **Before the bit.** While Android blinds it refuses, first and with no reply, every dialer whose HELLO lacks
  `CAP_BLIND_ADVERT` (`RefuseLegacy`), so no build of this change links to a blinding phone by its own dial until the bit
  joins `Capabilities.local`.
- **Recognition needs a link first.** Android sends a key only over a live proven link, so a contact is recognised by
  key only after one link since its last fresh pair or weekly rotation it missed.
- **iOS relaunches far more often than Android,** and two keys die at the next launch that Android does not resend until
  its next generation, root or restart (about a week): a stranger's key stored before the user accepts them (the first
  pass deletes every non-contact's keys, as Android's does), and a ctl 11 whose store unit failed (the replay of a failed
  open lives in memory, and nobody re-serves a `relay = false` frame).
- **No sweep is dated.** The first pass's sweep and the delete at a block write counts, never a log line, so no log says
  when the user blocked someone (xp6d's 2026-11-04 amendment). A store read that fails deletes nothing and lists nothing
  new.
- **Peer rows are never deleted here,** so a stored key goes only by the sweeps above, never with its peer row as on
  Android.
- **Clocks.** A contact whose clock is off by more than the window (ahead by more than 30 to 45 minutes, behind by
  about 8 hours) is not recognised before a link; it links as a stranger.
- **Unresolved forms are not shown.** Diagnostics, `links` and `status.sighted` list resolved and linked peers only.
  Counters report the rest.

**What keeps it true** (to be filled in as each phase lands):

- the wire: `BlindVectorTests` and `BlindTagVectorTests` over `keyed-v1.json`'s `blind` section, `BlindWireTests`,
  `BlindTagTests`, `TypedKeysTests` (#43), `LinkTagNextTests` (tag 9 read past, never written), and
  `BlueZGattRetryTests.aCharacteristicThatHoldsABlindedPayloadIsAStranger`;
- the pure link types, ported case for case from their Kotlin tests but for the own-tag and lonely-dial cases, which
  this port has no code for: `AdvertOrderTests` and `ResponderOrderTests`,
  `ExpectedTagTableTests`, `AdvertAliasesTests`, `AdvertAliasesClaimTests`, `AdvertAliasesBoundTests`,
  `KeyChurnLimiterTests`, `BlindSightingsTests`, `HeldStreaksTests` and `DialKeysTests`, with `AdvertAliasesKeyTests`
  and `DeadlineHeapTests` for the paths the Kotlin tests leave unrun;
- the wiring, on a scripted blinding Android (`BlindingPeer`): `BlindLinkTests` (the tag dial, `RefuseLegacy`, the
  backoff's 10/20/40/80/160 s, the tag flood, `TAG_NEXT`'s newest-of-a-read, the hint rule, the safety net),
  `BlindReaderTests` (BlindReaderTest's Sybil and held-dial cases, `HeldStreaks`, keys across the window's edges and
  skewed clocks, and a key stored for a contact reaching the link manager through `Mesh`), `BlindLinkScoreTests` (a
  hint taken before registration's promotion, a blinding link's score after an unannounced rotation, a crossing that
  books nothing), and `BlindLinkAttributionTests` (a tag dial displacing an unproven claimant, a blinded advert
  without the prefix, a replayer's proven dial, seeking past a dialer still proving itself);
- the presence keys' receive side: `PresenceKeyPolicyTests` (`PresenceKeyPolicyTest`'s receive cases), `OpenedUnderTests`
  (the era each rung commits), `DirectContactsTests`, `PresenceKeyStoreTests` over both stores with a failed unit,
  `SchemaTests`' v22 pin and migration, `MeshEnginePresenceKeyTests` (a contact's key listed, a stranger's held unlisted
  until accepted, refusals that still advance the chain, a block's and a first pass's deletes with no line, the carrier,
  a failed unit's replay, a failed read that deletes and lists nothing), `MeshEnginePresenceKeyEraTests` (a reset's lower
  generation replaces, the old root's late frames drain), `MeshPresenceKeyTests` (the key through the actor to the link
  manager, a tag resolved by key), and the device trial;
- the bit: `BlindWireTests.theBlindAdvertBitIsPinnedAndOurs` (`0x80000` in `Capabilities.local`, the HELLO's `c215f`),
  `LinkTests`' HELLO and profile pins (`c015f`, `c000f` with no prekey), `LinkImpostorTests` and `LinkPipeProofTests`
  (the legacy impostor's `215f` drops it with `LINK_PROOF`), and `MeshControlTests.statusCarriesTheDetails` (`status.capabilities`, the harness's way to tell a
  reader); `test_interop.py`'s `BlindDialedByTest` and `HeadStartLineTest` (a reader meets no ` blind=legacy`
  refusal, its HELLO carries the bit, and its own tag dial shows its `proved` line).

**Amended 2026-11-09, for knit-ios #51 (ADR 2026-11.6zhj, knit-next ADR 2026-11.8mhs):** `FLAG_LINK_SEAL` (`0x10`)
rides both advert forms: Android sets it in the clear form and the blinded form alike, and a tag dial to a blinded
advert carrying it opens sealed, as a clear dial does. This port reads it from either. A future iOS writer that blinds
its GATT payload (knit-next's `NEXT_WIRE_BREAK.md` item 13) would hide the flag from today's readers, which read
nothing from a blinded payload, so that design has to carry the flag some other way. The HELLO now reads `1c215f`
(`1c315f` with the doorbell), and the signed profile `0x1C015F`, or `0x1C000F` with the ratchet off; the legacy impostor's HELLO still reads `215f`, dropping `LINK_SEAL` with `LINK_PROOF`.
