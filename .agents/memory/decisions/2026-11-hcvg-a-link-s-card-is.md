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
- **P2, the receive half** (`Sources/KnitAppCore/LinkPreviews/`, `LinkCardView`):
  - **The rule.** `LinkPreviewPolicy` ports `normalize`, `sameUrl` and `firstEligible`. A card is drawn only beside a
    link in the words that is the same link once both are normalized (`linkCardFor`), so a sender can't attach a
    bank's card to another page's link.
  - **Opening.** `LinkCards` opens a card off the main actor once its blob is here, through `decode(_:)`, and keeps
    Android's bounds: 64 cards open, 256 refusals remembered. A sealed card that its key doesn't open is refused, not
    read again. `ChatMessage.card` carries the card without its picture's bytes. A thread rebuilds when a card opens
    (`openedCount`), and keeps the cards it drew while it is open, so the memo's bound never makes it read in a loop.
  - **Not an attachment.** `ChatAttachment` stays `nil` for a card, so no ring, wait or tap counts one, as on Android.
  - **Screening.** `PhotoScreening.hides(card:isMine:)` reads the picture with the photo classifier and the words with
    `TextScreening` in the thread's scope, one verdict per blob and key. Someone else's card draws nothing until it is
    screened, and a flagged one hides whole behind the message's tap. A picture the model can't score is let through
    and asked about again, as a photo is.
  - **The bubble.** The card sits where a photo would, 220 points wide, a 120-point picture over the title (2 lines),
    the description (3) and the host, which reads left to right. A tap opens the card's link.
  - **VoiceOver.** The card's label joins its row: "Link preview: title, host". The row's own Open action for the link
    opens the same page, so the card adds only Show link preview while it hides.
  - **The bit.** `MeshConfiguration.linkPreviews` adds `0x400` to the signed profile, with or without a prekey:
    `0xC055F` with the ratchet's prekey, `0xC040F` without. The start-time republish (ADR 2026-11.hpmt) edits the
    profile when the bit comes or goes. `Capabilities.local`, which the HELLO and the advert send, never holds it.
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
- **Unicode hosts:** a host outside ASCII is a registry name to Java, with no host, so neither phone draws a card whose
  own address is `https://bücher.de/`. Android's sender writes such a card's address in punycode, and Android draws it
  beside `bücher.de` in the words, since `normalize` runs `IDN.toASCII`. This phone refuses a host outside ASCII
  instead: Linux has no IDNA, so it draws no such card and will fetch none.
- **A card can move its row:** someone else's card draws nothing until it is screened, so the row grows by the card a
  moment after it first shows. Android's card waits for its decode the same way.
- **Hidden words keep their card:** the card has its own verdict, so a message whose words the filter hides still
  shows a clean card, as on Android.
- **Not built, as on Android:** a reader-side fetch, a receive toggle, and a card beside a photo.
- **The store:** approving previews is a later decision. It covers the privacy manifest, App Review's notes, the
  changelog and the release marker.
- **The traps:**
  - Reading a peer's card through `LinkPreviewBlob(decoding:)`, which skips the boundary. Use `decode(_:)`.
  - Swift's `isWhitespace` or `URL(string:)` in place of the ported rules.
  - Advertising `0x400` from `Capabilities.local`, which would put it in a release build.
  - Reading a card's blob on the main actor, or as a photo: `BlobImageCache` reads its picture through
    `AppSession.picture(of:)`.
- **The guards:**
  - `GoldenVectorTests`' two card fixtures;
  - `LinkPreviewBlobTests`, every case of `LinkPreviewBlobTest.kt`;
  - `JavaURITests`;
  - the `FuzzLinkPreview` harness;
  - `LinkPreviewPolicyTests`, every case of `LinkPreviewPolicyTest.kt`, its IDN case turned into this limit;
  - `ChatLinkCardTests` and `LinkCardScreeningTests`;
  - `MeshEngineLinkPreviewCapabilityTests`, with a second engine reading the bit from its peer row;
  - `MeshEnginePhotoTests.aDMLinkCardIsWantedKeptAndAnnouncedLikeAPhoto`, since the engine's want and intake rules
    read no type;
  - `check_release_app`'s marker, "link previews are on in this debug build".
- **Owed on the iPhone:** a Pixel's DM, group message and Nearby post with a link each show their card, a flagged one
  hides, a tap opens the page, VoiceOver reads the card in its row, and a release build sends `0xC015F`. The Linux
  tests can't show these.
