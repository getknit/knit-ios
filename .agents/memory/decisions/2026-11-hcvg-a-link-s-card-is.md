---
id: "2026-11.hcvg"
slug: a-link-s-card-is
title: "A link's card is fetched by its sender, in debug builds until approved"
date: 2026-11-10
topics: [messages, ui, network, interop, blobs]
---

# ADR 2026-11.hcvg — A link's card is fetched by its sender, in debug builds until approved

Status: Accepted (2026-11-10)

**Context:** Knit for Android shows a link's page title, description and picture as a card in the bubble (knit-next
ADR 2026-09.n752, amended by 2026-09.7x8k and 2026-10.9rh6). The sender fetches the page once, while it has the
Internet, and sends the card as an ordinary attachment:

- a string-keyed CBOR container, `LinkPreviewBlob`, typed `application/vnd.knit.link-preview`;
- sealed like a photo in a DM or a group, and in the clear in the Nearby room;
- a reader never contacts the site, and draws the card only beside a link in the words that matches its address.

The iPhone fetched the blob and drew nothing (ADR 2026-10.6cas: "a link's card shows nothing the link in the text
doesn't already show"). It sent no card, and it left `CAP_LINK_PREVIEW` (`0x400`) out of its capabilities, so an
Android phone never attached one to a DM or a group toward it. ADR 2026-11.w5ew left previews out of scope, since Knit
for iPhone fetched nothing over the Internet.

**Decision:** the iPhone shows Android's cards and sends its own, as Android does, in a debug build only until the
maintainer approves them for the store (the maintainer's call, 2026-11-10). It is built in three phases.

- **No wire, crypto, custody or schema change.**
  - The container is Android's byte for byte. Both of knit-next's golden fixtures (`linkPreviewBlob`,
    `linkPreviewBlobTextOnly`) decode to the value and encode back to their pinned bytes, which shows Android reads
    the cards this build writes.
  - The mesh is blind to an attachment's type, so `OutgoingPhoto`, sealing, `blobreq` and the room's
    `RoomAttachments` already carry a card.
- **P1, the container** (`Sources/KnitWire/Media/LinkPreviewBlob.swift`):
  - `LinkPreviewBlob.decode` is `decodeOrNull`. It bounds the bytes at 256 KiB, refuses any version but 1, and
    cleans the card at the boundary:
    - controls and format characters go, the bidi overrides among them;
    - whitespace runs collapse by ART's regex `\s` (ADR 2026-10.7uyt);
    - the title is cut to 200 UTF-16 units and the description to 400;
    - a picture that is no JPEG or WebP, or is past 128 KiB, is dropped and the card kept.
  - The card is refused only when its address is no plain web address.
  - The address is judged by `java.net.URI`, ported as `JavaURI` from ART's parser, so both phones keep and refuse the
    same addresses. A hand-written check would take addresses Android refuses (`a|b` in a path) and the reverse, and
    `Foundation.URL` differs between Linux and Apple platforms. `JavaURITests` holds 52 addresses to what OpenJDK 21
    read.
- **P2, the receive half:**
  - A card is drawn in the bubble beside the link it describes.
  - The content filter screens its picture and its words as one verdict, so a flagged card hides whole.
  - A debug build advertises `0x400`.
- **P3, the send half:**
  - **The fetch:** sender-side and off by default. It uses Android's address, redirect, size and header rules over
    URLSession.
  - **The composer:** a staged card, and a send that waits up to 5 s for its card.
  - **The setting** says the site sees the sender's IP address.
- **The release gate** follows voice notes (ADR 2026-10.ue3y). `KnitAppCore` holds no build condition: the session
  takes a bundle that only a debug build hands it, and `check_release_app` fails a release binary that holds its log
  line. A release build draws no card, sends none, shows no setting, and still sends `0xC015F`.

The first alternative is the obvious one for an iPhone: `LPMetadataProvider` from LinkPresentation, fetched by each
reader. It has the reader contact the site, which n752 rejected: most phones on a mesh have no Internet when they draw
a message, and every reader would open a socket to whatever a stranger in Nearby typed. It also loads a page its own
way, out of reach of the address and redirect rules, and what it reads from a page is not what Android reads.

**Consequences / limits:**

- **The app's first Internet surface.** ADR 2026-09.zwdp's "Knit meshes over Bluetooth alone" still holds for the
  mesh: nothing it carries crosses IP. The fetch is the sender's own HTTPS request, made only with the setting on.
- **Bad UTF-8:** text in a card that is not UTF-8 refuses the card here, as every frame here is refused. Android
  repairs it (`decodePayload`). Only a hand-made card shows the difference.
- **IPv6 literals:** `JavaURI` refuses a host written as an IPv6 literal, which Java reads. No Android sender writes
  one into a card (`LinkPreviewPolicy` refuses it).
- **Unicode hosts:** a host outside ASCII is a registry name to Java, with no host, so neither phone draws a card for
  `https://bücher.de/`.
- **Not built, as on Android:** a reader-side fetch, a receive toggle, and a card beside a photo.
- **The store:** approving previews is a later decision. It covers the privacy manifest, App Review's notes, the
  changelog and the release marker.
- **The traps:**
  - Reading a peer's card through `LinkPreviewBlob(decoding:)`, which skips the boundary. Use `decode(_:)`.
  - Swift's `isWhitespace` or `URL(string:)` in place of the ported rules.
  - Advertising `0x400` from `Capabilities.local`, which would put it in a release build.
- **The guards:**
  - `GoldenVectorTests`' two card fixtures;
  - `LinkPreviewBlobTests`, every case of `LinkPreviewBlobTest.kt`;
  - `JavaURITests`;
  - the `FuzzLinkPreview` harness.
