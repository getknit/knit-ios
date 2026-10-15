# Wire format

What a frame looks like on the air, as knit-next's `mesh/protocol/Wire.kt` encodes it at the pinned commit
(`.agents/context/knit-next.md`). The rules for changing any of it are in `.agents/rules/interop.md`.

## The CBOR profile

knit-next uses kotlinx-serialization-cbor 1.11.0 with `useDefiniteLengthEncoding = true`,
`encodeDefaults = false` and `ignoreUnknownKeys = true`. For a Swift codec that means:

- **Map keys are text strings**, equal to the Kotlin property names, written in declaration order.
  Decoding must not depend on order; encoding should match it, so our bytes diff cleanly against the
  goldens.
- **Default-valued fields are omitted**, never written as null. An absent field and a null field are not
  the same thing.
- **Byte arrays are byte strings** (major type 2). Integers use the shortest encoding, booleans are `F4` and
  `F5`, and there are no tags.
- **Unknown keys are ignored** on decode. That is how the wire grows.
- **The exception is the v3 DM plaintext** (`MessageContentV2`), which uses integer keys and raw ids. KnitWire
  has its codec, but nothing seals or opens v3 yet: the ratchet is dark (ADR 2026-10.5sk9).

A required field that is missing makes Android's decode fail, and the frame is neither delivered nor
carried. The frame is dropped with no error sent back. These fields must always be written, even when empty:

| Type | Required fields |
| --- | --- |
| `WireEnvelope` | `sig` (may be an empty byte string), `signed` |
| `RelayEnvelope` | `type`, `id`, `senderId`, `payload` |
| `ProfileContent` | `name`, `status` (an empty status is the empty text string, `60`) |
| `MessageContent` (named layout) | `body` |
| `EncEnvelope` | `nonce` (may be empty), `ct`, `keys` (may be the empty array `80`) |
| `WrappedKey` | `to`, `wk` |
| `ReceiptContent` / `ReactionContent` | `ackId` / `messageId` |

## Three layers

1. **`WireEnvelope`**, the unit on the radio:
   `{ ttl: Int = 8, hops: Int = 0, relay: Boolean = true, sig: bstr, signed: bstr }`.
   A fresh frame omits `ttl`, `hops` and `relay` because they sit at their defaults, so it encodes as
   `A2 63"sig" 58 40 <64 bytes> 66"signed" 59 …`. A relay rewrites only `ttl = min(ttl, 8)` and
   `hops + 1`; `sig` and `signed` pass through untouched.
2. **`RelayEnvelope`**, the bytes that are signed:
   `{ type: text, id: text, senderId: text, sentAt: Long = 0, recipientId: text?, group: GroupInfo?, payload: bstr }`.
   A DM sets `recipientId`. A group message sets `group`. A Nearby room post sets neither.
3. **The payload**: CBOR inside `payload` that only endpoints read. The types are listed below.

The payload types:

- `ChatContent { body = "", mentions = [], attachmentHash?, attachmentMime?, enc: EncEnvelope?, replyTo: ReplyRef? }`
- `ProfileContent { name, status, avatarHash?, pubKey?, deviceTag?, protoVersion?, capabilities?, prekey?, version?, openToChat = false, loraNode?, loraKey? }`
- `ReceiptContent { ackId }`, `ReactionContent { messageId, emoji? }`, `KeyReqContent { nodeIds }`,
  `BlobReqContent { hash, offset? }`, `TypingContent { groupId? }`
- `BlobHaveContent { hashes }` and `BlobHasContent { items: [BlobHasItem { hash, state, size?, held? }], load?, re? }`,
  the holder query and its answer (knit-next ADR 2026-10.6e5t). `state` has no default, so it is always written, `0`
  included: NONE 0, HAVE 1, SENDING 2, FETCHING 3, and PARTIAL 4, which is reserved. A state a build does not know is
  never taken for HAVE.
- A `blobreq`'s `offset` is how many bytes of a cut transfer the asker kept, echoed by the `FILE_HEADER` that answers
  it (knit-next ADR 2026-10.wtyc). This port reads it and never sends it, and serves the whole file (knit-ios #2).
- `EncEnvelope { v = 1, nonce, ct, keys: [WrappedKey { to, wk }], r: RatchetHeader?, g: GroupRatchetHeader? }`

`ProfileContent.pubKey` is effectively required: a profile without it is dropped. Keep every field we
decode, including the ones we don't use (`prekey`, `loraNode`), so a profile we carry for others is never
thinned.

## Registries

These only ever grow. A value is never reused, even after it is retired.

- **Frame types are strings:** `chat`, `groupupdate`, `groupleave`, `profile`, `receipt`, `reaction`,
  `blobreq`, `blobhave`, `blobhas`, `blobprog`, `blobcancel`, `keyreq`, `typing`, `commons`. `meshpost` is burned.
  - `isReplayable` covers chat, reaction, receipt, groupupdate and groupleave.
  - `isCustodial` is `isReplayable` plus `profile`.
- **`MessageContent.ctl`:**

  | Code | Meaning |
  | --- | --- |
  | 1 | session reset |
  | 2 | group key |
  | 3 | group key request |
  | 4 | group key ack |
  | 5 | receipt |
  | 6 | reaction |
  | 7 | reserved |
  | 8 | profile |
  | 9 | transfer |

  An unknown value is a silent no-op.
- **`EncEnvelope.v`:** 1 is static keys, 2 is the epoch ratchet, and 3 is the compact ratchet. An envelope
  version we cannot open is dropped locally, counted, and still relayed and carried.
- **Capabilities** (a Long in `ProfileContent.capabilities`, the low byte in the advert, hex in HELLO):

  | Bit | Name | Bit | Name |
  | --- | --- | --- | --- |
  | `0x001` | `E2E` | `0x040` | `INLINE_ACK` |
  | `0x002` | `GROUPS` | `0x080` | `FRAME_TRANSCODE` |
  | `0x004` | `REACTIONS` | `0x100` | `CRYPTO_V3` |
  | `0x008` | `STORE_FORWARD` | `0x200` | `FILES` |
  | `0x010` | `RATCHET` | `0x400` | `LINK_PREVIEW` |
  | `0x020` | `FAST_COMPACT` | `0x800` | `DIRECT_TRANSFER` |
  | `0x1000` | `DOORBELL` | `0x2000` | `BLOB_HAVE` |

  `DOORBELL` and `BLOB_HAVE` sit above the advert's 8 bits and are read from the HELLO alone. Android sends `0x2FFF`
  since `403cd861`, and `0xFFF` before it; it never claims `DOORBELL`. Only the signed profile copy gates anything, and only at send time: `RATCHET`
  (with a prekey) picks v2 DMs, `CRYPTO_V3` picks v3, `INLINE_ACK`, `FILES`, `LINK_PREVIEW` and
  `DIRECT_TRANSFER` gate features. The rest are diagnostic.

## Signatures, ids and clocks

- **Signature:** a raw 64-byte Ed25519 signature over exactly the `signed` bytes. Verification runs over
  the bytes as received, against a key whose node id is the frame's `senderId`:
  - our own frames verify with our own key;
  - a `profile` verifies with the key inside its own payload;
  - everything else verifies with the sender's pinned key.
- **Unsigned frames** come in two shapes: the blob traffic, `blobreq`, `blobhave`, `blobhas`, `blobprog` and
  `blobcancel`, each `relay = false` (`FrameType.isUnsignedPointToPoint`), and the v3 live-link tick (a
  `relay = false` DM-form `chat` addressed to us). Anything else with an empty `sig` is refused.
- **Frame id:** 16 random bytes, base64url, no padding, 22 characters. Profiles use
  `profile-<nodeId>-<publishedAt>`.
- **`ttl` is a hop limit, not a time.** A frame is relayed only while `hops < min(ttl, 8)`.
- **`relay`** is set per frame. `false` means point to point: never flooded, only handed on.
- **`sentAt`** is the originator's wall clock in epoch milliseconds, and it is signed. Custody expires at
  `sentAt` plus the TTL. A frame dated more than 5 minutes ahead is refused, and a custodial frame with
  `sentAt = 0` expired in 1970, so nobody carries it.

## Additive rules

From `docs/WIRE_COMPAT.md`:

1. Add only nullable or defaulted fields. New opaque bytes get a type of their own.
2. Never rename, re-type or repurpose a field.
3. Never recycle a type string, capability bit, ctl code or record tag.
4. The signature covers the `signed` blob verbatim. Never re-encode before verifying. Only `ttl` and `hops`
   change in flight, and they live outside the signature.
5. A version gate is a delivery gate, never a relay gate.

Adding a custodial type is a flag day, not an additive change. Breaking changes wait in knit-next's
`docs/NEXT_WIRE_BREAK.md` so one future break carries them all.

## What this build sends and understands

Groups joined the MVP's frames on 2026-09-30 (ADR 2026-09.n393), profile photos on 2026-10-03 (ADR 2026-10.nh55),
photos in chats the same day (ADR 2026-10.6cas), and the blob holder query on 2026-10-05.

| Frame | We send | We receive |
| --- | --- | --- |
| `profile` | on every new link, on edit, and at least every 12 h; `avatarHash` names our photo | pin, verify, carry; the photo shows once its bytes are held |
| `chat` DM, `enc.v = 1` | yes | yes, always |
| a photo in a DM or a group | sealed with `AttachmentCrypto`: the hash, type and key inside the sealed content, the hash alone beside `enc`; a picture held already goes as its blob and key, or a room picture under its own hash with no key (ADR 2026-10.f3mv) | kept with the message, its blob wanted, or held from our own sealed copy when a key-less one's author was in that chat; opened in memory with the key when shown |
| a photo in a room post | `attachmentHash` and `attachmentMime` in the clear; the blob is the photo | kept with the post, its blob wanted |
| `chat` DM, `enc.v = 2` or `3` | no (`CAP_RATCHET` stays off) | carry and relay; cannot open |
| `chat` room post (no recipient, no group) | yes, signed and cleartext | yes |
| `chat` group message, `enc.v = 1`, roster in `group` | yes, wrapped to each keyed member | yes, after the roster rules (`GroupRoster`) |
| `chat` group message, `enc.v = 2` (the group ratchet) | no (`CAP_RATCHET` stays off) | carry and relay; cannot open |
| `groupupdate`, empty payload, roster in `group` | on rename | yes: name and roster |
| `groupleave`, `GroupLeaveContent`, no `group` | on leave | yes: the sender departs |
| `receipt`, `relay = true`, `sentAt` set | our DM acks | yes: ✓✓ on our DMs |
| `receipt`, `relay = false`, no `sentAt` | room and group ticks over the link | yes: Android's room and group ticks to us |
| `keyreq` (`relay = false`, signed) | when a sender's key is missing | answer with cached signed profiles |
| `blobreq` (unsigned, `relay = false`, `sentAt` 0, no `offset`) | to the best holder a query found, or blind: the author, then the hop the frame came from, then every other neighbour once a 5 s grace is up; a cycle at most every 45 s, on a link-up or the 60 s tick (knit-next ADRs 2026-10.f7gg and 2026-10.6e5t) | serve it if held, as FILE records of kind ATTACHMENT, the whole file whatever `offset` says; otherwise want it, never asking the asker back that cycle; never flood it (ADR 2026-10.ym9y) |
| `blobhave` (unsigned, `relay = false`, `sentAt` 0, ≤ 32 hashes) | in a debug build, and from knit-peer: to each neighbour whose HELLO carries `CAP_BLOB_HAVE`, one frame per neighbour per step | answer every one, from the link that carried it and only when its sender is that link's peer, within 16 a burst and one a second; never flood it |
| `blobhas` (unsigned, `relay = false`, `sentAt` 0) | the answer: NONE, HAVE with the size, SENDING, or FETCHING per hash, our `load` and the query's `re`; never an `eta` | taken only from a neighbour queried this cycle for a hash it names; a state this build does not know is never HAVE; a SENDING `eta` holds the ask on that holder until then plus 30 s, the `eta` taken as at most 15 min (ADR 2026-10.ds45) |
| `blobprog` (unsigned, `relay = false`, `sentAt` 0, `BlobProgressContent`: hash, held, ms) | every 2 s of a kept file's chunks, to its sender when that link's HELLO carries `CAP_BLOB_HAVE` and not `CAP_DOORBELL` (knit-next ADR 2026-10.nsr7) | counted, from the link that carried it and only when its sender is that link's peer; nothing here measures a feed; never flood it (ADR 2026-10.ds45) |
| `blobcancel` (unsigned, `relay = false`, `sentAt` 0, `BlobCancelContent`: hash) | to a neighbour our ask is on, when the fetch falls back from it while it is linked, and to every neighbour asked but the one the blob came from once it lands; never at a blind round's widening, nor to one that said at or after the ask that it lacks the blob; once per ask, and only where `blobprog` goes (knit-next ADR 2026-10.nsr7) | from the link that carried it and only when its sender is that link's peer: a copy of the blob still waiting on that link comes off it, and the serve memo forgets it; one already streaming goes on; never flood it (ADR 2026-10.ds45) |
| `reaction`, `relay = true`, `sentAt` set, no recipient, no group | when the user reacts, in any thread, toggling as Android does (ADR 2026-10.ehe6) | yes: one emoji, last writer wins per message and reactor; never acked or notified |
| a reply's quote, `ReplyRef` | in `ChatContent.replyTo` in the clear for a room post, in `MessageContent.replyTo` sealed for a DM or a group, never in a sealed frame's shell; the snippet cut at 120 UTF-16 units as Android's composer cuts it (ADR 2026-10.mn29) | kept with the message as it came, first copy wins, `author` and `snippet` clipped to 256; a cleartext quote beside `enc` ignored; nothing checked against the original |
| a message's mentions, `Mention` | in `ChatContent.mentions` in the clear for a room post, in `MessageContent.mentions` sealed for a DM or a group, never in a sealed frame's shell; only those whose `"@" + name` the sent body holds, each once (`MessageMention.carried`, ADR 2026-10.nbhj) | kept with the message, first copy wins, only those whose token the 2000-unit body holds; a cleartext list beside `enc` ignored; "mentions me" by node id alone |
| `typing`, signed, `relay = false`, a fresh id, `TypingContent`: `{}` for the room or a DM, `{groupId}` for a group, a DM's `recipientId` set | each keystroke that leaves words, at most every 8 s a thread, only while Knit is in front: a DM's to its peer's link alone, the room's and a group's to every link; never carried, relayed or rung (ADR 2026-10.29z9) | held 12 s, pushed out by each cue and ended by the sender's message: a group's from its roster when we hold it, a DM's when it names us, the room's from anyone; a blocked sender's dropped, an undecodable one counted |
| `commons`, unknown types | no | carry and relay where custodial; never crash |

FILE records, which are not frames, go both ways too:

- **Out:** our photo as kind AVATAR at each new link, and any blob we serve as kind ATTACHMENT, a chunk at a time
  behind the radio's report (ADR 2026-10.h6zz).
- **In:** a peer's own AVATAR push, kept when it is the photo its signed profile names. An ATTACHMENT is kept when it is
  a blob this node wants and its bytes match its hash (ADR 2026-10.ym9y), such as a message's photo.

## Golden vectors

knit-next's `vectors/wire-v1.json` holds 61 fixtures, which `GoldenVectorTest.kt` reads. The inputs are generated:
`bytes(n, seed)[i] = (7 * i + seed) & 0xFF`, with `frameId(seed)` and `nodeId(seed)` built from
`bytes(16, seed)`. They are codec vectors only, with placeholder ids like `"m1"`; none carries a real
signature or ciphertext. The bundle probe (`sigPub = bytes(32, 10)`, `hpkePub = bytes(32, 20)`) derives node
id `cswad43wmlont27jr4tyvu63i4`.
