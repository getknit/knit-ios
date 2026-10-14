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
| [2026-09.de8f](decisions/2026-09-de8f-xcodegen-generates-the-app-project.md) | XcodeGen generates the app project, and the Mac builds the iOS app | toolchain, build, ci |
| [2026-09.khjj](decisions/2026-09-khjj-a-peer-wakes-a-suspended.md) | a peer wakes a suspended iPhone by writing its GATT doorbell | ble, interop, transport |
| [2026-09.ahrr](decisions/2026-09-ahrr-locks-are-pthread-mutexes.md) | Locks are pthread mutexes, so TSan can see them | concurrency, testing, tooling |
| [2026-09.fkqb](decisions/2026-09-fkqb-the-mac-builds-every-iphone.md) | the Mac builds every iPhone app, and xtool is retired | toolchain, build, ci |
| [2026-09.jcdx](decisions/2026-09-jcdx-the-accessibility-audit-blocks.md) | The accessibility audit blocks, with named exemptions and a largest-size walk | accessibility, testing, ui, ci |
| [2026-09.vcdk](decisions/2026-09-vcdk-the-mac-peer-is-knit.md) | The Mac peer is knit-peer on CoreBluetooth, run in the desktop session | interop, testing, toolchain, ble |
| [2026-09.xgtz](decisions/2026-09-xgtz-periphery-blocks-on-the-mac.md) | Periphery blocks on the Mac and on Linux | tooling, ci, testing |
| [2026-09.zawh](decisions/2026-09-zawh-the-mac-signs-in-its.md) | The Mac signs in its desktop session, reached through a launchd job | toolchain, build, ci, signing |
| [2026-09.63em](decisions/2026-09-63em-device-ui-tests-run-by.md) | device UI tests run by hand from the Mac | testing, app |
| [2026-09.n393](decisions/2026-09-n393-groups-seal-with-v1-per.md) | Groups seal with v1 per-member wraps until the ratchet lands | crypto, groups, interop |
| [2026-10.dz8d](decisions/2026-10-dz8d-a-debug-build-s-bridge.md) | a debug build's bridge also listens on Wi-Fi, on a router pinned over USB | interop, testing, app |
| [2026-10.65xx](decisions/2026-10-65xx-a-peer-s-profile-verifies.md) | a peer's profile verifies them by scanning their knit-id code, and never pins from it | app, crypto, security |
| [2026-10.mueg](decisions/2026-10-mueg-a-lonely-iphone-in-the.md) | a lonely iPhone in the background seeks peers within a wake budget | ble, transport, interop |
| [2026-10.5wgg](decisions/2026-10-5wgg-a-block-hides-a-person.md) | A block hides a person and changes nothing the mesh sees | moderation, privacy, custody, ui |
| [2026-10.6cas](decisions/2026-10-6cas-a-photo-in-a-chat.md) | A photo in a chat is sealed in DMs and groups and public in Nearby | blobs, crypto, app |
| [2026-10.8cy5](decisions/2026-10-8cy5-a-store-build-is-a.md) | A store build is a Release archive that the Mac checks, signs and uploads | build, signing, ci, store |
| [2026-10.h6zz](decisions/2026-10-h6zz-file-records-cross-a-link.md) | FILE records cross a link one chunk at a time, each behind the radio's report of the last | ble, transport, interop |
| [2026-10.kedu](decisions/2026-10-kedu-knit-ships-for-iphone-only.md) | Knit ships for iPhone only | platform, store |
| [2026-10.nh55](decisions/2026-10-nh55-profile-photos-and-photos-in.md) | Profile photos and photos in chats come to the iPhone, carried as Android carries them | scope, blobs, interop |
| [2026-10.sepc](decisions/2026-10-sepc-a-face-is-a-person.md) | A face is a person's photo or their node id's tint, and a profile photo is cropped and saved on the phone | app, blobs, ui |
| [2026-10.ym9y](decisions/2026-10-ym9y-the-iphone-asks-for.md) | The iPhone asks for, serves and carries blobs as Android's BlobExchange does | mesh, blobs, interop |
| [2026-10.5waw](decisions/2026-10-5waw-knit-s-ios-look.md) | Knit's iOS look: the HIG and Liquid Glass, Signal's layout, Android's coral and stitch | ui, accessibility, brand |
| [2026-10.e4kz](decisions/2026-10-e4kz-messages-from-others-are-screened.md) | Messages from others are screened as they arrive, by Android's Detoxify model in Core ML | moderation, store, app, build |
| [2026-10.ehe6](decisions/2026-10-ehe6-reactions.md) | Reactions: six to pick, any one emoji shown, sent in the clear | messages, wire, interop, ui |
| [2026-10.rpmq](decisions/2026-10-rpmq-photos-from-others-are-screened.md) | Photos from others are screened on the iPhone when first shown, by Android's NSFW model in Core ML | moderation, blobs, app, build |
| [2026-10.u7cq](decisions/2026-10-u7cq-a-delete-removes-messages-from.md) | A delete removes messages from this iPhone and keeps them gone | messages, custody, store, ui |
| [2026-10.m9uq](decisions/2026-10-m9uq-the-iphone-answers-and-asks.md) | The iPhone answers and asks blob holder queries | mesh, blobs, interop, wire |
| [2026-10.pkbu](decisions/2026-10-pkbu-a-thread-is-a-uikit.md) | A thread is a UIKit collection view | ui, accessibility |
| [2026-10.5u39](decisions/2026-10-5u39-store-screenshots-come-from-a.md) | Store screenshots come from a UI-test walk in the Simulator | testing, store, ui |
| [2026-10.8e2u](decisions/2026-10-8e2u-every-conversation-runs-android-s.md) | Every conversation runs Android's slur list before the model | moderation, privacy |
| [2026-10.cgm3](decisions/2026-10-cgm3-everyone-agrees-to-terms-with.md) | Everyone agrees to terms with zero tolerance before using Knit | moderation, onboarding, ui |
| [2026-10.ds45](decisions/2026-10-ds45-the-iphone-reports-a-file.md) | The iPhone reports a file's progress to its sender, and holds on a SENDING answer's eta | mesh, blobs, interop, wire |
| [2026-10.f6kf](decisions/2026-10-f6kf-a-report-blocks-the-person.md) | A report blocks the person and deletes the message here, and can email Knit | moderation, privacy, ui |
| [2026-10.spcy](decisions/2026-10-spcy-the-iphone-screens-on-sending.md) | The iPhone screens on sending only in Nearby, and screens its profile photo | moderation, privacy |
| [2026-10.f3mv](decisions/2026-10-f3mv-a-picture-keeps-the-identity.md) | A picture keeps the identity it arrived under | blobs, crypto, privacy |
| [2026-10.g3k9](decisions/2026-10-g3k9-the-store-s-video-is.md) | The store's video is a scripted demo scene filmed in the Simulator | testing, store, ui |
| [2026-10.m4ah](decisions/2026-10-m4ah-a-picked-picture-is-shrunk.md) | A picked picture is shrunk as Android shrinks it | blobs, app |
| [2026-10.ytvx](decisions/2026-10-ytvx-a-moving-photo-plays-in.md) | A moving photo plays in a chat | blobs, app, ui |
| [2026-10.2acj](decisions/2026-10-2acj-the-demo-wears-real-faces.md) | The demo wears real faces and photos that only a debug build bundles | app, store, ui, testing |
| [2026-10.x2cq](decisions/2026-10-x2cq-a-debug-build-s-bridge.md) | a debug build's bridge records the screen with ReplayKit | interop, testing, app |
| [2026-10.xwjc](decisions/2026-10-xwjc-the-iphone-s-file-feed.md) | The iPhone's file feed is clocked by its receiver's reports | ble, mesh, blobs, interop |
| [2026-10.zv5c](decisions/2026-10-zv5c-tip-links-show-on-the.md) | Tip links show on the US storefront only | app, store, copy |
| [2026-10.6eyf](decisions/2026-10-6eyf-a-smaller-id-iphone-dials.md) | a smaller-id iPhone dials a flagged peer after a head start | ble, transport, interop |
| [2026-10.7uyt](decisions/2026-10-7uyt-whitespace-is-what-art-says.md) | Whitespace is what ART says it is | interop, wire, text |
| [2026-10.yddp](decisions/2026-10-yddp-app-review-s-clips-are.md) | App Review's clips are scripted scenes filmed like the store's video | testing, store, moderation |
| [2026-10.ab6k](decisions/2026-10-ab6k-the-lab-s-hardware-addresses.md) | The lab's hardware addresses and hosts live in a private env file, not the repository | peer, devices, build |
| [2026-10.nwt2](decisions/2026-10-nwt2-knit-takes-the-exempt-export.md) | Knit takes the exempt export answer because its encryption is CryptoKit | store, crypto, build |
| [2026-10.29z9](decisions/2026-10-29z9-typing-cues-go-one-hop.md) | Typing cues go one hop, unencrypted, and show at a thread's foot | messages, wire, interop, ui |
| [2026-10.2c6c](decisions/2026-10-2c6c-wi-fi-aware-on-the.md) | Wi-Fi Aware on the iPhone can only be a paired file lane, and waits on a spike | scope, transport, wifi-aware |
| [2026-10.mn29](decisions/2026-10-mn29-replies-quote-in-every-thread.md) | Replies quote in every thread, screened with the reply | messages, wire, interop, ui, moderation |
