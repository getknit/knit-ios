---
id: "2026-10.b4yk"
slug: dms-and-groups-seal-with
title: "DMs and groups seal with the ratchet, and the iPhone advertises 0x15F"
date: 2026-10-19
topics: [crypto, dm, groups, interop]
---

# ADR 2026-10.b4yk — DMs and groups seal with the ratchet, and the iPhone advertises 0x15F

Status: Accepted (2026-10-19)

**Context:** ADR 2026-09.qsd9 kept the iPhone on v1, Knit's static-key scheme, and off `CAP_RATCHET` until the
ratchet landed, so Android went on sealing v1 toward it. ADR 2026-10.5sk9 then ported knit-next's whole ratchet
dark, behind `MeshConfiguration.ratchet`, from P0 to P7h. Each phase passed its gates. The ratchet vectors passed
both ways, A9 and A10, on Linux and under CryptoKit. knit-peer ran against the Pixels on knit-next 2.9.0, and a
Debug iPhone with `-ratchet on` passed `iphone-ratchet` (38 of 38 steps) and a reinstall with its database gone and
its Keychain kept (ADR 2026-10.5sk9's live-run amendments; ADR 2026-10.wcex). The maintainer asked for the flip on
2026-10-19.

**Decision:** the ratchet is on.

- **`Capabilities.local` is `0x15F`:** end-to-end, groups, reactions, store-and-forward, `CAP_RATCHET` (`0x10`),
  `CAP_INLINE_ACK` (`0x40`) and `CAP_CRYPTO_V3` (`0x100`). The three ratchet bits are named
  `Capabilities.ratchetSuite` (`0x150`) and go on and off together, never one at a time.
- **What goes on air:** the HELLO reads `215f`, or `315f` with the doorbell, and the advert's low byte reads `5f`.
  The signed profile carries `0x15F` and our prekey.
- **The switch stays, and is on by default in what ships.** The app passes it in every build: on with no
  choice, and so always in Release, which reads no argument. A Debug build's `-ratchet off` still turns it off,
  and keeps that choice. knit-peer runs with it on, and `--no-ratchet` turns it off. `MeshConfiguration.init`'s own
  default stays off, as `queriesBlobHolders`' does. The products ask for the ratchet by name, and tests start
  from the pre-ratchet build unless they ask, so the tests that pin v1 and the switch-off bytes keep their meaning.
- **The profile is what the switch gates.** Off, or on with no prekey kept, our signed profile carries
  `local` without the suite, `0xF`, and no prekey: the bytes it had before the ratchet. Android reads the three bits
  from the pinned profile alone (`CryptoScheme.kt:11-18`), and this port reads a HELLO's bits only for
  `CAP_BLOB_HAVE`, so the HELLO and the advert keep `0x15F` whatever the switch says. Following the switch there
  would thread it through the link manager, `KnitBLE` and `BlueZHost` to change bits nobody seals by.

The alternative a reader reaches for first is to flip `MeshConfiguration.init`'s default too. That would turn the
ratchet on quietly in every engine fixture. Every test that pins v1, and the switch-off profile's hex literal,
would then need an edit to keep testing what it names.

**Consequences / limits:**

- **Upgrading from a build without the ratchet** mints prekey 1 at the first start and republishes the profile
  under a new stamp with a version bump. Android pins the newer profile and seals the next DM v2 or v3. Frames
  still in custody that were sealed v1 still open.
- **v1 stays for older phones.** A peer whose profile carries no ratchet gets v1 DMs, and its reactions and ticks in
  the clear. A group with such a member gets v1 for each message, and its reactions in the clear.
- **What the claims leave to `SECURITY.md`:** a session's first messages, and a reset's, are sealed to a signed prekey,
  and the last five prekeys stay in the identity's item for about five weeks. A reaction the facade cannot seal goes
  in the clear (`reactionsSealedFallback`). The claims say so (`SECURITY.md`,
  the README, the encryption sheets, `.agents/rules/copy.md`).
- **The export answer stands** (ADR 2026-10.nwt2). The ratchet's X25519, HKDF, AES-GCM and Ed25519 come from
  `Crypto`, which is CryptoKit on iOS, never `_CryptoExtras`.
- **What keeps it true:**
  - `LinkTests` pins `local` at `15f`, the suite at `0x150` and the switch-off set at `f`.
  - `LinkManagerTests` pins the advert's `5f`, and `LinkDoorbellTests` and `LinkRig` pin the HELLO's `215f` and
    `315f`.
  - `MeshEnginePrekeyTests` holds that the bits and the prekey ride together or not at all, and that switch-off is
    the old profile's bytes.
  - `LaunchRatchetTests` holds that no choice, and Release, give the switch on.
  - `PeerRatchetTests` covers knit-peer's flags.
- **Flipped before three of 5sk9's gates.** ADR 2026-10.5sk9 put the flip after interop runs against knit-next
  `main` and the 2.8.0 APK, and after a trial of a build that names no `-ratchet`. The maintainer asked for the flip
  before them, on the 2.9.0 runs and the Debug trial with `-ratchet on`. Fielded builds from 2.3 to 2.8 lack
  knit-next `38e425b5` (#135), where a pair's DMs could go dark for hours after a reset.
- **A restore from the phone's own backup can strand a pair** (ADR 2026-10.5sk9's P3 amendment, still open). The
  backup brings back the identity item and the onboarded flag without the database. The mesh then starts without
  onboarding, mints the next prekey under a new key and publishes it at version 0, which Android takes as stale, so
  Android keeps the prekey it pinned before. Each init Android starts toward us names a key we no longer hold, until
  our own resets re-root the pair or the user edits their profile. The fix, onboarding after every database that has
  never published or keeping the flag in the database, is a product change for the maintainer.
- **Owed after the flip:**
  - the restore fix above;
  - knit-next `6d9627b7`'s race rule (ADR 2026-10.5sk9's roadmap entry);
  - an interop run against knit-next `main` past 2.9.0 and against 2.8.0;
  - a device trial of an iPhone build that names no `-ratchet` at all;
  - reading `PRAGMA secure_delete` once on the iPhone (ADR 2026-09.nyya).

Supersedes ADR 2026-09.qsd9. Amends ADR 2026-09.n393 and ADR 2026-10.ehe6.
