---
id: "2026-09.6es2"
slug: one-linkmanager-owns-dialing-and
title: "one LinkManager owns dialing and admission for every radio"
date: 2026-09-25
topics: [ble, transport, interop]
---

# ADR 2026-09.6es2 — one LinkManager owns dialing and admission for every radio

Status: Accepted (2026-09-25)

**Context:** on Android, who dials whom and who is admitted live inside `BluetoothMeshTransport.kt`, next to
the radio calls. Three of its rules fail an iPhone. The responder closes any dialer whose node id does not
sort above its own (`:754`), and Android cannot see an iPhone to dial it, so roughly half of all
iPhone–Android pairs could never link. Links are keyed by node id, so closing a replaced link runs the old
link's teardown and removes its replacement (`:787` and `:806`). A link from a peer it is not sighting
scores −127 dBm and is shed first, and an iPhone's link always looks unsighted to Android. This port needs
the same rules on two radios: CoreBluetooth on the iPhone and BlueZ on the Linux peer.

**Decision:** one synchronous `LinkManager` in `KnitMesh` makes every link decision, over a `Radio` protocol
that only advertises, scans, dials, accepts and moves bytes. The larger node id dials, unless the peer cannot
find us: a peer advertising service data without `FLAG_DIALS_GATT_PEERS` never reads a GATT payload, so a
radio that cannot advertise service data dials it whatever the order. A dialer's HELLO is admitted within
5 s unless we sighted it and our own rule says we dial it, which breaks cross-dials. A dialer we never
sighted is admitted whatever the order, and its second link replaces the first instead of being refused:
that is the peer's fresh link after its old one died. Links are keyed by channel, an unsighted link scores
−90 dBm (the promotion floor), and FILE records are discarded as they stream by. These are companion change
A1's rules, which the iPhone and the Linux peer run from the start. The first alternative, a link layer in
each radio adapter, would write these rules twice, and the CoreBluetooth copy could not run under the Linux
test suite.

**Amended 2026-09-25, when A1 merged (knit-next `05dc2be1`, its ADR 2026-09.shzv):** review added two rules,
and this port takes both. A held link is replaced only once it is 30 s old, so a device that claims an unsighted
peer's id can cut its link at most that often. And the −90 dBm score is for a link whose peer has not once been
sighted since it came up; a peer sighted during the link and then lost scores −127, as on Android 2.7, and is shed
first.

**Consequences / limits:** the admission rule differs from Android 2.7 in three ways (unsighted dialers,
stale-link replacement, −90 dBm), and A1 is what brings Android level. An Android build without A1 still refuses
the iPhone's dial whenever the iPhone's id sorts lower. The HELLO is unauthenticated, so a device that
claims a node id we are not sighting can replace that peer's link, once every 30 s at most. Frames stay signed,
so the most it can do is cut a link. The radio adapters must stay thin: a rule added to KnitBLE or KnitBlueZ is
a rule the other radio does not have. `LinkManagerTests`, `LinkAdmissionTests` and `LinkEdgeTests` pin each rule, including
`anUnsightedLinkedPeerDialingAgainReplacesItsStaleLink` for the teardown bug,
`aLinkYoungerThanThirtySecondsIsNeverReplaced` and `aLinkWhosePeerWasSightedThenLostIsShedFirst`.
