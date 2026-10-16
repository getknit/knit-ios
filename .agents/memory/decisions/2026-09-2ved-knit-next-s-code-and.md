---
id: "2026-09.2ved"
slug: knit-next-s-code-and
title: "knit-next's code and golden vectors are the wire contract"
date: 2026-09-25
topics: [interop, wire, testing]
---

# ADR 2026-09.2ved — knit-next's code and golden vectors are the wire contract

Status: Accepted (2026-09-25)

**Context:** `docs/IOS_PORT_REVIEW.md` in knit-next predates the v1 launch, and five of its byte-level claims are
now wrong: the node id scheme, the advert size, the one-way HELLO, the chunk size and the signature prefix.
knit-next's `GoldenVectorTest` pins 57 CBOR fixtures, inline in Kotlin, and no keyed vectors exist. The CBOR
profile (declaration-order text keys, omitted defaults, required fields) follows from kotlinx's settings
rather than from a written spec.

**Decision:** the Kotlin at the pinned knit-next commit is the wire contract. Four context files summarize it
with file and line citations: `wire-format.md`, `ble-transport.md`, `crypto.md` and `custody.md` under
`.agents/context/`. The Swift codec is tested against the goldens, copied with their provenance until
companion change A2 moves them into a JSON file both repos read. Signed bytes are stored and forwarded
verbatim, signed once, and verified rather than compared. Sharing the core through Kotlin Multiplatform, as
the review floated, would remove the drift risk but put a Kotlin/Native runtime and a Gradle build inside
the app; vectors carry that load instead.

**Consequences / limits:** a wire change in knit-next needs a matching change here, and moving the pin means
re-reading the files listed in `.agents/context/knit-next.md`. The golden-vector tests (from P1), an encoder
test for every type we emit, and A2's test in knit-next of fixtures this repo emits keep the two sides
honest.

**Amended 2026-10-15:** the ratchet brings one exception to "signed once" (ADR 2026-10.5sk9).

- **What Android does:** after a peer's reset, it re-seals its unacked DMs of the last 24 h under their original
  id and `sentAt`. Each reset gives those ids one more set of signed bytes, with no per-id guard
  (`MeshManager.kt:3361-3407` at knit-next `ac491f4c`).
- **What this port does:** the same, once its ratchet is on.
- **Why custody still holds one set of bytes per id:** the re-seal flies live and never replaces the bytes custody
  holds. Custody keeps the first bytes it stored for an id, here (`CustodySync`) as on Android (`ForwardSync.kt:75`).
  The receiver lets one copy of the re-sealed id past its dedup (`Router.reopen`).

Every other frame id is still signed once.
