# Routing, custody and sync

How knit-next floods, deduplicates, carries and back-fills frames at the pinned commit. The numbers here
are cross-platform law, not tuning knobs: if the iPhone bounds its carried set differently from Android,
the two never agree on what each is missing, and every 60-second exchange re-sends frames forever. The
`blobs-owner` reads it before it writes and the `blobs-reviewer` before it judges (`.agents/rules/owners.md`).

## Flooding

`MeshRouter.kt` and `SeenSet.kt`, in order, for a frame arriving over a link:

1. **Ingress budget, room posts only:** a burst of 240, then 30 a minute per link (`IngressBudget.kt`). A
   refused post is not marked seen, so it comes back later.
2. **SeenSet:** keyed by `RelayEnvelope.id`, a 10-minute window, LRU of 4096. A repeat is dropped here.
3. **Deliver locally,** if the frame verifies.
4. **Schedule the relay**, under the rules below.

The relay rules:

- wait 0–150 ms of random jitter (injected, so tests can pin it);
- cancel once the frame has been heard from 2 distinct neighbours;
- send to every neighbour except those it was heard from;
- relay only while `hops < min(ttl, 8)`, rewriting `ttl` and `hops` and passing `sig` and `signed`
  verbatim.

Our own frames go out at once and are marked seen. A `relay = false` frame is never flooded. The one
exception is a DM-form chat addressed to a peer we hold a live link to, which we hand on that one hop
(ADR 2026-09.wkbk). A frame that does not verify, or whose type we don't know, is still relayed; it is just
not delivered.

`LinkCrossings` keeps a frame from crossing one Bluetooth link twice. Frames are keyed by the first 8
signature bytes as lowercase hex, or `u:<id>` when unsigned, with a 10-minute window, 1024 entries per
link, cleared with the link.

## Custody

A node carries frames for people who are not in range yet. This is store-and-forward.

- **Entry rule** (`InboundPipeline.kt:236`): `verified && isCustodial && (wire.relay || type == "profile")`.
  A profile served point to point through `keyreq` is custodied. A `relay = false` tick never is. DMs and
  group chat are carried only when encrypted. The block list is never consulted: a block stops a frame at
  delivery only (ADR 2026-10.5wgg, after knit-next's ADR 2026-09.bts9).
- **Our own frames count too** (ORIGIN_SELF), our profile included, under the same quotas.
- **An inbound DM to us is custodied,** then purged by our own cleartext receipt (the self-purge). A sealed receipt,
  ours with the ratchet's switch on toward an author who can read one, purges nothing, ours included: the DM stays in
  our custody, and every carrier's, to its TTL. While our custody holds it, our digest lists it, so no back-fill serves
  it to us, but a copy still reaches us two ways, and each past the router's window earns one more sealed receipt, as
  in Kotlin (`InboundPipeline.kt:946-955`). Our quotas may evict it first, and then every holder next to us serves it.
  Or a node that lacks it and links to two holders (a returning phone's or a newcomer's back-fill, or a carrier whose
  quota evicted it) relays the first copy it gets to the other holder before that holder's own copy crosses: a served
  frame floods on (`ForwardSync.kt:14-15`), a serve stamps nothing in the server's seen set, and every node it reaches
  past its router window relays it on, holders included (`MeshEngine.swift:225-237`, `MeshRouter.kt:113-114`). So the
  recipient answers that copy wherever the re-flood finds it, though it still holds the DM.
- **Expiry:** `sentAt + 24 h`, or 6 h for room *chat*. Room receipts, reactions and profiles keep 24 h.
  Frames already dead on arrival, or dated more than 5 minutes ahead, are refused.
- **Quotas**, counted over live rows only, applied in this order (`ForwardRepository.kt:145`):
  - 200 per sender
  - 200 per group
  - 200 for the room
  - 1000 overall
- **Eviction order:** oldest first by `(sentAt ASC, id ASC)`, with the ids compared as SQLite BINARY
  (byte order).
- **Early purge:** a cleartext receipt from a DM's recipient removes that DM and tombstones its id for 24 h.
  Sealed receipts purge nothing.
- **A receipt that arrives before its DM vaccinates the DM on arrival** (knit-next ADR 2026-09.adpz, #100). The
  purge needs the DM's recipient, which only the DM names, so every receipt is also remembered as `(ackId,
  acker)` for the tombstone's 24 h, in a set of at most 4096 (`earlyAcks`). A DM that arrives later, whatever its
  origin, is refused and tombstoned if its cleartext `recipientId` is that acker, before it is authenticated. The
  memo is keyed on the acker, so a receipt from anyone else keeps nothing out. It lives in memory, like the
  tombstones. Two things make this order common. Back-fill serves newest-received first, so a receipt goes ahead
  of an older DM. And a DM's recipient relays it onward like any frame, after the jitter, but sends its receipt
  at once, so its other neighbours hear the receipt first. Before the memo, such a DM was carried to its expiry
  and offered at every exchange to neighbours that refused it: in `iphone-soak` on 2026-09-28 each order left one
  DM behind, and custody never matched (`.agents/context/linux-peer.md`, "What the iPhone's soak showed").

## Sync over a link

- At link-up and every 60 s, each side sends a `DIGEST` record listing every live custody id.
- On receiving the peer's `DIGEST`, a node pushes every live frame the list omits. Each goes out as a fresh
  `WireEnvelope` with `ttl = 8` and `hops = 0`, with `sig` and `signed` copied verbatim. Group frames go
  only to roster members.
- **Android pushes custody only in answer to a DIGEST.** A node that sends none gets no back-fill. A node
  whose digest under-reports gets the missing frames re-pushed at each exchange, though on a Bluetooth link
  `LinkCrossings` lets one frame cross only once in 10 minutes, so the repeat comes that often while the link
  lasts.
- **A link's writer is first in, first out, on both platforms, but holds at most one digest not yet written**
  (ADR 2026-09.3ch7, knit-next's ADR 2026-09.tjfb). A back-fill is queued whole. A digest made while an older
  one still waits takes that one's place, so a slow link writes one current digest behind a back-fill, not one
  per 60 s tick. What the socket already holds goes out as it was: on `hci1` that can still be minutes of
  digests (`.agents/context/linux-peer.md`, "Why the frames were late").

The advert's digest cue is the low 32 bits of an FNV-1a-64 fold (offset `0xCBF29CE484222325`, prime
`0x100000001B3`) over each live id's UTF-8 bytes, XORed across the set. Nothing on BLE reads it, but we
publish it honestly.

## Receipts and ticks

- **Our DM receipt:** type `receipt`, `sentAt = now`, no `recipientId`, `relay = true`, custodied. It is sent
  on every delivery, repeats included. With the ratchet's switch on, toward an author whose pinned profile carries
  `CAP_RATCHET` and a bundle, it is instead a sealed `CTL_RECEIPT` chat to the author, flooded and custodied for its
  day like any DM, carrying up to eleven of that author's room ticks; it purges nothing, ours included. A seal the
  facade cannot make sends the cleartext one in its place, and a store that fails sends neither, as Kotlin's throw
  sends neither (phase P5d, `InboundPipeline.kt:2831-2958`).
- **Room and group ticks:** the cleartext tick is `relay = false`, with no `sentAt` and a fresh id each attempt,
  never custodied, and sent only over a live link. A sealed one is sealed once, with `sentAt` set to now, and every
  send repeats those bytes: over a live link it is `relay = false` and never custodied; escalated, it is originated
  and custodied, as below. Android sends the cleartext tick to a non-ratchet author for up to 24 h, one per link-up.
  It moves a group tick into custody, as one sealed batch, only for an author who can open a sealed one
  (`canSealTickTo`, `MeshManager.kt:2066-2068`; `AckSync.kt`): an iPhone with the ratchet's switch on has opened it
  since P5a. The batch is a DM-form ctl 5 frame that every node carries for 24 h and nothing purges. Ours take the
  sealed form with the ratchet's switch on (phase P5d): P5c ported the ledger that sends it, and P5d's seams seal for
  it.
- **The forged-ack guard:** apply an ack only if the acknowledged message is a room or group message, or if
  the receipt comes from that DM's recipient. At most 128 ids per receipt.
- **There are no read receipts on the wire.** Delivery is the last state a sender sees.

## Key recovery

- **Parking:** a frame from a sender whose key we lack is parked for 2 minutes, at most 512 frames and 4 MiB
  in all, and a carrier's custody quota (200) per sender, so a stranger's whole served backlog parks
  (`PendingInbound.kt`, knit-next ADR 2026-09.9xuu).
- **Serving order:** a digest is answered profiles first, then everything else newest-received first, so a
  newcomer pins each sender's key before that sender's chat arrives (`ForwardSync.onDigest`, the same ADR).
- **The key ahead of a backlog:** when custody holds no live profile of a sender whose frames the reply
  serves, the reply sends that sender's key first, from the pin store and `relay = false`
  (`ForwardSync.keylessSenders`, knit-next ADR 2026-09.g64k). No key goes to the sender itself, or to a peer
  whose digest lists any of our live frames from that sender: it verified that frame, so it has the key.
- **Asking:** a signed `keyreq` with `relay = false` goes to our neighbours, with a 30-second cooldown.
- **Serving:** a holder answers with the signed profile its pin came from, verbatim and `relay = false`, from
  memory or else from the pin store. Android skips a request for its own id, which is why every node pushes
  its own profile at link-up.
- **The pin store** (`peer_profiles`, this port's schema v2 and knit-next's database v16): each pin keeps the
  signed frame it came from. The newest publish stamp wins, clamped to 5 minutes ahead, and an equal or older
  copy never replaces it. Custody is no substitute. The per-sender quota evicts a chatty sender's profile
  first, since it is their oldest frame, and the TTL takes a departed sender's up to 12 h before their last
  posts. Before the store, a restarted carrier served backlogs nobody could read until they expired, and a
  keyreq for them found nobody to answer it. The rows start empty after an upgrade, so a pin made before one
  gets its proof only when that peer's profile next arrives.

## Profiles

- **The id is derived from the publish stamp:** `profile-<nodeId>-<publishedAt>`, with `sentAt` equal to the
  stamp.
- **`version` is the edit clock.** An edit sets `version = max(now, previous + 1)` and a fresh stamp, then
  floods. Every 12 h the profile is republished with a fresh stamp and the same version, which keeps it
  inside the 24-hour custody window.
- **Sign once per stamp and reuse the bytes** (ADR 2026-09.qztx).
- **On receipt:**
  - pin only when the key derives to `senderId`, and never pin our own;
  - refuse a different key for a pinned id;
  - take presentation fields last-writer-wins on `version ?: sentAt`, clamped to now plus 5 minutes;
  - clamp the name to 32 and the status to 100 UTF-16 units.

## In this port

- **Where it lives:** the router is `KnitMesh/Router/Router.swift`, and the custody rules are
  `KnitStore/Custody/CustodyRules.swift`, which every store applies. `KnitMesh/Custody/CustodySync.swift`
  decides what to carry and serve, and `KnitMesh/Receipts/` owes the room and group ticks: `AckSync` and its
  holds, its seams in `TickSealing`, and the engine's wiring in `MeshEngine+Ticks.swift`. The seams' seals and the
  sealed DM receipt are the ratchet's, in `KnitMesh/Ratchet/MeshEngine+RatchetReceipts.swift`. `KnitMesh/Recovery/`
  holds key requests and parked frames (ADR 2026-09.p6nb).
- **Two stores apply them:** `MemoryCustodyStore` for the Linux peer and the tests, and `SQLCustodyStore`
  (`KnitStoreSQL`) for the app. Both run `CustodyRules` over their live rows and the same `CustodyStoreTests`
  (ADR 2026-09.nyya).
- **Ids compare by their bytes** (`ExactKey`), never by Swift's `String` equality (ADR 2026-09.jc2x). That
  includes the sender and group buckets and the ids an eviction removes. The SQL store keeps every id as a
  UTF-8 `BLOB`, which SQLite orders exactly as BINARY orders text, and reads it back with every byte. Before
  2026-10-16 it dropped a leading U+FEFF: our digest listed such a frame without it, a crafted id could stand in for
  the real frame it then named, and the quota's eviction missed the row (ADR 2026-09.jc2x, amended).
- **Android drops that mark,** a custody difference this port keeps on purpose (knit-next #178). knit-next binds ids
  as UTF-16, and SQLite drops a leading U+FEFF there (and byte-swaps the rest after a leading U+FFFE), so on Android
  such an id is one row with its unmarked twin, and its digest lists it unmarked. Dropping it here would port the
  collision. Until knit-next binds ids whole, or both platforms refuse such ids (a paired change), an iPhone sends
  such a frame again to each Android neighbour at every exchange, and a soak that compares custody sets those ids
  aside.
- **The early-receipt memo** is `CustodySync`'s `earlyReceipts`, counted in the `status` footprint as
  `earlyReceipts`. knit-next checks it again after the custody write, for a receipt handled on another dispatcher
  meanwhile; the engine here is synchronous (ADR 2026-09.gq84), so it checks once.
- **Where the iPhone otherwise differs from Android, all of it delivery-side, none of it custody:**
  - a cleartext DM or group message is dropped, not shown;
  - a `blobreq` is never flooded, even one marked `relay = true`, where Android would flood it; it is answered or
    asked onward as Android's `BlobExchange` does (ADR 2026-10.ym9y);
  - with the ratchet's switch off, every receipt and tick, room or group, is cleartext, a ratchet DM's receipt
    included; with it on, they take the sealed form toward an author who can read one (phase P5d);
  - an owed tick, sealed or cleartext, goes only over a live link, at link-up, the 60 s re-offer or the heal. Kotlin's
    best-effort re-sends between, on a doubling back-off, ride the fast plane, and a room tick's ride deadline routes
    only to the spool or the fast plane, so a due ride waits for a link or a carrier (ADR 2026-10.5sk9's P5c amendment);
  - with the ratchet's switch on, a DM ratchet frame to us whose store unit failed is opened again at the next sweep
    from the copy that failed, kept in memory, since custody keeps the first bytes stored under an id and a peer's
    re-seal reuses its id; the copy goes once any copy of its id commits, or once the frame's row exists, read inside
    a store unit, so a failed read keeps it; a first verdict's id is let past the router's dedup once, for a copy a
    neighbour's back-fill brings first (ADR 2026-10.5sk9's P5a amendment);
  - at start, every custodied ratchet DM to us with no row is opened again, where Android leaves such a frame to
    expire, and only to deliver it: a failure is counted under its reason, never toward a reset, and lets nothing past
    the router; a ctl frame from the era the pair holds drops as `DUPLICATE`, and one from an era it has since left can
    open again under that era's draining root for as long as custody keeps it, where a reaction or a profile applies
    nothing.
- **Our own ratchet DM is custodied inside its send unit,** with the switch on (ADR 2026-10.5sk9, phase P5b): the seal,
  the cleared wait and our custody's copy commit together, before the frame goes on the air, which is Android's order
  too (`originateWire`, custody first). A re-seal after a peer's reset flies live and is carried only where custody holds
  no bytes under its id, so custody keeps the first bytes stored under an id here as on Android (`ForwardSync.kt:75`).
  A re-seal reaches only the nodes it meets live whose router has not seen its id within ten minutes. The reopen is
  the failing peer's alone, a relay that carried the original inside that window drops it, and every custody, the
  peer's included, keeps only the original, as in Kotlin. So a peer two hops away does not read DMs that crossed a
  relay within ten minutes before its reset (`RatchetResealReachTests`). The unit's one write in memory, a tombstone
  `CustodySync.admits` may set, is idempotent (`StoreTransactor`'s contract), so custody's copy stays in the unit.
- **Group messages carried before groups showed** are delivered at start-up: the engine replays each live
  group `chat` in custody from someone else that has no message row, oldest first, as Android's
  `replayCustodiedGroupFrames` does (`MeshEngine+GroupRatchetInbound.swift`, ADR 2026-09.n393). One already delivered
  is skipped, so it is not ticked again; its row is read in a store unit of its own, and a read that fails skips the
  frame until the next replay.
- **With the ratchet's switch on, the same replay runs twice more** (ADR 2026-10.5sk9, phase P6a2): every hour, as the
  net under the rest (`replayUndeliveredGroupCustody`, `MeshManager.kt:971`), and at once for one sender's frames in one
  group once that sender's seed is adopted. A group frame that came before its seed is in our custody and our digest, so
  no neighbour serves it again; only these open it. At a group's first sight the ratchet DMs our custody holds from its
  roster open again too, a seed whose park died with the process among them (`replayCustodiedSeedDms`,
  `MeshManager.kt:1772-1830`). Each replay goes past the router, reads custody and writes nothing to it. Custody never
  reads group-ratchet state: a group frame's `NO_KEY`, `AEAD_FAIL`, `BAD_HEADER` or failed unit changes what we deliver,
  never what we carry, and a seed's ack and a key request are ordinary sealed DMs that purge nothing.
- **Our own group form** (ADR 2026-10.5sk9, phase P6b): each seed DM, and the group frame it goes ahead of, is signed
  once and taken into our own custody inside the send's store unit, then flooded once the unit commits, seeds first. A
  seed DM is an ordinary sealed DM, custodied and carried like any other. It never makes a row and is never
  acknowledged, so it purges nothing and every custody keeps it to its TTL. The seed outbox, not custody, records what a
  member holds. A seed the member never acknowledged is sealed again under a fresh id at a link-up, a re-offer, their
  profile, their reset or their key request, floored at 15 minutes per group, member and pairwise root. A send unit that
  fails writes no custody row and sends nothing.
