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
- **Custody constants are cross-platform law.** TTLs, quotas, eviction order, `isCustodial` membership and
  the digest fold match `.agents/context/custody.md` exactly, or digests never agree.
- **Send a full DIGEST at link-up and every 60 s.** Android back-fills only in answer to one.
- **Never write a link record tag outside 1..7.** Android drops the link on an unknown tag.
- **Advertise only what is implemented.** This build sends capabilities `0x15F`: E2E, GROUPS, REACTIONS,
  STORE_FORWARD, RATCHET, INLINE_ACK and CRYPTO_V3 (ADR 2026-10.b4yk). Builds before the ratchet sent `0xF` (ADR
  2026-10.ehe6), builds before reactions `0xB` (ADR 2026-09.n393), and the MVP `0x9`. `CAP_RATCHET` promises v2 DMs,
  the group form, their ctl codes and resets; `CAP_INLINE_ACK` and `CAP_CRYPTO_V3` promise what
  `.agents/context/crypto.md` lists under "The promise behind the bits". The three go together
  (`Capabilities.ratchetSuite`), and the signed profile carries them only beside our prekey: with the switch off,
  or no prekey kept, the profile says `0xF`. Android reads them from the profile alone.
- **`CAP_DOORBELL` (`0x1000`) lives in the HELLO alone.** The HELLO adds it, reading `315f`, when the radio
  serves the doorbell (`Radio.servesDoorbell`). Nothing else ever advertises it: not `Capabilities.local`, not the
  signed profile, not the advert, and never the Linux peer's `android` profile, which serves no GATT.
- **`CAP_BLOB_HAVE` (`0x2000`) lives in the HELLO alone too.** Every HELLO carries it, reading `215f`, because
  every build answers a `blobhave` (knit-next ADR 2026-10.6e5t). Android reads it from the link only, so it stays
  out of `Capabilities.local`, the signed profile and the emitted vectors. Answering is never gated; only asking is
  (`MeshConfiguration.queriesBlobHolders`). A file's progress report, `blobprog`, and an asker's withdrawal,
  `blobcancel`, ride the same bit: each goes only to a neighbour whose HELLO carries it, an iPhone included (knit-next
  ADR 2026-10.nsr7, ADR 2026-10.ds45, ADR 2026-10.xwjc). Android still sends an iPhone no `blobprog`.
- **Text limits count UTF-16 code units,** and whitespace is what ART says it is, not the desktop JDK: regex
  `\s` is Unicode White_Space, and `isWhitespace` is ART's own list, pinned from knit-next's `ArtTextSemanticsTest`
  (ADR 2026-10.7uyt). Node ids compare as ASCII strings, never as raw bytes.
- **Changes stay additive** (`docs/WIRE_COMPAT.md` in knit-next). If a change can only be made by breaking
  the wire, don't make it: add it to knit-next's `docs/NEXT_WIRE_BREAK.md` and find the additive route.
- **A behaviour that needs Android to change** is a Track A item in `.agents/memory/roadmap.md`, made in
  knit-next under knit-next's own rules, never worked around silently here.
