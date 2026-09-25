# MVP: Knit for iOS talks to Knit for Android

The first milestone: an iPhone and an Android phone message each other over Bluetooth LE, as mesh peers.
Scope decisions and their reasons are ADRs (`.agents/memory/decisions.md`); what comes after the MVP is in
`.agents/memory/roadmap.md`.

## Done means

Every item below passes with both apps open and in range. The two phones are an iPhone (iOS 18 or later)
running a development build and an Android phone running a Knit build that includes companion change A1.
Items 2–6 and 11 also pass between the iPhone and the Linux peer.

1. **Setup.** Onboarding completes: welcome, then an optional name (the alias is the fallback), then the
   Bluetooth grant. The identity lives in the Keychain and survives relaunch and reboot.
2. **Link.** The phones link within 30 s of both being open, in both node id orders. A debug build's
   Diagnostics can mint an identity above or below a given id, and `knit-peer keygen --above/--below` does
   the same for the peer.
3. **Profiles.** Each side shows the other's name, or the same alias Android renders, and the safety
   numbers match.
4. **Nearby room.** A post appears on the other phone within 5 s over a live link, and shows ✓✓ once any
   peer has acknowledged it.
5. **DMs.** Tap a Nearby author, then Profile, then Message. The first DM arrives as a message request.
   After Accept, v1-encrypted replies flow both ways with Sent ✓ and Delivered ✓✓.
6. **Offline delivery.** A DM or room post written while the phones are apart arrives within 60 s of the
   next link.
7. **Relay.** In a forced line (Android, iPhone, Linux peer, with the peer's `deny-link` pointed at Android),
   posts and DMs cross the iPhone both ways, and the custody id sets converge.
8. **Discovery profile.** A peer that advertises only the `0xFE30` UUID and GATT payload (knit-peer in
   `--radio-profile ios`) finds and links the iPhone. This stands in for iPhone to iPhone.
9. **Background.** An open link survives 10 minutes with the iPhone locked, and a DM in that window posts a
   local notification. If P8's wake test shows that L2CAP data cannot wake a suspended app, this item
   becomes "the DM arrives at the next foreground, through custody", and the copy says so.
10. **Status.** The chat list shows how many peers are linked. Bluetooth off and Bluetooth not allowed each
    have their own message. The unsupported-device message is checked through `-seedDemo`. Settings has
    Stop and Start.
11. **Soak.** One hour of room traffic both ways, at or under 30 posts a minute per link including relays
    (Android refuses more). It passes with no link drop caused by us, no crash, and no unbounded growth in
    custody or the SeenSet. Unknown types, FILE records, `blobreq` and `keyreq` are handled without
    dropping the link.
12. **Gates.** Every blocking CI job is green, and the accessibility audit finds no errors on MVP screens.

## Not in the MVP

- **The v2/v3 ratchet**, which is the next milestone.
- **Contacts and profile media:** QR verification and contact links; avatars (we publish none and discard
  what we receive).
- **Message features:** attachments, reactions, replies, mentions and typing indicators.
- **Other surfaces:** groups, search, drafts and backups; link previews and location.
- **Moderation and block/report,** which an App Store build needs.
- **Background discovery.**
- **The other planes:** Wi-Fi Aware, the BLE side channel, spool relays, LoRa and Wi-Fi Direct.

## Phases

Each phase ends when its exit check passes. P7 starts the day the Mac arrives, whatever phase is in flight.

| Phase | Builds | Exit |
| --- | --- | --- |
| P0 Foundation | repo, dotagents, ADRs, package skeleton, gates, CI, spikes | pipeline green on the skeleton; `xtool dev build` yields `Knit.app` |
| P1 Wire | `KnitWire`: CBOR, wire types, link records, advert, ids, fuzz targets | all 57 goldens pass; each fuzzer runs 10 minutes clean |
| P2 Crypto | `KnitCrypto`: bundle, node id, signatures, v1 DMs, safety number, alias | RFC and golden vectors pass, including A2's keyed vectors |
| P3 Mesh | `KnitMesh`, `KnitStore`, `LinkManager` | ported suites pass under TSan and ASan; coverage floors hold (the lab is deferred) |
| P4 Linux peer | `KnitBlueZ`, `knit-peer` on hci1 | checklist L passes |
| P5 Store | `KnitStoreSQL` on GRDB | schema v1 frozen; migrations tested |
| P6 App | SwiftUI screens, `KnitBLE`, Keychain, notifications | `xtool dev build` green in CI; AppCore tests pass |
| P7 Mac | macOS runner, Simulator UI tests, a native Mac radio run | checklist M passes |
| P8 iPhone | the wake test, the scan-filter check, acceptance | the list above passes; tag `v0.1.0` |

## Checklists over the air

- **L (P4, Linux peer against Android):**
  - With `--radio-profile android` against Android 2.7: links, name and alias parity, the room both ways,
    v1 DMs both ways with ticks, DIGEST back-fill, FILE records tolerated, and a one-hour soak.
  - With `--radio-profile ios` against Android with A1: links in both id orders.
  - With `--radio-profile ios` against Android 2.7: the refusal reproduces, proving that A1 is the fix.
  - Two peers rehearse the relay line in item 7.
- **M (P7, a Mac against Android and the Linux peer):** checklist L's first two groups, with CoreBluetooth on
  the Mac as the radio.

## Track A, in knit-next

- **A1**, during P3 and P4, validated in P4: the responder accepts unsighted dialers, replaces their stale
  links, removes a link only if it is still registered, and scores it at −90 dBm.
- **A2**, during P1 and P2: golden vectors as JSON, keyed vectors, and a test of fixtures this repo emits.
- **A3**, after the MVP: Android finds and dials iPhones.

`.agents/context/knit-next.md` has the detail of each.
