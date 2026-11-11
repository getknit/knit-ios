# Wire format

What a frame looks like on the air, as knit-next's `mesh/protocol/Wire.kt` encodes it at the pinned commit
(`.agents/context/knit-next.md`). The rules for changing any of it are in `.agents/rules/interop.md`.

## The CBOR profile

knit-next uses kotlinx-serialization-cbor 1.12.0 (1.11.0 before `97e1747f`) with `useDefiniteLengthEncoding = true`,
`encodeDefaults = false` and `ignoreUnknownKeys = true`. For a Swift codec that means:

- **Map keys are text strings**, equal to the Kotlin property names, written in declaration order.
  Decoding must not depend on order; encoding should match it, so our bytes diff cleanly against the
  goldens.
- **Default-valued fields are omitted**, never written as null. An absent field and a null field are not
  the same thing.
- **Byte arrays are byte strings** (major type 2). Integers use the shortest encoding, booleans are `F4` and
  `F5`, and no encoder writes a tag.
- **Unknown keys are ignored** on decode. That is how the wire grows.
- **The exception is the v3 DM plaintext** (`MessageContentV2`), which uses integer keys and raw ids. KnitWire
  has its codec, and the ratchet seals and opens v3 toward a peer whose profile carries `CAP_CRYPTO_V3` (ADR
  2026-10.5sk9).

Decoding is looser than any encoder. Since knit-ios #14, KnitWire reads every field the way kotlinx does, so both
platforms refuse and carry the same frames, apart from the gaps the last item names (`Decoder.kt` in the 1.12.0
sources). That includes the fields Android typed at `cad69c77b` (knit-ios #42, #43): a chat's declared languages,
`lang` and `reads` (`Int?` under `"l"` and `"r"` in `ChatContent` and `MessageContent`, labels 18 and 19 in
`MessageContentV2`), read and dropped; a transfer's `md` (`List<Long>?`), checked and dropped; and ctl 11's `pk`
(`PresenceKeyPayload`), typed.

- **A nullable field is null** when its value is the byte `F6` or the single byte `A0`. An empty map written any other
  way (`B8 00`, `BF FF`) goes to the field's own decoder, which fails unless the field's type has no required field.
- **An `Int` is a 64-bit reading,** wrapped, then held to −2³¹ through 2³²−1 and truncated to 32 bits: `1A FFFFFFFF`
  reads as −1, and `3B FFFFFFFFFFFFFFFE` as 1. A `Long` wraps with no range check.
- **Tags are skipped** before every value and every key, a run of them included. A tagged `F6` is not null, so it
  fails a nullable field.
- **An integer key in a named map is skipped** as unknown. A key of any other non-text kind fails. In a labelled class
  (the v3 plaintext) a negative key with argument `n` is the label `~n`, the bits of kotlinx's wrapped `Long`: `20`
  (−1) is unknown and skipped, and `3B FFFFFFFFFFFFFFFE` reads as label 1.
- **An indefinite-length text's chunks are joined, then checked** as UTF-8 once, as `CborText.chunks` and kotlinx
  do, so a code point may straddle two chunks (knit-next ADR 2026-10.qjap).
- **Every copy of a duplicated key is decoded,** and the last one wins.
- **Keys compare by their UTF-8 bytes,** as Kotlin's `getElementIndex` compares strings, never by Swift's canonical
  equivalence: a key spelled with a Kelvin sign is unknown, not `attachmentKey` (ADR 2026-09.jc2x).
- **Depth and trailing bytes match where it counts for custody.** Android walks the signed envelope and every payload
  it checks with `CborText` before kotlinx (`Wire.kt:1086`, `:1097`). The walk refuses nesting past 32 levels,
  counting each tag, and any byte after the top-level item, as `CBOR.decode` does. Android skips that walk for the
  outer `WireEnvelope`, the sealed plaintexts and the public key bundle, and three gaps stay there:
  - A value nested past 32 levels under an unknown key reads on Android and is refused here. Matching it would let a
    large frame recurse deep enough to exhaust the stack.
  - One stray byte after the top-level item reads on Android, whose parser has already read it ahead when it checks
    for leftovers (`Cbor.kt:86-95`), and is refused here.
  - Bad UTF-8 in a sealed plaintext shows on Android as U+FFFD and drops here as `cannotOpen`.

  For a key bundle, the first two mean we never pin that sender. All three are recorded, not closed.
- **One parser split reaches the checked paths too.** Under an unknown key, `CborText` takes a two-byte simple value
  below 32 (`F8 00` to `F8 1F`) and an indefinite map with an odd number of items (`BF 01 FF`), and so does kotlinx's
  `skipElement`. RFC 8949 calls both malformed, and `CBOR.decode` refuses them, so Android carries a signed frame
  holding one and back-fills it to us until it expires. Off the checked paths kotlinx also skips additional info 28 to
  30 on majors 0, 1 and 7. The fix belongs in `CborText`, whose own doc says it refuses CBOR that isn't well formed,
  not in loosening this parser (knit/knit-next#217).

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
| `BlobHasItem` | `hash`, `state` |
| `BlobProgressContent` / `BlobCancelContent` | `hash`, `held`, `ms` / `hash` |
| `VideoInfo` (Android's) | `durationMs`, `width`, `height`, `poster` |
| `BadgeEntry` (Android's) | `w`, `r` |
| `ScopeConfigPayload` (Android's) | `spools`, `maxFrames`, `ttlMs`, `maxBlob`, `version` |

A known key whose value has the wrong CBOR type fails Android's decode too. Android drops a sealed message with one as
`DECRYPT_FAILED` and does not carry a chat frame with one (`canCarry`, `InboundPipeline.kt:2320-2329`). KnitWire
checks the type of every key Android types, including the ones it does not model, so it refuses the same frames: a
room post's `video`, `attachmentName`, `attachmentKey` and `"s"`; a sealed message's `video`, `cl`, `sc`, `xf`, `"s"`
and badges; the v3 plaintext's labels 16 and 17 and `pr`'s label 8; and a blob request's `fastOnly` (knit-ios #14).
The open path drops a sealed message that fails before its commit, so its chain index stays unspent, as on Android.

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

- `ChatContent { body = "", mentions = [], attachmentHash?, attachmentMime?, enc: EncEnvelope?, replyTo: ReplyRef?,
  attachmentSize: Long?, video: VideoInfo?, attachmentName?, attachmentKey?, s: bstr = empty }`. A room post declares
  `attachmentSize`, its photo's plaintext length, from 1,000,000 bytes (knit-next ADR 2026-10.hmfe); a sealed frame's
  shell never does. This port models none of the last four, but checks each one's type (knit-ios #14): a short video
  (knit-ios #9), a commons post's file name and key (knit-ios #11), and the body's formatting (knit-next ADR
  2026-10.p95v), whose byte string is the same under `MessageContent`'s `"s"` and the v3 plaintext's label 17.
- `ProfileContent { name, status, avatarHash?, pubKey?, deviceTag?, protoVersion?, capabilities?, prekey?, version?, openToChat = false, loraNode?, loraKey? }`
- `ReceiptContent { ackId }`, `ReactionContent { messageId, emoji? }`, `KeyReqContent { nodeIds }`,
  `BlobReqContent { hash, offset?, pull?, until?, fastOnly? }`, `TypingContent { groupId? }`. Android sets `fastOnly`
  only toward a Wi-Fi Aware route, so an iPhone never gets one.
- `BlobHaveContent { hashes }` and `BlobHasContent { items: [BlobHasItem { hash, state, size?, held?, eta? }], load?, re? }`,
  the holder query and its answer (knit-next ADR 2026-10.6e5t). `state` has no default, so it is always written, `0`
  included: NONE 0, HAVE 1, SENDING 2, FETCHING 3, and PARTIAL 4, which is reserved. A state a build does not know is
  never taken for HAVE.
- A `blobreq`'s `offset` is how many bytes of a cut transfer the asker kept, echoed by the `FILE_HEADER` that answers
  it (knit-next ADR 2026-10.wtyc, ADR 2026-10.w6rn). This port serves the tail from `1...length` and any other
  offset as the whole file, and asks with the length of a cut prefix it kept. The `FILE_HEADER` then writes `offset`
  after `size`, which is the tail's bytes, and only when it is past 0. A receiver splices the tail onto its kept
  prefix, and refuses a resumed header that names more than it kept.
- A `blobreq`'s `pull` is how many phones deep the ask may still pull the blob through, the receiver counted, and its
  `until` is the root's deadline for that, epoch ms on the frame's clock (knit-next ADR 2026-10.2drc, ADR
  2026-10.8hek). Every ask carries its want's budget, 0 included, and its deadline when it has one. An absent `pull`
  reads as 1, a fetch only.
- `EncEnvelope { v = 1, nonce, ct, keys: [WrappedKey { to, wk }], r: RatchetHeader?, g: GroupRatchetHeader? }`

`ProfileContent.pubKey` is effectively required: a profile without it is dropped. Keep every field we
decode, including the ones we don't use (`prekey`, `loraNode`), so a profile we carry for others is never
thinned.

## Registries

These only ever grow. A value is never reused, even after it is retired.

- **Frame types are strings:** `chat`, `groupupdate`, `groupleave`, `profile`, `receipt`, `reaction`,
  `blobreq`, `blobhave`, `blobhas`, `blobprog`, `blobcancel`, `keyreq`, `typing`, `commons`, `talk`, `link`.
  `meshpost` is burned. `link` (knit-next `aac6ee180`, `Wire.kt:104`) is a direct Internet link's signal, which only a
  spool's signal lane carries: Android never floods one whatever its envelope says (`MeshRouter.kt:214`) and spends no
  key request on one (`NO_KEY_REQUEST_TYPES`). This port has no `.link` yet, so a re-wrapped copy would pass the relay
  gate (`MeshEngine.swift:285`) and could spend a key request (knit-next.md, "Owed here").
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
  | 7 | scope config (`CTL_SCOPE_CONFIG`, a spool's relays and bounds) |
  | 8 | profile |
  | 9 | transfer |
  | 10 | call (`CTL_CALL`, only toward a profile carrying `CALL`) |
  | 11 | presence key (`CTL_PRESENCE_KEY`, knit-next ADR 2026-11.xp6d; named form only, the plaintext padded to 128 bytes, its map under `pk` naming `g`, `k`, `ng`, `nk` and `p`), only point to point over a proven link, `relay = false`, toward a peer carrying `BLIND_ADVERT` |

  An unknown value is a silent no-op. This port decodes ctl 11's `pk` as kotlinx does (`PresenceKeyPayload`: `g` and
  `k` required, `ng`, `nk` and `p` nullable, a wrong kind failing the whole content), keeps it named-only
  (`MessageContentV2.encode` refuses it), never sends one, and acts on none yet; Android sends it none until this port
  claims `BLIND_ADVERT`.
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
  | `0x4000` | `CALL` | `0x8000` | `WALKIE` |
  | `0x10000` | `LORA_DIRECT` | `0x20000` | `INET_LINK` |
  | `0x40000` | `LINK_PROOF` | `0x80000` | `BLIND_ADVERT` |

  `DOORBELL` and `BLOB_HAVE` sit above the advert's 8 bits and are read from the HELLO alone. Android sends `0x2FFF`
  since `403cd861`, and `0xFFF` before it; it never claims `DOORBELL`. `CALL` and `WALKIE` ride its signed profile
  alone, in a build that wires calls (`CallWiring.kt:137-138`), so a 2.10 release profile reads `0xEFFF` while its
  HELLO still reads `0x2FFF`. This port claims neither, so Android offers an iPhone no call. Only the signed profile copy gates anything, and only at send time: `RATCHET`
  (with a prekey) picks v2 DMs, `CRYPTO_V3` picks v3, `INLINE_ACK`, `FILES`, `LINK_PREVIEW` and
  `DIRECT_TRANSFER` gate features. The rest are diagnostic.

  `LORA_DIRECT` and `INET_LINK` are Android's, and this port names neither. `LINK_PROOF` (ADR 2026-11.hpmt, knit-next
  ADR 2026-11.264w) is in `Capabilities.local`, so the HELLO reads `c215f` (`c315f` with the doorbell) and the signed
  profile `0xC015F` or `0xC000F` (`0xC055F` or `0xC040F` in a debug build with link previews, which signs
  `CAP_LINK_PREVIEW` too; ADR 2026-11.hcvg). It is read twice: from the HELLO, to decide whether a link runs the proof exchange,
  and from the signed profile, whose copy makes a peer proof-capable. A HELLO carrying it carries a fourth field,
  `n<32 lowercase hex>`, a fresh nonce, and a link where both HELLOs carry it exchanges tag-8 `PROOF` records before it
  registers (`ble-transport.md`, "The handshake").

  `BLIND_ADVERT` (knit-next ADR 2026-11.xp6d) says "I read tags": Android's HELLO and every signed profile carry it
  since `0285a5c8b`, and no privacy decision rests on it. Android sends `TAG_NEXT` (record tag 9) and ctl 11 only to a
  peer carrying it, and while it blinds refuses a dialer whose HELLO lacks it. This port claims it in
  `Capabilities.local`, so in every HELLO and every profile it signs, since the reader landed: tag 9 and ctl 11 both
  read here (ADR 2026-11.sv5t; `ble-transport.md`, "The advert"). Builds before it sent `4215f` and `0x4015F`.

## Signatures, ids and clocks

- **Signature:** a raw 64-byte Ed25519 signature over exactly the `signed` bytes. Verification runs over
  the bytes as received, against a key whose node id is the frame's `senderId`:
  - our own frames verify with our own key;
  - a `profile` verifies with the key inside its own payload;
  - everything else verifies with the sender's pinned key.
- **Unsigned frames** come in two shapes: the blob traffic, `blobreq`, `blobhave`, `blobhas`, `blobprog` and
  `blobcancel`, each `relay = false` (`FrameType.isUnsignedPointToPoint`), and the v3 live-link tick (a
  `relay = false` DM-form `chat` addressed to us). Anything else with an empty `sig` is refused. Android also admits
  an unsigned `talk` addressed to it, a walkie chunk its ratchet seal authenticates; this port relays one and never
  opens it.
- **Frame id:** 16 random bytes, base64url, no padding, 22 characters. Profiles use
  `profile-<nodeId>-<publishedAt>`, and Android's walkie chunks (`talk`) the first 11 characters of a fresh id. An id
  is not opaque on the way in: `Router.admit` refuses any frame whose id is not its type's shape, as Android's router
  does (`FrameId.admits`, ADR 2026-10.h7xw), so a new id shape is a wire break.
- **`ttl` is a hop limit, not a time.** A frame is relayed only while `hops < min(ttl, 8)`. Android refuses a
  `WireEnvelope` whose `ttl` or `hops` is negative (`decodeWire`, `Wire.kt:1075-1076`, knit-next `9c56cd31`). KnitWire
  reads any 32-bit value, so the refusal is owed.
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
6. Every nullable nested type keeps at least one required field, since kotlinx reads an empty map as `null` there.
7. An envelope id has the shape its type is minted with (`FrameId.admits`), so a new id shape is a break.

Adding a custodial type is a flag day, not an additive change. Breaking changes wait in knit-next's
`docs/NEXT_WIRE_BREAK.md` so one future break carries them all.

## What this build sends and understands

Groups joined the MVP's frames on 2026-09-30 (ADR 2026-09.n393), profile photos on 2026-10-03 (ADR 2026-10.nh55),
photos in chats the same day (ADR 2026-10.6cas), the blob holder query on 2026-10-05, and the ratchet on 2026-10-19
(ADR 2026-10.b4yk).

| Frame | We send | We receive |
| --- | --- | --- |
| `profile` | on every new link, on edit, and at least every 12 h; `avatarHash` names our photo | pin, verify, carry; the photo shows once its bytes are held |
| `chat` DM, `enc.v = 1` | toward a peer whose profile carries no `CAP_RATCHET`, and toward every peer with the ratchet's switch off | yes, always |
| a photo in a DM or a group | sealed with `AttachmentCrypto`: the hash, type and key inside the sealed content, the hash alone beside `enc`; from 1,000,000 bytes its plaintext length too, sealed (`attachmentSize`, knit-next ADR 2026-10.js2p); a picture held already goes as its blob and key, or a room picture under its own hash with no key (ADR 2026-10.f3mv) | kept with the message, its blob wanted, or held from our own sealed copy when a key-less one's author was in that chat; opened in memory with the key when shown |
| a photo in a room post | `attachmentHash` and `attachmentMime` in the clear, and `attachmentSize` from 1,000,000 bytes; the blob is the photo | kept with the post, its blob wanted |
| `chat` DM, `enc.v = 2` or `3` (the ratchet) | toward a peer whose profile carries `CAP_RATCHET`: v3 when it also carries `CAP_CRYPTO_V3` and the content has a compact form, v2 otherwise (ADR 2026-10.b4yk) | yes, with the switch on (`crypto.md`) |
| `chat` room post (no recipient, no group) | yes, signed and cleartext | yes |
| `chat` group message, `enc.v = 1`, roster in `group` | while any other member lacks `CAP_RATCHET` or a valid prekey, or with the switch off: wrapped to each keyed member | yes, after the roster rules (`GroupRoster`) |
| `chat` group message, `enc.v = 2` (the group ratchet) | when every other member's profile carries `CAP_RATCHET` and a valid prekey, and the epoch's seed seals to each of them (ADR 2026-10.b4yk) | yes, with the switch on (`crypto.md`) |
| `groupupdate`, empty payload, roster in `group` | on rename | yes: name and roster |
| `groupleave`, `GroupLeaveContent`, no `group` | on leave | yes: the sender departs |
| `receipt`, `relay = true`, `sentAt` set | our DM acks | yes: ✓✓ on our DMs |
| `receipt`, `relay = false`, no `sentAt` | room and group ticks over the link | yes: Android's room and group ticks to us |
| `keyreq` (`relay = false`, signed) | when a sender's key is missing | answer with cached signed profiles |
| `blobreq` (unsigned, `relay = false`, `sentAt` 0, no `offset`, the want's `pull` and `until`) | to the best holder a query found, or blind: the author, then the hop the frame came from, then every other neighbour once a 5 s grace is up; a cycle at most every 45 s, on a link-up or the 60 s tick (knit-next ADRs 2026-10.f7gg and 2026-10.6e5t) | serve it if held, as FILE records of kind ATTACHMENT, the whole file whatever `offset` says; otherwise want it with one hop less of its `pull`, never asking the asker back that cycle, unless that leaves less than none or its `until` has passed; taken only from the link that carried it when its sender is that link's peer, as the other four blob-control types are (`blobControlNotFromLink`); never flood it (ADR 2026-10.ym9y, ADR 2026-10.8hek) |
| `blobhave` (unsigned, `relay = false`, `sentAt` 0, ≤ 32 hashes) | in every build, the app's and knit-peer's (`MeshConfiguration.queriesBlobHolders`, ADR 2026-10.m9uq's amendment of 2026-10-09): to each neighbour whose HELLO carries `CAP_BLOB_HAVE`, one frame per neighbour per step | answer every one, from the link that carried it and only when its sender is that link's peer, within 16 a burst and one a second; never flood it |
| `blobhas` (unsigned, `relay = false`, `sentAt` 0) | the answer: NONE, HAVE with the size, SENDING, or FETCHING per hash, our `load` and the query's `re`; never an `eta` | taken only from a neighbour queried this cycle for a hash it names; a state this build does not know is never HAVE; a SENDING `eta` holds the ask on that holder until then plus 30 s, the `eta` taken as at most 15 min (ADR 2026-10.ds45) |
| `blobprog` (unsigned, `relay = false`, `sentAt` 0, `BlobProgressContent`: hash, held, ms) | while a file streams in, kept or skipped, to its sender: on every chunk that brings 2 KiB, at least every 500 ms, and once more 500 ms after chunks no report carried; every 2 s with the window off. Only when that link's HELLO carries `CAP_BLOB_HAVE`, an iPhone included (knit-next ADR 2026-10.nsr7, ADR 2026-10.xwjc) | counted, from the link that carried it and only when its sender is that link's peer; it clocks the window of the file we feed that peer (`FeedWindow`, ADR 2026-10.xwjc); never flood it (ADR 2026-10.ds45) |
| `blobcancel` (unsigned, `relay = false`, `sentAt` 0, `BlobCancelContent`: hash) | to a neighbour our ask is on, when the fetch falls back from it while it is linked, and to every neighbour asked but the one the blob came from once it lands; never at a blind round's widening, nor to one that said at or after the ask that it lacks the blob; once per ask, and only where `blobprog` goes (knit-next ADR 2026-10.nsr7) | from the link that carried it and only when its sender is that link's peer: a copy of the blob still waiting on that link comes off it, and the serve memo forgets it; one already streaming goes on; never flood it (ADR 2026-10.ds45) |
| `reaction`, `relay = true`, `sentAt` set, no recipient, no group | when the user reacts, in any thread, toggling as Android does (ADR 2026-10.ehe6) | yes: one emoji, last writer wins per message and reactor; never acked or notified |
| a reply's quote, `ReplyRef` | in `ChatContent.replyTo` in the clear for a room post, in `MessageContent.replyTo` sealed for a DM or a group, never in a sealed frame's shell; the snippet cut at 120 UTF-16 units as Android's composer cuts it (ADR 2026-10.mn29) | kept with the message as it came, first copy wins, `author` and `snippet` clipped to 256; a cleartext quote beside `enc` ignored; nothing checked against the original |
| a message's mentions, `Mention` | in `ChatContent.mentions` in the clear for a room post, in `MessageContent.mentions` sealed for a DM or a group, never in a sealed frame's shell; only those whose `"@" + name` the sent body holds, each once (`MessageMention.carried`, ADR 2026-10.nbhj) | kept with the message, first copy wins, only those whose token the 2000-unit body holds; a cleartext list beside `enc` ignored; "mentions me" by node id alone |
| `typing`, signed, `relay = false`, a fresh id, `TypingContent`: `{}` for the room or a DM, `{groupId}` for a group, a DM's `recipientId` set | each keystroke that leaves words, at most every 8 s a thread, only while Knit is in front: a DM's to its peer's link alone, the room's and a group's to every link; never carried, relayed or rung (ADR 2026-10.29z9) | held 12 s, pushed out by each cue and ended by the sender's message: a group's from its roster when we hold it, a DM's when it names us, the room's from anyone; a blocked sender's dropped, an undecodable one counted |
| `talk`, unsigned, Android's walkie chunks | no | relayed like any frame, never opened, carried or asked a key for |
| `commons`, unknown types | no | carry and relay where custodial; never crash |

FILE records, which are not frames, go both ways too:

- **Out:** our photo as kind AVATAR at each new link, and any blob we serve as kind ATTACHMENT, a chunk at a time
  behind the radio's report (ADR 2026-10.h6zz).
- **In:** a peer's own AVATAR push, kept when it is the photo its signed profile names. An ATTACHMENT is kept when it is
  a blob this node wants and its bytes match its hash (ADR 2026-10.ym9y), such as a message's photo.

## Golden vectors

knit-next's `vectors/wire-v1.json` holds 85 fixtures, which `GoldenVectorTest.kt` reads. The inputs are generated:
`bytes(n, seed)[i] = (7 * i + seed) & 0xFF`, with `frameId(seed)` and `nodeId(seed)` built from
`bytes(16, seed)`. They are codec vectors only, with placeholder ids like `"m1"`; none carries a real
signature or ciphertext. The bundle probe (`sigPub = bytes(32, 10)`, `hpkePub = bytes(32, 20)`) derives node
id `cswad43wmlont27jr4tyvu63i4`.
