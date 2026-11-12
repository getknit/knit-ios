---
id: "2026-11.6zhj"
slug: a-link-seals-everything-after
title: "A link seals everything after an ephemeral key exchange"
date: 2026-11-09
topics: [ble, crypto, security, interop]
---

# ADR 2026-11.6zhj — A link seals everything after an ephemeral key exchange

Status: Accepted (2026-11-09). Mirrors knit-next ADR 2026-11.8mhs (knit-next #286, option 1), a paired change
(`link-seal`, knit-ios #51) led by Android, mirrored ahead of the pin from knit-next's `feat/link-seal` at
`554458ef9`, merged to its `main` as `5fdaf5da8`, which is the pin since (`.agents/context/knit-next.md`). It closes knit-ios #39 for every sealed link. Amends ADR 2026-11.hpmt, ADR
2026-10.mueg, ADR 2026-09.xzpt, ADR 2026-11.sv5t and ADR 2026-09.3ch7.

**Context:** every link record crossed insecure L2CAP in the clear. A radio in range read, without linking, the HELLO
with the node id, the PROOF that ties the id to its keys, the DIGEST, every frame's envelope (who talks to whom) and
the cleartext frames. The link proof (ADR 2026-11.hpmt) bound the id to its key but not to the channel, so a node in
range of both peers could forward a real handshake and sit in the middle of a proven link (hpmt's accepted relay).

**Decision:** two upgraded builds run an ephemeral X25519 exchange before anything else, and everything after it
rides AES-256-GCM under keys from that exchange. The PROOF signs both ephemeral keys. Links with Android v2.10.x and
v2.11.0 stay as they were. No iOS build had shipped, so no older iPhone needs the plain form, but every Android build
up to v2.11.0 does, and the responder takes both first records for good.

- **The bit.** `Capabilities.linkSeal = 0x100000` is in `Capabilities.local` (`0x1C015F`), only beside `linkProof`. The
  HELLO reads `1c215f`, or `1c315f` with the doorbell. The profile's copy is informational, and nothing decides from
  it. hpmt's republish on a capability change runs once after the upgrade.
- **The advert flag.** `AdvertPayload.linkSealFlag = 0x10`, bit 4 of byte 23, is written exactly when our HELLO carries
  the bit (`writtenFlags(dialsGattPeers:seals:)`), so it reaches the GATT value and knit-peer's service data. A
  23-byte payload reads it as absent. Android learns that an iPhone seals only from this flag in its GATT payload: the
  advert's capability byte is full.
- **The dial decision.** A dialer opens sealed exactly when the advert it dials from carries the flag
  (`DialTarget.seals`, copied in `dial()`, tag dials alike). Nothing else feeds it: not the profile, and not earlier
  links.
- **The records** (`LinkRecord`): tag 10 `keyShare`, exactly 32 bytes, and tag 11 `sealed`, `[0x0B][u32be len][ct ‖
  tag16]` with `len` from 17 to 65,552. Both lengths are checked from the header, as tag 9's is. Tag 12 stays unknown.
  On a plain link, tag 10 or 11 drops the link as an unknown tag did before.
- **The keys** (`LinkSeal`, KnitCrypto). `ss = X25519(own ephemeral, peer's)`, refused when the point is low-order or
  `ss` is all zero (`SharedSecret.isAllZero`, as `RatchetCrypto.dh` does, since swift-crypto and CryptoKit return zeros
  where Tink throws). HKDF-SHA256 with `ikm = ss`, `salt = eD ‖ eR`, info `knit/link/v1/seal/d2r` or `…/r2d`, 32
  bytes, in `RatchetCrypto.hkdf`'s argument order. The dialer seals with d2r and opens with r2d. The ephemeral key is
  `Curve25519.KeyAgreement.PrivateKey()`, the system's secure generator, through `LinkManager.makeEphemeral`, never the
  mesh's seedable `random`. `derive` spends it whatever the outcome.
- **The halves.** `LinkSealer` and `LinkOpener` are final classes whose counter advances under a `KnitSync` lock, so
  even a shared reference can't seal two frames under one nonce. The nonce is `00000000 ‖ u64be(n)`, implicit, one per
  frame from 0. The AAD is the frame's five header bytes. Either half refuses frame 2^48 and is spent after its first
  failure. Keys, secrets and the private half print as redacted in every description and mirror.
- **The v2 transcript** (`LinkProof.Form.sealed(KeyShares)`): `"knit/link/v2/proof" ‖ role ‖ eD ‖ eR ‖ u32be(len hD) ‖
  hD ‖ u32be(len hR) ‖ hR`. `KeyShares` is one value for the salt and the transcript. The form is a required argument
  with no default, chosen by how the channel opened, never by a HELLO's bits. v1 stays byte for byte, and neither form
  verifies as the other.
- **The exchange** (`LinkManager+Seal`). The dialer queues its KEY_SHARE and waits in a new stage, `awaitingKeyShare`,
  with its own 5 s deadline and its own put-off. On the responder's KEY_SHARE it derives, hands the radio its sealer,
  and writes its HELLO sealed. A responder whose first record is a KEY_SHARE writes its own at once, before any
  admission, installs its sealer in the same radio call, derives, and re-arms its deadline and put-off for the sealed
  HELLO. A plain HELLO first takes today's path. hpmt's exchange then runs unchanged inside the seal, except that both
  sealed HELLOs must carry `linkProof`, `linkSeal` and a valid nonce (checked before `judgeClaim`), and the PROOF signs
  v2. A sealed link is always a proven link.
- **Where the seal sits: in the shared `LinkOutbox`, as each entry leaves the queue.** The link manager keeps the
  opener on `Channel` and hands the sealer to the radio (`Radio.writeKeyShare(_:sealer:to:)` and `Radio.seal(_:with:)`,
  requirements with no default, so no radio or wrapper can drop it and write plain). `appendKeyShare` puts the outbox
  in a state that holds everything queued behind the KEY_SHARE until the sealer arrives. `next(atMost:)` seals one
  frame of at most `frameBytes - 21` plaintext once, caches the ciphertext and slices it by the write limit, so a
  partial or refused write is offered again and never sealed twice. A nil from the sealer fails the outbox, and the
  radio closes the channel. `removeAll()` on a sealed outbox fails it rather than turning it plain. Levels, the 4 MiB
  bound and `wroteFileRecord` stay in plaintext bytes.
  - **The digest slot keeps working.** `offerDigest` swaps only an entry not yet sealed, so ADR 2026-09.3ch7's
    coalescing runs on plaintext and the counter follows socket order. Turning the swap off on sealed links would have
    brought back the stale-digest queue that made a post wait 393 s. Coalescing in the link manager would have needed a
    poll, since the radio reports no drain, and would have let frames pass the digest. Sealing in the link manager
    rules the swap out, because a swapped digest would need a nonce already used.
  - The radios, which ADR 2026-09.6es2 keeps to moving bytes, now also run the seal. The code lives once, in
    `LinkOutbox` in KnitMesh, and Linux tests it; `L2CAPLink` and BlueZ only pass the sealer along in FIFO with their
    writes.
- **Failed seals count only bytes that arrived and were wrong.** These are: another record where the responder's
  KEY_SHARE belongs, a bad KEY_SHARE or one `derive` refuses, a non-SEALED record after the exchange, a frame out of
  range or that fails to open, an inner tag 10 or 11, a first inner record that isn't a HELLO, and a sealed HELLO
  missing a bit or the nonce. An EOF or a timeout is never a failed seal (contract revision 1). It is today's no-reply
  refusal, logged `link chN got no key share from <shown>` in `awaitingKeyShare`, never `timed out`. A failed seal
  logs `link chN seal failed for <shown>: <why>`, retires a dialer with a backoff and a responder without, and counts
  `linkSealFailed`. A PROOF failure inside the seal counts `linkProofFailed` only. `LinkTrace` sees only ciphertext and
  sizes on a sealed channel.
- **No plain link between two sealing builds** (contract §7). On a plain-form link the responder refuses before
  replying when both HELLOs carry `linkSeal`, and the dialer refuses after the reply, with no PROOF and a backoff. This
  happens in `admit`, `answered` and `answeredTag`, before R1, and counts `linkSealRefused` once.
- **The stale-payload forget** (contract §7, revision 1). This is `GattPayloads`' fourth rule, `noReply(at:)`. When a
  plain dial made from a GATT payload ends with no reply, our HELLO carried the bit and the payload lacked the flag,
  the payload is forgotten once per address, so the next dial reads it fresh (`Radio.dialGotNoReply(at:)`, by
  address, since both radios have dropped the channel's address by `.closed`).
- **Counters** `linksSealed`, `linkSealFailed` and `linkSealRefused`, on `LinkManager`, `Mesh` and `MeshControl`'s
  status, under the names Android reports. A sealed link counts `linksProven` too.
- **knit-peer.** `FloodRadio` and `LyingRadio` stay where they were. They now sit above the outbox seal, so their
  junk, rewrites and injections go out sealed in order, and both modes still test something between sealing builds.
  `--seal on|off|downgrade|plain-reply` sets `LinkManager.sealSwitch`, a trial switch the app never sets, like
  `Impostor`. `--flip-sealed-bit` corrupts one sealed frame after link-up in BlueZ, the only layer that sees
  ciphertext. `--psm` gives a fresh PSM at each switch (contract revision 2), because the kernel hands out the same
  dynamic PSM at every start. The legacy impostor skips the exchange and airs no flag.

**Consequences / limits:**

- **What a sealed link guarantees.** A listener that only listens sees two random public keys, then ciphertext, sizes
  and timing. A relay can't sit in the middle of a sealed link: it can't compute the keys, and swapping its own in
  breaks a signature. An injected, replayed or reordered record fails to open and closes the link. Between phones that
  hold each other's profile, or have proven each other this run, a relay also can't downgrade the link (§7 and R1).
- **At a first meeting a relay can still pose as an old build to both phones** (contract revision 3). It strips the
  flag and rewrites both plain HELLOs to v2.10.x shape, with no proof bit, no seal bit and no nonce. Nothing is signed
  then, so §7 never fires, and the link comes up plain and unproven, readable by the relay. R4 closes it once either
  profile reaches the other. This is hpmt's profile-less claim, already accepted.
- Links with Android v2.10.x and v2.11.0 stay plain. Their HELLO, PROOF and envelopes stay readable, and v2.11.0 links
  stay relayable as hpmt accepted. The exposure ends for each pair once both phones run a sealing build.
- Sizes and timing still show. There is no padding.
- What is outside a link stays readable: the advert, the iPhone's GATT payload and the doorbell write. A phone that
  links on purpose still learns the node id, since the seal keeps out only a listener.
- Every inbound dial costs the responder an X25519 key, one DH and a 37-byte write before admission, including dials it
  then refuses. A refused dialer learns only the responder's ephemeral key.
- **Link-up takes one more round trip:** KEY_SHARE, KEY_SHARE, HELLO, HELLO+PROOF, PROOF. This amends hpmt's
  suspension risk and mueg's put-off cost: a suspended iPhone has one more stage to lose a link in, and each stage can be
  put off once.
- **A stale flag costs a dial.** A peer that upgraded inside the 90 s linger is dialed plain and refused under §7. Rule
  4 then makes the next dial from its GATT payload read the payload fresh. A peer that downgraded inside the linger
  closes on tag 10. The dialer sees no reply and backs off, and a cached payload still carrying the flag isn't
  forgotten by that silence (contract revision 2). Busy, suspended and already-linked iPhones give no reply all the
  time, and forgetting on each would spend Android's GATT read budget. Until an existing rule forgets it, the dialer
  keeps dialing sealed. Only a downgraded iPhone hits this.
- **A BlueZ write that would block after sealing fixes a digest with no byte out.** At most one more stale digest
  queues behind it. That is a bounded few KB, and it never rolls the counter back.
- **A blinded GATT payload carries the flag in its flags byte, as a clear one does.** The writer that blinds it
  (ADR 2026-11.prsp) came before this change merged, so `writtenFlags(dialsGattPeers:blinded:seals:)` sets
  `FLAG_LINK_SEAL` in both forms. Android at the pin reads nothing from a blinded GATT payload, so it learns that a
  blinding iPhone seals only once companion change A11 reads one (the `blind-gatt-reads` contract, §8). Until then it
  dials no blinding iPhone at all, and the iPhone's own dials read the Pixel's flag from its service data. The writer's
  switch is off by default in debug builds and absent from release until A11 merges (ADR 2026-11.prsp).
- No rekeying. The 2^48 frame cap closes a link first.
- **What keeps it true:**
  - Records, flag and outbox: `LinkSealTests`, `LinkProofTests`, `LinkSealWireTests`, `LinkTests` (tag 12 unknown),
    `LinkOutboxSealTests` and `BlueZOutboxTests` (a digest swapped behind a backed-up sealed socket still opens in
    order, and nothing queued before the sealer leaves plain).
  - The exchange: `LinkSealExchangeTests`, `LinkSealRefusalTests`, `LinkSealTagDialTests`, `LinkImpostorTests` (the
    legacy pose) and `LinkPipeProofTests` (a sealed two-engine link).
  - Rule 4 and the radio: `GattPayloadsTests`; `L2CAPLinkSealTests` on Darwin.
  - Vectors: `keyed-v1.json` → `link.seal` from Android; `ios-emitted-v1.json` → `link.seal` from this port.
  - Devices: the contract's T4 to T6.
