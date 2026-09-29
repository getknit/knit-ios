# Routing, custody and sync

How knit-next floods, deduplicates, carries and back-fills frames at the pinned commit. The numbers here
are cross-platform law, not tuning knobs: if the iPhone bounds its carried set differently from Android,
the two never agree on what each is missing, and every 60-second exchange re-sends frames forever.

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
  group chat are carried only when encrypted. The block list is never consulted.
- **Our own frames count too** (ORIGIN_SELF), our profile included, under the same quotas.
- **An inbound DM to us is custodied,** then purged by our own cleartext receipt (the self-purge).
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
  on every delivery, repeats included.
- **Room ticks:** `relay = false`, no `sentAt`, a fresh id each attempt, never custodied, sent only over a
  live link. Android sends them to a non-ratchet author for up to 24 h, one per link-up.
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
  decides what to carry and serve, `KnitMesh/Receipts/AckSync.swift` owes the room ticks, and
  `KnitMesh/Recovery/` holds key requests and parked frames (ADR 2026-09.p6nb).
- **Two stores apply them:** `MemoryCustodyStore` for the Linux peer and the tests, and `SQLCustodyStore`
  (`KnitStoreSQL`) for the app. Both run `CustodyRules` over their live rows and the same `CustodyStoreTests`
  (ADR 2026-09.nyya).
- **Ids compare by their bytes** (`ExactKey`), never by Swift's `String` equality (ADR 2026-09.jc2x). That
  includes the sender and group buckets and the ids an eviction removes. The SQL store keeps every id as a
  UTF-8 `BLOB`, which SQLite orders exactly as BINARY orders text.
- **The early-receipt memo** is `CustodySync`'s `earlyReceipts`, counted in the `status` footprint as
  `earlyReceipts`. knit-next checks it again after the custody write, for a receipt handled on another dispatcher
  meanwhile; the engine here is synchronous (ADR 2026-09.gq84), so it checks once.
- **Where the iPhone differs from Android, all of it delivery-side, none of it custody:**
  - a cleartext DM is dropped, not shown;
  - a `blobreq` is ignored rather than asked onward, since the MVP holds no blobs;
  - group frames are carried and relayed, never shown;
  - every receipt and room tick is cleartext, because this build cannot seal one.
