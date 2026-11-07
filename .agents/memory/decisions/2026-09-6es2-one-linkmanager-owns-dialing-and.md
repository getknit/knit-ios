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

**Amended 2026-09-29, for MVP item 2's first link:** two promotion rules are this port's, and Android does not have
them. A peer quiet for more than 8 s is never promoted. A sighting lingers 90 s and the dwell counts from the first
advert, so after a Pixel left, the iPhone dialed it two or three times, and each timeout doubled the backoff, up to
80 s. And `nextDeadline` wakes the link layer when a candidate's 12 s dwell ends, as long as the peer will still
have been heard within those 8 s. Promotion ran only when something happened, so a dwell that ended between adverts
waited for the next one, 3 to 10 s at a phone's rate. Nothing on the air changes. Making this a paired change first
would leave item 2 waiting on Android, which cannot find an iPhone until A3. `LinkDwellTests` pins both rules.

**Amended 2026-10-02, for gaps of 8 to 12 s:** the silence limit is 12 s, not 8 (`heardWithinMilliseconds`). On
2026-10-02 the Pixel 7 probe, with knit-next's fix for #112, linked within 30 s in 4 of 8 samples. In three of the
four slow ones a passive scan on the ATS2851 heard the phone with no gap over 7.3 s, while the iPhone went 8.3 to
14.8 s between sightings. A dwell that ended in such a gap got no wake, and the next advert, more than 8 s after the
last, restarted it. Replayed through the iPhone's own sightings, a 12 s limit links 6 of those 8 within 30 s, and 7 of
2026-10-01's 8. Rerun with it the same morning, the probe linked 7 of 8 within 30 s, with a median of 23.5 s against
29.0 s (`.agents/context/linux-peer.md`, "What the 12 s limit showed").

- **A phone that leaves gets one dial at most.** When a link drops, its peer backs off for 8 to 12 s. If that ends
  within 12 s of the phone's last advert, the iPhone dials it once. The 8 s limit never allowed that dial. It came in 6
  of the day's 32 pauses on the 12 s limit, 8.3 to 10.6 s in ("What the Meshtastic radio showed"). The dial times out
  after 12 s, and when the doubled backoff ends the phone has been quiet for 30 s or more, so the 2026-09-29 run's two
  or three dials per pause do not come back. None did that day.
- **The wake now always fires.** With the limit no shorter than the dwell, every running dwell ends heard recently
  enough. A peer heard once is dialed 12 s later, unless an advert more than 8 s after it restarted the dwell.
- **A fast failure can be retried once more.** A dial that fails within a few seconds leaves the peer heard within
  12 s when an 8 to 12 s backoff ends, and the iPhone dials it again.
- **The gap reset stays Android's 8 s.** Raising it to 12 s as well gives 7 of 8 and 8 of 8 in the same replays, but
  the iPhone would then count presence differently from the phone it talks to. That is the next step if this one is
  not enough.

`LinkDwellTests`' `aPeerHeardOnceIsDialedWhenItsDwellEnds` and `aPhoneThatLeftIsNotDialedAgainAfterItsDialTimesOut`
pin the change, and `noWakeForAPeerThatWillBeQuietTooLongWhenItsDwellEnds` now runs with an 8 s limit.

**Consequences / limits:** the admission rule differs from Android 2.7 in three ways (unsighted dialers,
stale-link replacement, −90 dBm), and A1 is what brings Android level. An Android build without A1 still refuses
the iPhone's dial whenever the iPhone's id sorts lower. The HELLO is unauthenticated, so a device that
claims a node id we are not sighting can replace that peer's link, once every 30 s at most. Frames stay signed,
so the most it can do is cut a link. The radio adapters must stay thin: a rule added to KnitBLE or KnitBlueZ is
a rule the other radio does not have. `LinkManagerTests`, `LinkAdmissionTests` and `LinkEdgeTests` pin each rule, including
`anUnsightedLinkedPeerDialingAgainReplacesItsStaleLink` for the teardown bug,
`aLinkYoungerThanThirtySecondsIsNeverReplaced` and `aLinkWhosePeerWasSightedThenLostIsShedFirst`.

**Amended 2026-10-03, when photos came in (ADR 2026-10.nh55):** FILE records are no longer discarded as they stream
by. `LinkManager` takes each link's files in through a `FileIntake`, under Android's receiving rules, and streams files
out one chunk at a time behind the radio's report of the last (ADR 2026-10.h6zz). The radios still decide nothing:
they queue a whole FILE record and report its last byte out. `LinkFileTests` replaces the discard test.

**Amended 2026-10-23, for knit-next's silent-link close (its ADR 2026-10.697m):** this port adds no silent-link rule.
Since `f8b5d544`, Android closes a link that stops sending: once the peer has sent it an empty `KEEPALIVE`, an
unanswered probe closes the link about 150 to 210 s after the last byte in. The rule exempts a link whose HELLO carries
`CAP_DOORBELL` (`LinkSilence.kt:39`), because iOS suspends Knit with its link up. Every CoreBluetooth HELLO carries the
bit, so Android never probes an iPhone and never answers one. Mirroring the rule here would need Android to answer
first, which is worth asking for only once an iPhone is seen keeping a link its peer dropped, as a Redmi did in
knit-next #203. So `LinkManager` still ends a link only on the radio's close, an unknown tag, a replacement or a shed. This port never writes a keepalive: one would mark a
link without the bit, which is only the Linux peer's `android` profile, as answering on Android, and then its
unanswered probes would close the link. `.agents/rules/interop.md` holds that rule, and
`LinkAdmissionTests.aKeepaliveIsNeverWrittenNorAnsweredDoorbellOrNot` pins it. One link end still backs off once
(`retire`), which knit-next `9a68b225` (#205) brought Android level with.

**Amended 2026-10-26, for knit-ios #19 (ADR 2026-10.f5zs):** the 2026-10-23 list of how a link ends gains one. A link
with bytes queued and none written for 120 s of Knit's running time ends with `link chN write stalled for <ms> ms`,
Android's `WRITE_STALL_MS` (`LinkSilence.kt:35-37`, `:389` at `e63f15f4`). It backs off nobody, as Android's
`closeSilent` does not. A `CAP_DOORBELL` peer that never advertised a digest cue is exempt, since a suspended iPhone
reads nothing by design. Knit's own suspension never counts: a late check, a ring and coming to the front each
re-stamp the baselines. The link manager also meters a peer's digests now, a burst of 2 and then one per 30 s, keyed
by node id. `LinkWriteStallTests`, `WriteStallWatchTests` and `LinkDigestBudgetTests` pin both.

**Amended 2026-11-01, for the link proof (ADR 2026-11.hpmt, knit-next ADR 2026-11.264w):** the HELLO is no longer
taken on trust between phones that both carry `CAP_LINK_PROOF`. Each proves the id its HELLO names before the link
registers, an unproven claim to an id known to prove itself is refused, and a proof displaces an unproven link
claiming its id. These admission rules stand for links where neither side proves, so the consequences above still hold
toward Android v2.10.1 and earlier, and for an id we hold no profile for until it proves itself. A proven link is
replaced only by a link that proves the same id, under the same sighting and 30 s rules.

**Amended 2026-11-07, for blinded adverts (ADR 2026-11.sv5t, knit-next ADR 2026-11.xp6d):** an advert can carry a
rotating tag in place of the id (`FLAG_BLINDED`), so who dials is read off the advertised forms, by Android's
`AdvertOrder.iDial`. The iPhone is clear, so the order never sends it to a blinded advert: a blinding phone dials
every advert that carries an id. This ADR's exception holds on forms, so a radio without service data still dials a
blinded peer that reads no GATT payload. That dial, like every dial to a blinded advert, is a tag dial: its HELLO
carries `a` = the tag, its reply must prove itself (ADR 2026-11.hpmt), and the link registers under the id it proved.
Dials in flight and backoff are booked on a dial key, a clear advert's id or a tag's handle and address, never on the
id a tag dial's reply named. The responder's order check reads a proof-offering dialer's `t`, so a blinding Android
whose id sorts below ours is admitted. A sighting attributed to an id we hold a link to is never dialed, and a tag
dial that proves an id we already hold a proven link to keeps the new link and retires the old one, as Android's
responder replaces.
