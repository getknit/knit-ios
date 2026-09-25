---
id: "2026-09.zwdp"
slug: knit-for-ios-meshes-over
title: "Knit for iOS meshes over Bluetooth LE only"
date: 2026-09-25
topics: [scope, transport, ble]
---

# ADR 2026-09.zwdp — Knit for iOS meshes over Bluetooth LE only

Status: Accepted (2026-09-25)

**Context:** knit-next runs Wi-Fi Aware and Bluetooth LE together behind `CompositeMeshTransport`, and adds a
BLE side channel on extended-advertising pages (dark in release builds), spool relays over the internet,
LoRa through a Meshtastic board, and Wi-Fi Direct file transfers. iOS 26's Wi-Fi Aware needs a pairing
ceremony for every pair of devices, exposes no follow-up messages, and cannot use knit-next's pre-shared
data-path key (`docs/IOS_PORT_REVIEW.md` §1.2). CoreBluetooth cannot send extended adverts at all.

**Decision:** the iPhone joins the mesh over Bluetooth LE only. It reads Android's `0xFE30` presence advert,
links over insecure L2CAP credit-based channels, and speaks the same record stream. To Android an iPhone
looks like a BLE-only Android phone, which `CompositeMeshTransport` already handles: it merges radios per
peer and needs no change. Porting Wi-Fi Aware was the obvious alternative; the pairing requirement alone
rules it out for a mesh that links strangers.

**Consequences / limits:** every frame to or from an iPhone crosses a persistent L2CAP link, at Bluetooth's
throughput, with no fast fan-out plane. The iPhone never advertises `CAP_FAST_COMPACT`, `CAP_FRAME_TRANSCODE`
or `CAP_DIRECT_TRANSFER`. The other planes are listed as never-on-iOS in `.agents/memory/roadmap.md`; the
capability rule in `.agents/rules/interop.md` is the check that keeps them out.
