---
id: "2026-10.ym9y"
slug: the-iphone-asks-for
title: "The iPhone asks for, serves and carries blobs as Android's BlobExchange does"
date: 2026-10-03
topics: [mesh, blobs, interop]
---

# ADR 2026-10.ym9y — The iPhone asks for, serves and carries blobs as Android's BlobExchange does

Status: Accepted (2026-10-03)

**Context:** a photo names its bytes by hash, and the bytes move one hop at a time (`BlobExchange.kt`, knit-next ADRs
2026-09.4tx5 and 2026-09.ptv8):

- **Asking.** A node that wants a blob sends every neighbour an unsigned, point-to-point `blobreq`, and asks each one
  again at link-up and every 60 seconds.
- **Answering.** A neighbour that holds the blob serves it as FILE records. One that lacks it wants it in turn, so the
  next ask finds it one hop nearer.
- **Not doubling up.** Nothing is pushed to a node that did not just ask. Nothing is asked for while its bytes stream
  in, and a copy already on the link is not served again.
- **Bounds.** At most 256 blobs are wanted, each forgotten after 30 minutes unrefreshed. Serves are remembered for
  45 s, at most 512 of them. The wants are rebuilt from the database at each re-ask.

The MVP ignored every `blobreq` and kept no blobs. ADR 2026-10.nh55 asked for Android's parity.

**Decision:** `BlobExchange` is a pure, bounded port in `KnitMesh/Recovery`, shaped like `KeyExchange`, with Android's
constants. `MeshEngine+Blobs` drives it:

- **Rebuilding the wants.** At start, at link-up and at each 60 s re-offer, the wants are rebuilt from the stores:
  every advertised photo whose bytes are missing.
  - A linked peer's own photo is left to its link-up push, and asked for at the next re-offer if it never came.
    Android never asks for a neighbour's photo again.
  - A blob just asked of every neighbour is not asked again by the re-ask in the same pass. Android asks twice (its
    ADR 2026-09.ptv8, "What it costs").
- **Serving.** Any held blob is served as kind ATTACHMENT, to the neighbour whose link carried the request, never to
  the sender the unsigned frame names. A blob not held is wanted on the asker's behalf.
- **Taking a file in.** It is kept only if its bytes hash to its key. A pushed photo is adopted only when it is the
  photo its pusher's signed profile advertises (ADR 2026-10.nh55). Anything else is kept only if something wants it.
- **Profiles.** A profile's photo is adopted once its bytes are held, and the photo shown meanwhile stays.
  - A newer profile with no photo clears it.
  - A hash that is not one leaves the photo shown alone. Android behaves the same way, since those bytes can never
    arrive.
- **Our own photo** is pushed to each neighbour after the profile that names it. A push counts only once its END is
  out, so a link that dies mid-push pushes again at the next link-up. Android counts the push as handed over, and
  never tries again.
- **Removing blobs.** A blob goes when nothing names it any more: at a replacement, and in a sweep at each start
  (`deleteIfUnreferenced`, `deleteOrphans`). A blob fetched on an asker's behalf therefore lives until the next start.

Two choices differ from Android on purpose, both hardening:

- **A `blobreq` is never flooded,** even one marked `relay = true`. Android would flood it, and every node it reached
  would serve the neighbour that handed it on. No build sends one marked that way.
- **Every hash is checked.** A `blobreq`'s hash must be a `BlobHash` (64 lowercase hex characters), as every hash in a
  store must. Android checks only a FILE_HEADER's key.

The alternative was to serve only what this node shows. A photo would then stop at an iPhone in a line while its
caption crossed, which ADR 2026-09.p6nb ruled out for frames.

**Consequences / limits:**

- **Air time for others.** An iPhone spends air time on other people's photos, as Android phones do.
- **Serving and fetching are unauthenticated.** Anyone in range can make a node serve any blob it holds, or fetch one
  on its behalf, within the bounds above.
- **Carrier pulls wait for Phase 4.** Pulling the blobs of carried frames within Android's 128 MiB, and a custody
  column to weigh them, come later (ADR 2026-10.nh55's plan). Until then only a request moves a blob through the
  iPhone.
- **Guards:**
  - `BlobExchangeTests` for the bounds;
  - `MeshEngineBlobTests` for serving, asking on another's behalf, the no-flood rule, the request's shape and
    rejected files;
  - `MeshEngineAvatarTests` for our photo and peers' photos;
  - `BlobStoreTests` and `SQLBlobStoreTests` for the stores.
