---
id: "2026-11.hpmt"
slug: a-link-proves-the-node
title: "A link proves the node id its HELLO claims"
date: 2026-11-01
topics: [ble, crypto, security, interop]
---

# ADR 2026-11.hpmt — A link proves the node id its HELLO claims

Status: Accepted (2026-11-01). Mirrors knit-next ADR 2026-11.264w (knit-next #232), a paired change
(`link-hello-proof`, knit-ios #25) led by Android, mirrored ahead of the pin from knit-next `c3a191834` and
`fe919013e`, merged to its `main` from `fix/link-hello-proof` (`.agents/context/knit-next.md`). Amends ADR
2026-09.6es2, whose consequences took the HELLO's id on trust, ADR 2026-10.b4yk, whose on-air line said `0x15F`, ADR
2026-10.f5zs, whose meters key on the link's id, and ADR 2026-10.mueg, whose late deadline is put off once per
handshake stage now.

**Context:** a link's identity was the node id its HELLO named, `nodeId|version|capsHex`, and nothing checked it. ADR
2026-09.6es2 accepted that because every frame is signed. But much of what the link manager and the engine do is keyed
on the link's peer rather than on a signed frame: which link is a peer's, which one a re-dial replaces, the link-up
work, and the unsigned blob control a neighbour sends point to point. So the link's id should be as trustworthy as a
frame's signer, wherever both ends can show it.

**Decision:** two phones that both carry `CAP_LINK_PROOF` (`0x40000`) prove their identity keys to each other before
either counts the link as that peer. A phone refuses an unsigned claim to the id of a peer it knows can prove itself,
and a proof displaces anyone squatting on its id. Builds without the bit (Android v2.10.1 and earlier) link as they
did, unproven. The wire change is additive: a capability bit, a fourth HELLO field every shipped build ignores, and a
link record written only to a peer whose HELLO carries the bit.

- **The bit** is in `Capabilities.local`, so the HELLO reads `4215f` (`4315f` with the doorbell) and the signed
  profile `0x4015F` with the ratchet's prekey or `0x4000F` without. The advert carries only the low byte, so it never
  shows there. The profile's copy is the one that says a peer can prove itself: it is signed, so nobody can strip it
  from a peer's profile.
- **The HELLO** gains `n<32 lowercase hex>`, a 16-byte nonce from the system's secure generator
  (`LinkProof.freshNonce`), fresh for each connection attempt, present exactly when the caps carry the bit. Field 3 is
  a nonce only in exactly that form.
- **The PROOF record**, tag 8, carries `sigPub ‖ hpkePub ‖ signature`, 128 bytes. The signature covers
  `"knit/link/v1/proof" ‖ role ‖ u32be(len) ‖ dialer's HELLO ‖ u32be(len) ‖ responder's HELLO`, the HELLOs as the
  bytes that crossed, with the role byte 1 for the dialer and 2 for the responder (`LinkProof`). A verifier checks the
  length, that the keys derive to the HELLO's id, then the signature.
- **The exchange.** The dialer writes its HELLO. A responder that admits a HELLO with the bit and a nonce writes its
  reply and its PROOF in one write, then waits up to the 5 s HELLO timeout for the dialer's PROOF, writing and
  registering nothing until it verifies. The dialer, once both HELLOs carry the bit, needs the responder's PROOF
  next, verifies it, writes its own, and registers. Anything else where a PROOF belongs, a timeout, a bad length, a
  wrong id, a bad signature, or the bit with no valid nonce, is a failed proof: the link closes (the dialer backs off),
  nothing registers, and `linkProofFailed` counts. `.up` and everything that keys on the peer wait for registration.
- **Who must prove.** An id is proof-capable when its stored profile carries the bit, or a link proved it this run:
  a live proven link, or the in-memory set of ids proven since the manager was made. The set keeps at most 4,096 ids,
  Android's `MAX_PROVEN`, in Android's order: a repeat proof makes an id the newest, and the least recently proven
  goes first (`LinkClaims`).
  - **R1:** an unproven HELLO claiming a proof-capable id is refused, the responder before replying and the dialer after
    reading the reply. It runs ahead of today's refusals, so it counts `linkClaimRefused` even where "already linked"
    would refuse it too.
  - **R2:** a proven link is replaced only by one that proves the same id, under today's sighting and 30 s rules, and
    only once the new proof verifies.
  - **R3:** a bit-carrying dialer is admitted pending its proof against a held unproven link claiming its id, whatever
    the order, sighting or age. The held link closes only once the proof verifies, and stays if it fails.
  - **R4:** when an id proves itself, or its stored profile gains the bit (`MeshTransport.peerProvesItself`), every live
    unproven link claiming it closes and counts `linkClaimRefused`.
  - A displacement yields `.down` then `.up` for the id, in one event list, so the engine's link-up work runs again
    for the real peer.
- **The bit can't be taken back by an older frame.** A peer's capabilities follow its presentation version only, never
  the prekey's watermark, and at start a node whose published capabilities differ from those its last profile carried
  republishes as an edit (`OwnProfile.capabilities`, schema v21). Every profile from before an upgrade is then strictly
  older than the first one with the bit.
- **Blob control is attributed only to a link.** `blobreq`, `blobhave`, `blobhas`, `blobprog` and `blobcancel` are taken
  only from the neighbour whose link carried them, under that neighbour's id and `relay = false`, and any other is
  dropped as `blobControlNotFromLink`. Every build of both platforms sends them under its own id, so nothing honest is
  lost.
- **Counters:** `linksProven`, `linkProofFailed` and `linkClaimRefused` on `LinkManager`, `Mesh` and the control
  status, Android's names.
- **knit-peer** proves itself with its file identity, and gains a legacy mode and a claimed id for the device trial
  (`--lying`'s `impostor` command, `.agents/context/linux-peer.md`).

The alternative a reader reaches for first is a key derived from the handshake and a MAC on every record, which would
also bind the link to the proof and close the relayed handshake below. It changes every record after the HELLO, so it
can't be additive toward v2.10.1, and it is the follow-up. Trusting the signed profile's id alone does not help either:
the question is which link a neighbour is on, and only the link can answer it.

**Consequences / limits:**

- **Old Android builds stay unproven,** and another node can still claim their ids under today's rules until each one's
  upgraded profile reaches us.
- **A peer we hold no profile for,** and that hasn't proven itself this run, can be claimed by an unsigned HELLO. The
  squatter goes when the real peer dials with its proof (R3) or its profile reaches us (R4). If the dial order makes us
  the real peer's dialer, promotion skips a peer a live link already claims, so the squatter holds the id until then.
  Dialing through an unproven link is a follow-up: against an honest legacy peer it flaps the real link.
- **A relayed handshake is not prevented.** The proof isn't bound to the radio channel, so a node in range of both
  peers can forward the HELLOs and proofs and sit in the middle, dropping traffic or injecting unsigned blob control on
  that link. It can't forge a signed frame. A key derived from the handshake and a MAC on every record would close it:
  a follow-up.
- **Fresh identities are free.** The proof stops a node from claiming someone else's id, not from minting its own;
  link-slot capture by many ids (knit-next #222) and per-socket metering (knit-ios #24) stay open.
- **A downgraded install** is refused by phones that hold its newer profile until its older profile reaches them.
- **A never-edited profile** (version 0, onboarding not finished) is republished at version 0, not as an edit, as ADR
  2026-10.5sk9 rules for a reinstall: an edit would flood an empty name. Its pre-upgrade frames stay at equal versions
  until onboarding's first edit. No iOS build has shipped, so only a lab device mid-onboarding meets it. Android bumps
  unconditionally.
- **Clock skew.** "Strictly older" holds within the 5-minute future clamp. A sender whose clock runs more than 5 min
  fast has both its old and its bumped edit clamped to the receiver's `now + 5 min`, so a later re-serve of the old one
  writes caps without the bit until its next profile. Names have always behaved this way.
- **One more half round trip** before link-up on a proven link. The device trial measures it.
- **An iPhone suspended mid-handshake costs a link.** If iOS suspends Knit after its HELLO and before it reads the
  reply and PROOF, the Android responder closes after its 5 s PROOF wait and counts `linkProofFailed`, where before it
  registered on its reply. The seeking trial measures it.
- **A store read that fails** answers "not proof-capable", so R1 fails open for that HELLO; the mesh runs only once
  the store is readable.
- **The proven set is bounded** at 4,096 ids. Evicting an id only reopens the no-profile window above for it; a live
  proven link keeps its id proof-capable on its own.

**What keeps it true:**

- `LinkProofTests`: the transcript's bytes, both roles, and the contract's reject shapes.
- `LinkTests`: the nonce field and tag 8.
- `LinkProofExchangeTests`: both roles, legacy both ways, every failure, one put-off per stage, `retire` and `refuse`
  mid-proof, and no PROOF to a HELLO without the bit.
- `LinkClaimTests`: R1 to R4, R1's place ahead of today's refusals, the event order and the set's cap.
- `LinkPipeProofTests`: two managers proving, a legacy one linking unproven, and a displacement re-running link-up.
- `LinkImpostorTests`: knit-peer's impostor puts on the wire what it says.
- `MeshEngineLinkProofCapabilityTests`: capabilities follow the presentation version, the start-time republish, and
  R4's edge.
- `MeshEngineBlobTests` and `MeshEngineBlobQueryTests`: blob control only from its link.
- `MeshControlTests`: the counters.
- `LinkVectorTests` replays knit-next's `keyed-v1.json` `link` entries, and `EmittedVectorTests` emits Carol's two
  proofs, which knit-next's `IosEmittedVectorTest` verifies.

**Amended 2026-11-07, for blinded adverts (ADR 2026-11.sv5t, knit-next ADR 2026-11.xp6d):** a dial to a blinded
advert expects no id and requires a proof. A reply naming us fails; one without `CAP_LINK_PROOF`, or with the bit and
no nonce, fails as `unproven` or `nonce`; otherwise its PROOF is verified against the reply's own id, and the link
registers under that proven id, R1 to R4 unchanged. The radio hears nothing of an unproven reply (`heardHello`). A
dialer's HELLO names the form it dialed (`a`, on every dial here, the id on a clear one), and a blinding responder's
HELLO names its current tag (`t`). The proof covers both HELLOs as the bytes that crossed, so neither field can be
rewritten (`keyed-v1.json`'s `blind.link.toldRewritten`). The bit values move with `CAP_BLIND_ADVERT`: the HELLO reads `c215f`
(`c315f` with the doorbell) and the signed profile `0xC015F`, or `0xC000F` without the ratchet's prekey.
