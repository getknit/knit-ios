---
id: "2026-10.5sk9"
slug: forward-secrecy-ports-knit-next
title: "Forward secrecy ports knit-next's ratchet whole, dark behind one switch"
date: 2026-10-15
topics: [crypto, dm, groups, interop]
---

# ADR 2026-10.5sk9 — Forward secrecy ports knit-next's ratchet whole, dark behind one switch

Status: Accepted (2026-10-15)

**Context:** every DM and group message this port seals is v1, a fresh key wrapped to each recipient's static X25519
key, so whoever later takes that key opens every v1 message ever sent to it (ADR 2026-09.qsd9). The roadmap puts
forward secrecy before any public build. In knit-next it is five pieces that ship together:

- the DM epoch ratchet, v2, bootstrapped by X3DH off a signed prekey (knit-next ADR 016);
- the group form, a sender-key ratchet whose seeds ride the pairwise DM sessions (knit-next ADR 017);
- the sealed control plane, which carries receipts, reactions and profile updates as ctl DMs (knit-next ADRs 018,
  020 and 033);
- v3, with a compact plaintext, a derived nonce and an unsigned live-link tick (knit-next ADR 059);
- inline acks (knit-next ADR 054).

One bit covers DMs and the group form (`Protocol.kt:51-60`). Android seals the group form whenever every other member
of a group advertises it with a prekey (`MeshManager.kt:1344-1353`), and every build since 2.3.0 does so. Every one
of those builds also advertises the bit with a prekey of its own. Android starts a session just to seal a receipt
(`InboundPipeline.kt:2904-2948`). The Kotlin is about 4,200 lines, with 3,650 lines of tests, and nobody has written
keyed vectors for it (`.agents/context/crypto.md`). Kotlin lines here are at knit-next `ac491f4c`, past this port's pin.

**Decision:**

- **Port all five pieces.** That covers DM v2 and v3, the group form both ways, ctl codes 1 to 6 and 8, inline acks
  both ways, the answer an init is owed (IntroSync's answer half), and our own and our peers' prekeys.
- **Skip only what no fielded Android build needs from us:**
  - the spool's exports, since there is no spool here (ADR 2026-09.zwdp);
  - sending contact-card intros, which waits for Contacts;
  - `CTL_TRANSFER`, which Android sends only toward `0x800`, so it takes the unknown-ctl path;
  - unsigned tick sends, since a signed tick verifies on Android the normal way;
  - the LoRa and spool tick paths;
  - `gr` root gossip, which is decoded, kept raw and never sent. The cost is bounded: a 6 h grace on a group this port
    founded, and at most one correction per group and member every 15 minutes (`GroupRootPolicy.kt:49`,
    `MeshManager.kt:1623-1646`).
- **Phase order.** Keyed vectors come first, as companion change A9. Then:
  1. the codec and primitives;
  2. prekeys;
  3. a store unit that fails closed, and the DM engine;
  4. DMs in the mesh;
  5. the group form received, then the group form sent;
  6. A10, interop runs, and the flip.
- **The switch, `MeshConfiguration.ratchet`, off by default.** Every phase merges with it off.
  - **Off:** the iPhone puts the same bytes on air as before. It seals the ratchet toward nobody, even Android peers
    that advertise it, publishes no prekey, and drops a v2 or v3 frame as `.cannotOpen`. Pinning peers' prekeys runs
    anyway, since it sends nothing.
  - **On:** the signed profile adds `0x10`, `0x40` and `0x100` and carries our prekey. The HELLO and the advert stay
    `0xF`, because Android takes a peer's capabilities from its pinned profile alone (`CryptoScheme.kt:11-13`).
  - **Every toggle republishes the profile** under a new stamp, with a version bump, as Android's prekey rotation does
    (`MeshManager.kt:996-1003`).
  - **Who can turn it on:** knit-peer, with `--ratchet`, and a Debug build, with `-ratchet`. A release build cannot,
    until the flip.
- **The flip is one change.** `Capabilities.local` becomes `0x15F` and the switch defaults on. That waits on four
  things: every promise in `crypto.md`'s ratchet section holds; A9 and A10 pass on Linux and in `test:macos`; knit-peer
  passes interop runs against knit-next `main` and the 2.9.0 and 2.8.0 APKs; and a Debug iPhone trial passes.
- **The Kotlin decides,** as `.agents/rules/interop.md` says, where it and `docs/FORWARD_SECRECY_RATCHET.md` or
  `docs/GROUP_FORWARD_SECRECY.md` disagree. knit-next's own crypto reviewer treats those docs as normative. The
  research for this port found ten places where they lag the Kotlin; each goes to knit-next as a doc fix.
- **One new unsigned shape, admitted only with `0x100` on:** the v3 live-link tick.
  - It must be a `relay = false` chat in DM form, addressed to us by a pinned peer. It is checked ahead of the
    exists-gate, and it must open as a v3 `CTL_RECEIPT` before anything commits. It is never custodied and never
    counts toward a reset (`InboundPipeline.kt:592-598`, `:1739-1768`).
  - This moves the trust boundary the crypto reviewer's shape 5 guards, on purpose.
- **A reinstall:** the Keychain keeps the identity and the prekeys, and every session dies with the database (ADR
  2026-09.tkww).
  - The iPhone sends no resets of its own then, because it has no peer list to send them to, and resetting every peer
    as it pins would reset strangers too.
  - The peers' next frames fail as `NO_SESSION`, the reset heuristic re-roots each pair, and the peer re-seals its
    last 24 h of DMs (`MeshManager.kt:3361-3407`).
  - A launch that finds a stored identity over an empty database draws a fresh prekey and bumps the profile, as
    Android's restore does (`MeshManager.kt:1036-1047`), but without the resets that follow it there.
- **The alternatives, and why not:**
  - **DMs first, with groups left on v1:** the one bit makes Android seal the group form toward any iPhone that
    advertises it.
  - **A new bit for the group form:** builds already in the field would still seal it.
  - **One branch merged at the flip:** a single review of thousands of lines, and nothing proven along the way.
  - **Porting from the two docs:** they lag the Kotlin.

**Consequences / limits:**

- **Until the flip,** the iPhone stays on v1, and every claim that v1 has no forward secrecy stays true.
- **Evidence before the flip** is thin. The dark phases add paths no fielded phone runs, so knit-peer runs and the
  Debug trial are the only live evidence for them, and CryptoKit runs only in `test:macos` until the trial.
- **A reinstall after the flip strands every session** until the heuristic and the peer's re-seal recover it, and
  every TestFlight reinstall will exercise that path.
- **Fielded Android lags `main`.** knit-next `38e425b5` first shipped in 2.9.0, and `0f519d71` and `795b0883` are in
  no tag yet, so interop runs cover the release APKs as well as `main`.
- **The guards today:**
  - `LinkTests` and `MeshEngineProfileTests` pin `0xF`.
  - `MeshEngineDirectMessageTests.aRatchetDMIsCarriedAndRelayedButCannotBeOpened` pins the drop.
  - `PersonaTests` keeps the review gates in step with the paths.
- **The guards to come:** the DM phase adds a test that the switch off puts the same bytes on air, and the flip
  changes the pins above in the same change.
