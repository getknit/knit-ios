# Interop with knit-next

Everything this repo puts on the air must match what Knit for Android does. These rules hold for
`KnitWire`, `KnitCrypto`, `KnitMesh`, both stores (custody is theirs to bound) and both radio adapters.

- **The pinned knit-next commit is the source of truth** (`.agents/context/knit-next.md`). When a knit-next
  doc and its Kotlin disagree, the Kotlin wins. Read the Kotlin before porting a rule, and cite the file and
  line in a comment.
- **Keep `signed` bytes verbatim.** Relays rewrite only `ttl` and `hops`. Never decode and re-encode signed
  bytes, and never round-trip them through `Codable`.
- **Sign each frame id once and store the bytes.** Verify signatures; never compare them.
- **Emit every required field, even when empty.** A missing `ProfileContent.status` fails Android's decode
  silently, and our key is never pinned (`.agents/context/wire-format.md` has the table). Every emitted
  type has an encoder test against its golden value.
- **Custody constants are cross-platform law.** TTLs, quotas, eviction order, `isCustodial` membership and
  the digest fold match `.agents/context/custody.md` exactly, or digests never agree.
- **Send a full DIGEST at link-up and every 60 s.** Android back-fills only in answer to one.
- **Never write a link record tag outside 1..7.** Android drops the link on an unknown tag.
- **Advertise only what is implemented.** The MVP sends capabilities `0x9` (E2E and STORE_FORWARD).
  `CAP_RATCHET` is a promise to handle v2 DMs, their ctl codes and resets; it stays off until the ratchet
  milestone ships.
- **Text limits count UTF-16 code units,** and whitespace means Java's `\s`. Node ids compare as ASCII
  strings, never as raw bytes.
- **Changes stay additive** (`docs/WIRE_COMPAT.md` in knit-next). If a change can only be made by breaking
  the wire, don't make it: add it to knit-next's `docs/NEXT_WIRE_BREAK.md` and find the additive route.
- **A behaviour that needs Android to change** is a Track A item in `.agents/memory/roadmap.md`, made in
  knit-next under knit-next's own rules, never worked around silently here.
