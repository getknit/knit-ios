---
id: "2026-10.65xx"
slug: a-peer-s-profile-verifies
title: "a peer's profile verifies them by scanning their knit-id code, and never pins from it"
date: 2026-10-02
topics: [app, crypto, security]
---

# ADR 2026-10.65xx — a peer's profile verifies them by scanning their knit-id code, and never pins from it

Status: Accepted (2026-10-02)

**Context:** until now an iPhone verified someone only by reading forty digits aloud and tapping Mark as verified.
Knit for Android has also let two people scan each other's code since 2.2.2, and its scanner offers two paths:

- **The peer's profile** compares only (`ProfileDetailsViewModel.onScanned`, `:397-411`). A scan that carries the
  pinned key marks the person verified. Anything else is MISMATCH, and nothing is written.
- **Add contact** imports (`AddContactViewModel.onScanned`, `:221-267`). A scan of someone whose key has not pinned
  pins it from the code and marks them verified, which makes them a contact.

Each phone shows `knit-id:v1:<nodeId>:<bundle>` (`VerifyPayload.kt`), always 150 ASCII bytes, drawn by zxing at
error correction L. Android never puts the signed contact card (ADR 042 there) in a QR, though both of its scan
paths read one. Verification is local and one-sided on both platforms, and no wire type carries it. iOS already had
the rest: `PeerRecord.verified` in the frozen v1 schema, `setVerified` from the engine up to the profile, and an
engine that refuses a different key for a pinned id.

**Decision:** the profile path only, for `knit-id` codes only.

- **`VerifyPayload`** in KnitCrypto ports the Kotlin codec. It parses on UTF-8, never on characters (ADR
  2026-09.jc2x), so a combining mark after the prefix leaves the prefix whole, as Kotlin's `startsWith` does.
  `certifiedNodeId` is Android's `parseLegacy` check: the id must be the one the bundle's text derives to.
- **`PeerProfileModel.scanned`** returns one of four outcomes. A certified code for this person, whose bundle's bytes
  equal the pinned text, verifies them through the existing `setVerified`. Our own code and a text that is no code
  at all each get their own words. Android answers MISMATCH for both, and the split changes only what the user
  reads. Everything else is a mismatch, and a mismatch never clears an earlier verification, as on Android.
- **The profile shows our own code** under the safety number, with Scan their code below it, as Android's
  `EncryptionSection` does. CoreImage draws it at error correction L, black on fixed white paper in dark mode too.
- **VisionKit's `DataScannerViewController` scans.** It is `@MainActor` and runs its own capture session, so nothing
  non-`Sendable` is started off the main actor and no delegate is `nonisolated`. AVFoundation's
  `AVCaptureMetadataOutput` was the alternative, at about three times the code. AVFoundation only reads and asks for
  the camera permission: the scanner reports itself unavailable until access is granted, so `CodeScannerModel` asks
  first, and checks `isSupported` before that, so a device that cannot scan never prompts.
- **The seam:** AVFoundation, VisionKit and CoreImage are imported only under `Sources/Knit/Codes/`
  (`seam_codes` in `.swiftlint.yml`). The camera reaches KnitAppCore as `CameraAccess`, the same arrangement as
  `NotificationPermission`.
- **`-demoCamera denied|allowed`** gives `-seedDemo` a camera that answers one thing, so the Simulator, which has no
  scanner, can show the refused and failed states. No hook injects a scanned text: the outcomes are tested on Linux.

**Consequences / limits:**

- **No Add contact.** A code from someone whose key has not pinned is a mismatch. Pinning from a scan, contact cards
  and `knit://` links wait for the contact-links milestone (`.agents/memory/roadmap.md`).
- **A card QR reads as "not a Knit code"** here, where Android's profile would verify it. No phone draws one.
- **An A10 iPad cannot scan.** The scanner needs an A12, which every iOS 18 iPhone has, but iPadOS 18 still runs on
  the 7th-generation iPad. It shows its own code and says it cannot scan.
- **The guards:** `VerifyPayloadTests` (Alice's 150-byte code and Kotlin's parse cases), `ProfileTests` (each
  outcome against the store), `CodeScannerTests` (the permission order), `CopyTests`'
  `infoPlistAsksForTheCameraInTheCatalogsWords`, `seam_codes`, `KnitUITests`' scan walk, and `KnitDeviceTests`'
  `CameraTests` on the iPhone, which keeps a picture of the code it drew. Both pictures decoded to the full code
  on 2026-10-02.

**Amended 2026-10-19:** Add contact now pins from a scanned code or a signed contact link (ADR 2026-10.tpr5). The
profile still only compares, and it now reads a card as well as a `knit-id` code, as Android's profile does. The first
two limits above no longer hold.
