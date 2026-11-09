# Interop with knit-next

Everything this repo puts on the air must match what Knit for Android does. These rules hold for
`KnitWire`, `KnitCrypto`, `KnitMesh`, both stores (custody is theirs to bound) and both radio adapters.

- **The pinned knit-next commit is the source of truth** (`.agents/context/knit-next.md`). When a knit-next
  doc and its Kotlin disagree, the Kotlin wins. Read the Kotlin before porting a rule, and cite the file and
  line in a comment.
- **Keep `signed` bytes verbatim.** Relays rewrite only `ttl` and `hops`. Never decode and re-encode signed
  bytes, and never round-trip them through `Codable`.
- **Sign each frame id once and store the bytes.** Verify signatures; never compare them. The one exception is the
  ratchet's re-seal after a peer's reset, which keeps the original id and never replaces custodied bytes (ADR
  2026-09.2ved, amended).
- **Emit every required field, even when empty.** A missing `ProfileContent.status` fails Android's decode
  silently, and our key is never pinned (`.agents/context/wire-format.md` has the table). Every emitted
  type has an encoder test against its golden value.
- **Custody constants are cross-platform law.** TTLs, quotas, eviction order, the group gate, `isCustodial`
  membership and the digest fold match `.agents/context/custody.md` exactly, or digests never agree.
- **An envelope id has the shape its type is minted with,** or `Router.admit` refuses it unseen, as Android does
  (`FrameId.admits`, ADR 2026-10.h7xw). The table is cross-platform law like `isCustodial`: a new frame type mints a
  `FrameId`, and a new id shape is a wire break that every build before it drops.
- **Send a full DIGEST at link-up and every 60 s.** Android back-fills only in answer to one.
- **Never write a link record tag outside 1..11; 8 (`PROOF`) only to a HELLO carrying `CAP_LINK_PROOF`; 9
  (`TAG_NEXT`) only while this port blinds, to a proven link whose HELLO carries `CAP_BLIND_ADVERT`; 10 (`KEY_SHARE`)
  and 11 (`SEALED`) only on a link opened in the sealed form.** Every build drops the link on an unknown tag: Android
  v2.10.1 and earlier know only 1..7, v2.11.0 only 1..8 (the `link-hello-proof` contract, §3; the `link-seal` contract,
  §3; knit-ios #25, #51). Tag 9 is read, exactly 16 bytes (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t; ADR
  2026-11.prsp). A dialer opens sealed only toward an advert carrying `FLAG_LINK_SEAL`, so tags 10 and 11 reach no build
  that would throw on them (ADR 2026-11.6zhj).
- **Advertise only what is implemented.** This build sends capabilities `0x1C015F`: E2E, GROUPS, REACTIONS,
  STORE_FORWARD, RATCHET, INLINE_ACK, CRYPTO_V3, LINK_PROOF, BLIND_ADVERT and LINK_SEAL (ADR 2026-10.b4yk; knit-ios
  #25; ADR 2026-11.sv5t; knit-next #286). Builds before the seal sent `0xC015F`, builds before the reader `0x4015F`,
  builds before the link's proof `0x15F`, builds before the ratchet `0xF` (ADR 2026-10.ehe6), builds before reactions
  `0xB` (ADR 2026-09.n393), and the MVP `0x9`. `CAP_RATCHET` promises v2 DMs,
  the group form, their ctl codes and resets; `CAP_INLINE_ACK` and `CAP_CRYPTO_V3` promise what
  `.agents/context/crypto.md` lists under "The promise behind the bits". The three go together
  (`Capabilities.ratchetSuite`), and the signed profile carries them only beside our prekey: with the switch off,
  or no prekey kept, the profile says `0x1C000F`. Android reads them from the profile alone. `CAP_LINK_PROOF`
  (`0x40000`) rides the HELLO and every profile we sign, the switch on or off: a peer reads it from our signed profile
  to know a link claiming our id must prove it, and from the HELLO to run the proof. `CAP_BLIND_ADVERT` (`0x80000`)
  rides both too: it promises that tag 9 and ctl 11 read here, and Android sends `TAG_NEXT` and its presence keys to a
  peer whose HELLO or pinned profile carries it (ADR 2026-11.sv5t). `CAP_LINK_SEAL` (`0x100000`) rides both, and only
  beside `CAP_LINK_PROOF`: the HELLO's copy is the one that counts (a plain link whose two HELLOs carry it is refused),
  the advert carries it as the flags byte's `FLAG_LINK_SEAL` (`0x10`), and the profile's copy is informational (the
  `link-seal` contract, §1 and §7). Every start whose profile would
  carry other capabilities than its last publish recorded republishes it as an edit, so no older profile of ours can
  take a bit back where a peer holds it (the `link-hello-proof` contract, §7).
- **`CAP_LINK_PREVIEW` (`0x400`) lives in the signed profile alone, in a debug build alone.** It promises that this
  phone draws a link's preview card, and Android attaches one to a DM or a group only toward a pinned profile carrying
  it. A debug build signs it beside the rest (`MeshConfiguration.linkPreviews`), reading `0x1C055F` with the prekey and
  `0x1C040F` without; a release build signs `0x1C015F` until the maintainer approves link previews (ADR 2026-11.hcvg).
  Never add it to `Capabilities.local`, which the HELLO and the advert send in every build.
- **`CAP_DOORBELL` (`0x1000`) lives in the HELLO alone.** The HELLO adds it, reading `1c315f`, when the radio
  serves the doorbell (`Radio.servesDoorbell`). Nothing else ever advertises it: not `Capabilities.local`, not the
  signed profile, not the advert, and never the Linux peer's `android` profile, which serves no GATT.
- **Never write a `KEEPALIVE` (tag 5) unless the link answers Android's.** Android closes a silent link to any peer
  whose HELLO lacks `CAP_DOORBELL` (knit-next ADR 2026-10.697m). One keepalive from us marks the link as answering,
  and from then on Android closes it after about 150 to 210 s with no byte in. A sender has to answer each keepalive
  with one of its own, except one that crosses its own unanswered announce or probe. Today no radio here writes one
  (`LinkAdmissionTests`), so the Linux peer's `android` profile, the only link without the bit, is never probed.
- **`CAP_BLOB_HAVE` (`0x2000`) lives in the HELLO alone too.** Every HELLO carries it, reading `1c215f`, because
  every build answers a `blobhave` (knit-next ADR 2026-10.6e5t). Android reads it from the link only, so it stays
  out of `Capabilities.local`, the signed profile and the emitted vectors. Answering is never gated; only asking is
  (`MeshConfiguration.queriesBlobHolders`). A file's progress report, `blobprog`, and an asker's withdrawal,
  `blobcancel`, ride the same bit: each goes only to a neighbour whose HELLO carries it, an iPhone included (knit-next
  ADR 2026-10.nsr7, ADR 2026-10.ds45, ADR 2026-10.xwjc). Android has sent an iPhone `blobcancel` since nsr7,
  and `blobprog` since knit-next `e658eb6f`.
- **Text limits count UTF-16 code units,** and whitespace is what ART says it is, not the desktop JDK: regex
  `\s` is Unicode White_Space, and `isWhitespace` is ART's own list, pinned from knit-next's `ArtTextSemanticsTest`
  (ADR 2026-10.7uyt). Node ids compare as ASCII strings, never as raw bytes.
- **Changes stay additive** (`docs/WIRE_COMPAT.md` in knit-next). If a change can only be made by breaking
  the wire, don't make it: add it to knit-next's `docs/NEXT_WIRE_BREAK.md` and find the additive route.
- **A log line a harness reads is frozen.** Reword no line that a pattern in `scripts/interop.py` or `scripts/soak.py`
  matches; add a line instead. `iphone-rotate` reads `ble serving <the doorbell's|the payload's> service <serial>`, `ble removed
  <…> service <serial>`, `ble matched an added service by order, not identity`, `ble looks again at the services of` and
  `ble rung by` from the iPhone, and knit-peer's `bluez ringing`, `bluez could not ring`, `link up <id> on chN`, `link down
  <id> on chN` and `link head start over for <id> `. Both channel-ending tables
  read `link chN closed: the advert flipped to …` (ADR 2026-11.prsp).
- **Admit a relinking dialer out of order, and only then.** For 30 s after the radio closes a proven link, a dialer
  proving that id is admitted whatever the order, unless our own dial or proof to it is open (ADR 2026-09.6es2, amended
  2026-11-11). Android does not do this, so toward an Android above the iPhone a relink still waits for Android's
  dial. Never let the window open on a teardown of ours, and never drop the guard, or both ends can admit crossing
  dials and lose both links.
- **A behaviour that needs Android to change** is a Track A item in `.agents/memory/roadmap.md`, made in
  knit-next under knit-next's own rules, never worked around silently here.
