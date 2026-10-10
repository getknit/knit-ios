---
id: "2026-10.6eyf"
slug: a-smaller-id-iphone-dials
title: "a smaller-id iPhone dials a flagged peer after a head start"
date: 2026-10-10
topics: [ble, transport, interop]
---

# ADR 2026-10.6eyf — a smaller-id iPhone dials a flagged peer after a head start

Status: Accepted (2026-10-10)

**Context:** since knit-next `713b29d6`, every Android build advertises `FLAG_DIALS_GATT_PEERS`, because its GATT
reader runs in every build (knit-next ADR 2026-09.kwq2). Under ADR 2026-09.6es2's order, a foreground iPhone whose
node id sorts below such a phone then waits for the phone to scan, read its GATT payload and dial it. An open
Android holding one link scans every 60 s or more, and a screen-off one every 240 to 840 s. So the iPhone missed MVP
item 2, which wants phones linked within 30 s of both being open, in both id orders. This is interop-audit finding
AND-2, the "iPhone's twin of knit-next #103" on the roadmap. Android's responder already admits a dialer it has not
sighted whatever the order (`BleAdmissionPolicy.kt:52`, knit-next ADR 2026-09.shzv). That fallback is what makes
the flag safe, so nothing on Android has to change.

**Decision:** the maintainer chose this route on 2026-10-10. The iPhone gives a flagged peer above it a head
start, then dials that peer itself (`LinkManager+HeadStart.swift`). It dials when all of these hold:

- **The peer.** Its advert carries the flag, and its id sorts above ours as an ASCII string.
- **Promotion.** It passes the ordinary promotion filters: at least −90 dBm, heard within 12 s, not backing off,
  not linked or being dialed, and within the 6-link budget.
- **The dwell.** It has dwelled 24 000 ms: the ordinary 12 s plus a 12 s head start
  (`Configuration.headStartMilliseconds`).
- **One at a time.** No other head-start dial is open. Like Android's `lonelyDialInFlight`, this is derived from
  the dials in flight, never kept, since at the front the order never dials a flagged peer above us.

Among eligible peers the strongest goes first. A refusal is an ordinary failed dial, with the ordinary backoff. The
head start is a promotion override, as seeking's `dialsWhateverTheOrder` is. `weDial` and admission keep the order,
so a peer that has sighted the iPhone refuses the dial (`:51`) and dials the iPhone itself. A head-start peer's dwell
counts 12 s less wherever promotion reads it, so `dwellDue` wakes the link manager when the head start ends, with no
sighting needed. `link head start over for <id> (dwell=<ms>ms rssi=<dBm>dBm)` comes right before the dial's own
`link dialing` line. This is knit-next ADR 2026-09.hj4a's lonely dial turned the other way.

**Why 12 s.** MVP item 2 wants a link within 30 s. The first build gave a 15 s head start, which left about 3 s for
the dial. On 2026-10-10 the iPhone's dial to a screen-off Pixel 3 took 4.7 s from `link dialing` to `link up`, and
the dwell starts at the first sighting, a moment after Knit starts. So the screen-off Pixel 3's three head-start links
came at 29.6, 31.5 and 32.0 s, two of them over the item. The revised contract made the head start 12 s, which leaves
about 6 s. A shorter head start takes the dial from more phones that are about to dial anyway: the open Pixel 3
dialed at 15.6 to 17.2 s, inside either head start.

**Why the doorbell gates it.** A head-start dial makes the iPhone the link's central, which CoreBluetooth opens at a
720 ms supervision timeout and lets the iPhone change no further. Only Android's doorbell lookup asks for BALANCED's
5 s (knit-next ADR 2026-09.dqvb, #102), and the lookup runs only on a link whose HELLO carries `CAP_DOORBELL`. So the
rule reads `Radio.servesDoorbell`, the flag the HELLO reads, and the front alone: no head-start dial goes out on a
radio that serves no doorbell. In the background, seeking already dials whatever the order (ADR 2026-10.mueg), and a
linked iPhone there gives no head start.

The alternative a reader reaches for first is to clear the flag on Android, so the iPhone dials at the ordinary 12 s.
That is a knit-next change, and it gives up the flag's point: with the flag set, an Android that scans in time is
the link's central, at 5 s natively, and the iPhone dials only when it does not.

knit-peer gains `--gatt-reads`, which has the `android` profile read GATT payloads and set the flag, as a release
Android does, with no doorbell (interop-audit finding IOS-9). With `--never-sight`, it stands in for a gapped Android
that never dials the iPhone (`interop.py iphone-peer --release-android`).

**Consequences / limits:**

- **The rule covers any flagged peer above us:** a release Android, knit-peer's `ios` profile, and another iPhone.
  Each of those that has sighted us refuses the dial and dials us itself.
- **Some links move to the iPhone-central path.** An iPhone below an A3 Android was always the peripheral before.
  Now an Android that has not dialed within 24 s gets the iPhone's dial, and that link reaches 5 s only through the
  doorbell lookup. `interop.py iphone --links N` counts those links with the iPhone below, and fails any link that
  does not end at `timeout=5000ms` and any head-start link whose lookup found no doorbell. Only a real Android asks
  for BALANCED, and only a real iPhone opens at 720 ms, so knit-peer cannot stand in for this check.
- **A sighted Android refuses first.** Before its own dial lands, an Android that sighted the iPhone within 90 s
  costs the iPhone one refused dial and a 10 s backoff.
- **24 s of dwell needs the phone heard without an 8 s gap.** A gap restarts the dwell, as it does the ordinary one.
- **On hardware, 2026-10-10** (`.agents/context/linux-peer.md`, "What the head start showed"): with a 12 s head start,
  a screen-off Pixel 3 linked by the iPhone's head-start dial in 10 of 10 link-ups, at 26.0 to 28.8 s. Each link
  ended at 5000 ms after its doorbell lookup. An open Pixel 3 dialed first in 9 of 10, at 16.2 to 17.6 s, and the
  iPhone dialed the tenth at 25.6 s. With 15 s, an open Pixel 9 that had read the iPhone refused one head-start dial,
  and its own dial landed at 33.8 s.
- **Guards:** `LinkHeadStartTests` covers the dwell, the timer, one dial at a time, the refusal's backoff, the
  `300f` HELLO, a radio without a doorbell, an unflagged peer, a larger-id iPhone, seeking, and admission.
  `LinkManagerTests`' `theSmallerIdWaitsOutTheHeadStartOfAPeerThatCanSeeIt` pins both halves of the wait.
  `PeerOptionsTests` pins the switch.
