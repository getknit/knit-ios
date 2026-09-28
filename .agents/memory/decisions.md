# Architecture decision records

The load-bearing decisions and *why* they hold. One file each, in
[`decisions/`](decisions/) — this page is the router. Open the file whose
row matches; do not guess from the title alone. Supersede a decision by
writing a new ADR and changing the old one's `Status:` line, never by
deleting it.

**This file is generated. Do not edit it by hand.** Add a decision with
`python3 scripts/adr.py new "<title>" --topics a,b`, write the body,
then `python3 scripts/adr.py index`.

**Ids are minted, not chosen.** A new ADR is `YYYY-MM.suffix`
(`ADR 2026-08.k3f9`) with a random suffix, so parallel branches never take
the same number. Cite an ADR by its id, exactly as its heading spells it.

| ADR | Decision | Topics |
| --- | --- | --- |
| [2026-09.2ved](decisions/2026-09-2ved-knit-next-s-code-and.md) | knit-next's code and golden vectors are the wire contract | interop, wire, testing |
| [2026-09.5ftc](decisions/2026-09-5ftc-a-headless-linux-peer-on.md) | a headless Linux peer on hci1 is the first interop rig | interop, ble, testing |
| [2026-09.5phg](decisions/2026-09-5phg-knit-for-ios-is-gpl.md) | Knit for iOS is GPL-3.0-or-later with an App Store exception | license, legal |
| [2026-09.5vbh](decisions/2026-09-5vbh-xtool-builds-with-the-compiling.md) | xtool builds with the compiling toolchain's clang headers | toolchain, build |
| [2026-09.6es2](decisions/2026-09-6es2-one-linkmanager-owns-dialing-and.md) | one LinkManager owns dialing and admission for every radio | ble, transport, interop |
| [2026-09.d3jv](decisions/2026-09-d3jv-the-darwin-sdk-stays-on.md) | the Darwin SDK stays on this machine | ci, toolchain, legal |
| [2026-09.gq84](decisions/2026-09-gq84-the-mesh-engine-is-a.md) | the mesh engine is a synchronous state machine behind one actor | architecture, concurrency, testing |
| [2026-09.jc2x](decisions/2026-09-jc2x-wire-ids-compare-by-their.md) | wire ids compare by their bytes, never by Swift string equality | wire, mesh, security |
| [2026-09.jgs6](decisions/2026-09-jgs6-each-quality-gate-blocks-from.md) | each quality gate blocks from the commit that gives it work | tooling, ci, testing |
| [2026-09.p6nb](decisions/2026-09-p6nb-the-iphone-relays-and-carries.md) | the iPhone relays and carries custody under Android's quotas | custody, mesh, interop |
| [2026-09.qsd9](decisions/2026-09-qsd9-dms-seal-with-v1-static.md) | DMs seal with v1 static keys until the ratchet lands | crypto, dm, interop |
| [2026-09.txqp](decisions/2026-09-txqp-ios-18-is-the-floor.md) | iOS 18 is the floor and the bundle id is app.getknit.knit | platform, build |
| [2026-09.wde9](decisions/2026-09-wde9-the-protocol-core-is-platform.md) | the protocol core is platform-free Swift that builds and tests on Linux | architecture, build, testing |
| [2026-09.xzpt](decisions/2026-09-xzpt-an-iphone-is-found-through.md) | an iPhone is found through a read-only GATT payload under 0xFE30 | ble, wire, interop |
| [2026-09.zwdp](decisions/2026-09-zwdp-knit-for-ios-meshes-over.md) | Knit for iOS meshes over Bluetooth LE only | scope, transport, ble |
| [2026-09.kwa8](decisions/2026-09-kwa8-a-debug-build-takes-knit.md) | a debug build takes knit-peer's commands over USB | interop, testing, app |
| [2026-09.nyya](decisions/2026-09-nyya-the-store-is-grdb-on.md) | the store is GRDB on SQLite under Data Protection, and SQLCipher waits | store, storage, interop |
| [2026-09.tkww](decisions/2026-09-tkww-a-reinstall-keeps-the-keychain.md) | a reinstall keeps the Keychain identity and republishes its profile | identity, storage, app |
| [2026-09.ycza](decisions/2026-09-ycza-user-facing-copy-lives-in.md) | user-facing copy lives in one catalog in KnitAppCore | copy, app |
| [2026-09.3ch7](decisions/2026-09-3ch7-a-link-holds-at-most.md) | a link holds at most one digest waiting, in an outbox both radios share | mesh, transport, interop |
| [2026-09.khjj](decisions/2026-09-khjj-a-peer-wakes-a-suspended.md) | a peer wakes a suspended iPhone by writing its GATT doorbell | ble, interop, transport |
