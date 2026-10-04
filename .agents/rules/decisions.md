# Decisions

When an ADR must be read, and how a new one is recorded. Routed from
[`AGENTS.md`](../../AGENTS.md): match the trigger table here before touching code,
and read the whole file before recording an architectural or product-scope choice.

## When to read one

Every row names a **trigger** and a **file**. Follow the rows that match the task and
skip the rest. The traps live in the routed files, not here: if a trigger row starts
growing an explanation, that explanation belongs in the ADR.

| If touching | READ |
| --- | --- |
| a radio plane, a capability bit we advertise, or anything Wi-Fi Aware, LoRa, spool or Wi-Fi Direct | [ADR 2026-09.zwdp](../memory/decisions/2026-09-zwdp-knit-for-ios-meshes-over.md) |
| `KnitWire`, `KnitCrypto`, `KnitMesh`, golden vectors, or the knit-next pin | [ADR 2026-09.2ved](../memory/decisions/2026-09-2ved-knit-next-s-code-and.md) |
| the target layout in `Package.swift`, or a `#if canImport` / `#if os` guard | [ADR 2026-09.wde9](../memory/decisions/2026-09-wde9-the-protocol-core-is-platform.md) |
| the deployment target, the bundle id or `App/Info.plist` | [ADR 2026-09.txqp](../memory/decisions/2026-09-txqp-ios-18-is-the-floor.md) |
| the device family, `TARGETED_DEVICE_FAMILY`, or anything for the iPad | [ADR 2026-10.kedu](../memory/decisions/2026-10-kedu-knit-ships-for-iphone-only.md) |
| a release build, `#if DEBUG`, the demo's launch arguments, `App/PrivacyInfo.xcprivacy`, the export-compliance key, `check.sh release`, `archive` or `upload`, or `release:testflight` | [ADR 2026-10.8cy5](../memory/decisions/2026-10-8cy5-a-store-build-is-a.md) |
| a CI job's `allow_failure`, a disabled lint rule, a compiler setting, or coverage floors | [ADR 2026-09.jgs6](../memory/decisions/2026-09-jgs6-each-quality-gate-blocks-from.md) |
| `COPYING`, `APP-STORE-EXCEPTION.md`, or how contributions are licensed | [ADR 2026-09.5phg](../memory/decisions/2026-09-5phg-knit-for-ios-is-gpl.md) |
| where the iPhone app builds, the `knit-local` runner, CI caches or artifacts | [ADR 2026-09.fkqb](../memory/decisions/2026-09-fkqb-the-mac-builds-every-iphone.md) |
| `App/project.yml`, `App/Knit.xcconfig`, `scripts/check.sh xcode`, or a job on the `macos` runner | [ADR 2026-09.de8f](../memory/decisions/2026-09-de8f-xcodegen-generates-the-app-project.md) |
| signing, `scripts/mac-desktop.sh`, `scripts/check.sh device`, `build:ios:signed`, or `App/Local.xcconfig` | [ADR 2026-09.zawh](../memory/decisions/2026-09-zawh-the-mac-signs-in-its.md) |
| a lock, `KnitSync`, `Mutex`, or a TSan report | [ADR 2026-09.ahrr](../memory/decisions/2026-09-ahrr-locks-are-pthread-mutexes.md) |
| DM sealing, `EncEnvelope` versions, or the capability bits `CAP_RATCHET` and `CAP_CRYPTO_V3` | [ADR 2026-09.qsd9](../memory/decisions/2026-09-qsd9-dms-seal-with-v1-static.md) |
| group frames, `GroupRoster`, `GroupStore`, status notices, or `CAP_GROUPS` | [ADR 2026-09.n393](../memory/decisions/2026-09-n393-groups-seal-with-v1-per.md) |
| who dials whom, HELLO admission, link teardown, or a `Radio` adapter | [ADR 2026-09.6es2](../memory/decisions/2026-09-6es2-one-linkmanager-owns-dialing-and.md) |
| the router, custody rules or quotas, the digest exchange, or receipts | [ADR 2026-09.p6nb](../memory/decisions/2026-09-p6nb-the-iphone-relays-and-carries.md) |
| `KnitStoreSQL`, the schema or a migration, a SQL store, or where the database file lives | [ADR 2026-09.nyya](../memory/decisions/2026-09-nyya-the-store-is-grdb-on.md) |
| a set, map or column keyed by a frame id, a frame key or an unparsed sender id | [ADR 2026-09.jc2x](../memory/decisions/2026-09-jc2x-wire-ids-compare-by-their.md) |
| a timer, a `Task`, the `Mesh` actor, or how the engine reads time | [ADR 2026-09.gq84](../memory/decisions/2026-09-gq84-the-mesh-engine-is-a.md) |
| `KnitBlueZ`, `knit-peer`, `scripts/interop.py`, `scripts/knit-hci.sh`, or anything that touches a Bluetooth adapter here | [ADR 2026-09.5ftc](../memory/decisions/2026-09-5ftc-a-headless-linux-peer-on.md) |
| `knit-peer` on a Mac, `PeerRadioHost`, `scripts/mac-peer.sh`, `mac-desktop.sh --stdio`, or `interop.py --mac` | [ADR 2026-09.vcdk](../memory/decisions/2026-09-vcdk-the-mac-peer-is-knit.md) |
| `KnitControl`, the control protocol, the app's debug bridge (`Sources/Knit/Debug/`), or `AppSession.eventTap` | [ADR 2026-09.kwa8](../memory/decisions/2026-09-kwa8-a-debug-build-takes-knit.md) |
| the bridge over Wi-Fi: `WiFiGate`, `RouterPin`, `WiFiCommand`, or `interop.py --host` | [ADR 2026-10.dz8d](../memory/decisions/2026-10-dz8d-a-debug-build-s-bridge.md) |
| the GATT payload, its UUIDs, `FLAG_DIALS_GATT_PEERS`, `Radio.dialsGattPeers`, `Radio.heardHello`, `GattPayloads`, or `KnitBLE` | [ADR 2026-09.xzpt](../memory/decisions/2026-09-xzpt-an-iphone-is-found-through.md) |
| `LinkOutbox`, `Radio.writeDigest`, or how a radio queues what it writes | [ADR 2026-09.3ch7](../memory/decisions/2026-09-3ch7-a-link-holds-at-most.md) |
| the doorbell, `Radio.ring`, `Radio.servesDoorbell`, `CAP_DOORBELL`, `LinkManager+Doorbell`, or what wakes a suspended iPhone | [ADR 2026-09.khjj](../memory/decisions/2026-09-khjj-a-peer-wakes-a-suspended.md) |
| seeking peers in the background, `Radio.seekPeers`, `LinkManager+Seeking`, the wake budget, the scan's filter, or `interop.py iphone-seek` | [ADR 2026-10.mueg](../memory/decisions/2026-10-mueg-a-lonely-iphone-in-the.md) |
| the Keychain identity, `KeychainSecretStore`, or what onboarding publishes | [ADR 2026-09.tkww](../memory/decisions/2026-09-tkww-a-reinstall-keeps-the-keychain.md) |
| what photos the iPhone shows, sends or carries, a group photo, screening, or `CAP_FILES` | [ADR 2026-10.nh55](../memory/decisions/2026-10-nh55-profile-photos-and-photos-in.md) |
| FILE records, `FileIntake`, `LinkManager+Files`, `Radio.writeFileRecord`, or how a file streams on a link | [ADR 2026-10.h6zz](../memory/decisions/2026-10-h6zz-file-records-cross-a-link.md) |
| `blobreq`, `BlobExchange`, `MeshEngine+Blobs`, a `BlobStore`, our photo's push, or how a peer's photo is adopted | [ADR 2026-10.ym9y](../memory/decisions/2026-10-ym9y-the-iphone-asks-for.md) |
| a face, `Face`, `AvatarTint`, `AvatarView`, `Sources/Knit/Images/`, the profile photo's picker or cropper, or `-demoPhoto` | [ADR 2026-10.sepc](../memory/decisions/2026-10-sepc-a-face-is-a-person.md) |
| a photo in a chat, `AttachmentCrypto`, `MessageAttachment`, `ChatAttachment`, the composer's photo, or the viewer's Save | [ADR 2026-10.6cas](../memory/decisions/2026-10-6cas-a-photo-in-a-chat.md) |
| blocking, `BlockStore`, `MeshEngine+Blocks`, `DropReason.blocked`, the Blocked people screen, or anything the delivery path reads that custody must not | [ADR 2026-10.5wgg](../memory/decisions/2026-10-5wgg-a-block-hides-a-person.md) |
| `VerifyPayload`, a scanned code, `CodeScannerModel`, `CameraAccess`, `Sources/Knit/Codes/`, `-demoCamera`, or Add contact | [ADR 2026-10.65xx](../memory/decisions/2026-10-65xx-a-peer-s-profile-verifies.md) |
| a string a person reads, `Copy`, `App/Info.plist`'s usage strings, or a view's text | [ADR 2026-09.ycza](../memory/decisions/2026-09-ycza-user-facing-copy-lives-in.md) |
| `check.sh periphery`, a `verify:periphery` job, a `periphery:ignore`, or a Periphery finding | [ADR 2026-09.xgtz](../memory/decisions/2026-09-xgtz-periphery-blocks-on-the-mac.md) |
| a view's colors, `Palette`, `KnitUITests`, `AuditPolicy`, `scripts/check.sh uitest`, or an accessibility audit finding | [ADR 2026-09.jcdx](../memory/decisions/2026-09-jcdx-the-accessibility-audit-blocks.md) |
| `KnitDeviceTests`, the `KnitDevice` scheme, `scripts/check.sh devicetest`, `SystemApps`, or an id that names a state | [ADR 2026-09.63em](../memory/decisions/2026-09-63em-device-ui-tests-run-by.md) |

## Where they live

One file per decision under [`../memory/decisions/`](../memory/decisions/). The index
at [`../memory/decisions.md`](../memory/decisions.md) is a **generated router** over
them.

## Adding one

```sh
python3 scripts/adr.py new "<title>" --topics a,b   # scaffolds the file, prints the citation
# write the body
python3 scripts/adr.py index                        # regenerates the router
python3 scripts/adr.py lint                         # markdownlint via lintorama
```

**Never hand-edit the router.** `python3 scripts/adr.py index --check` fails instead
of writing, and CI runs it.

`new` deliberately does *not* update the router: a decision appears there once it is
written, not while it is a stub.

Once the body is written, add a row under [When to read one](#when-to-read-one) if the
next task in that area would need the decision. A decision nobody is routed to is a
decision nobody reads.

## Ids are minted, not chosen

A new ADR is `YYYY-MM.suffix` with a random four-character suffix (`ADR 2026-08.k3f9`),
because a sequence number is itself the merge conflict: every branch reads the same
"next number" and takes it. Sequence ids that predate the convention stay valid.

**Cite whichever form an ADR carries, and never renumber one.** The generator refuses a
duplicate id, a missing frontmatter key, a filename that disagrees with its `id` and
`slug`, and a `# ADR …` heading that disagrees with its frontmatter. That last check is
load-bearing: every citation in the codebase resolves by grepping for that heading.

## What belongs in one

An ADR records a decision **and what it cost**. The scaffold's three labels are the
shape:

- **Context**: what was observed, and what it was mistaken for. Numbers where there
  are numbers.
- **Decision**: what changed, and what the alternative was.
- **Consequences / limits**: what this costs, what it does not cover, and the trap
  the next person will reach for. **Name the test or check that keeps it true.**

That last line earns its keep. A decision with no named guard is a decision the next
refactor undoes without noticing.

To reverse a decision, write a new ADR and change the old one's `Status:` line to
`Superseded by ADR <id> (<date>)`. Never delete an ADR: its id is cited in commit
messages that cannot be rewritten.

## Every count in an ADR is point-in-time

An ADR records what was measured **on the day it was written**. A count inside
`memory/decisions/` is evidence for that decision and **never a statement of what is
true now**. Do not quote one as the current figure, and do not carry one into a new
comment, doc or answer. Measure again instead.

## Consult before deciding

Read the router at [`../memory/decisions.md`](../memory/decisions.md) for prior choices
before making an architectural or product-scope call. The ADR is usually faster than
the argument, and a re-litigated decision should end in a new ADR that supersedes the
old one, not in a silent reversal.
