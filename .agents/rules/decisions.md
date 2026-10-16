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
| the `WiFiAware` or DeviceDiscoveryUI frameworks, the `com.apple.developer.wifi-aware` entitlement, AWDL, or a faster lane for files | [ADR 2026-10.2c6c](../memory/decisions/2026-10-2c6c-wi-fi-aware-on-the.md) |
| `KnitWire`, `KnitCrypto`, `KnitMesh`, golden vectors, or the knit-next pin | [ADR 2026-09.2ved](../memory/decisions/2026-09-2ved-knit-next-s-code-and.md) |
| the target layout in `Package.swift`, or a `#if canImport` / `#if os` guard | [ADR 2026-09.wde9](../memory/decisions/2026-09-wde9-the-protocol-core-is-platform.md) |
| the deployment target, the bundle id or `App/Info.plist` | [ADR 2026-09.txqp](../memory/decisions/2026-09-txqp-ios-18-is-the-floor.md) |
| the device family, `TARGETED_DEVICE_FAMILY`, or anything for the iPad | [ADR 2026-10.kedu](../memory/decisions/2026-10-kedu-knit-ships-for-iphone-only.md) |
| a release build, `#if DEBUG`, the demo's launch arguments, `App/PrivacyInfo.xcprivacy`, the export-compliance key, `check.sh release`, `archive` or `upload`, or `release:testflight` | [ADR 2026-10.8cy5](../memory/decisions/2026-10-8cy5-a-store-build-is-a.md) |
| a CI job's `allow_failure`, a disabled lint rule, a compiler setting, or coverage floors | [ADR 2026-09.jgs6](../memory/decisions/2026-09-jgs6-each-quality-gate-blocks-from.md) |
| a persona in `.agents/personas/` or `.claude/agents/`, `rules/owners.md`, `review-gate.sh` or `review-gate.conf` | [ADR 2026-10.zjmx](../memory/decisions/2026-10-zjmx-an-owner-writes-a-plane.md) |
| `COPYING`, `APP-STORE-EXCEPTION.md`, or how contributions are licensed | [ADR 2026-09.5phg](../memory/decisions/2026-09-5phg-knit-for-ios-is-gpl.md) |
| where the iPhone app builds, the `knit-local` runner, CI caches or artifacts | [ADR 2026-09.fkqb](../memory/decisions/2026-09-fkqb-the-mac-builds-every-iphone.md) |
| `App/project.yml`, `App/Knit.xcconfig`, `scripts/check.sh xcode`, or a job on the `macos` runner | [ADR 2026-09.de8f](../memory/decisions/2026-09-de8f-xcodegen-generates-the-app-project.md) |
| signing, `scripts/mac-desktop.sh`, `scripts/check.sh device`, `build:ios:signed`, or `App/Local.xcconfig` | [ADR 2026-09.zawh](../memory/decisions/2026-09-zawh-the-mac-signs-in-its.md) |
| a lock, `KnitSync`, `Mutex`, or a TSan report | [ADR 2026-09.ahrr](../memory/decisions/2026-09-ahrr-locks-are-pthread-mutexes.md) |
| DM sealing, `EncEnvelope` versions, or the capability bits `CAP_RATCHET` and `CAP_CRYPTO_V3` | [ADR 2026-09.qsd9](../memory/decisions/2026-09-qsd9-dms-seal-with-v1-static.md), [ADR 2026-10.5sk9](../memory/decisions/2026-10-5sk9-forward-secrecy-ports-knit-next.md) |
| the ratchet: `MeshConfiguration.ratchet`, `RatchetEngine`, `RatchetSessions`, `RatchetResetPolicy`, `RatchetInbound`, `RatchetReplay`, `RatchetStore` or the `ratchet_*` tables, a prekey, a v2 or v3 seal or open, the group form, a ctl code, a session reset or the re-seal after one, the control surface's `ratchet`, the unsigned v3 tick, `CAP_INLINE_ACK`, or a sealed receipt or tick | [ADR 2026-10.5sk9](../memory/decisions/2026-10-5sk9-forward-secrecy-ports-knit-next.md), [ADR 2026-09.2ved](../memory/decisions/2026-09-2ved-knit-next-s-code-and.md), [ADR 2026-09.p6nb](../memory/decisions/2026-09-p6nb-the-iphone-relays-and-carries.md) |
| the ratchet's store unit: `StoreTransactor`, `Transacted`, `MemoryTransactor`, `Checkpointing`, `KnitDatabase+Units`, or `MeshStores.transactor` | [ADR 2026-10.5sk9](../memory/decisions/2026-10-5sk9-forward-secrecy-ports-knit-next.md), [ADR 2026-09.nyya](../memory/decisions/2026-09-nyya-the-store-is-grdb-on.md) |
| group frames, `GroupRoster`, `GroupStore`, status notices, or `CAP_GROUPS` | [ADR 2026-09.n393](../memory/decisions/2026-09-n393-groups-seal-with-v1-per.md) |
| who dials whom, HELLO admission, link teardown, or a `Radio` adapter | [ADR 2026-09.6es2](../memory/decisions/2026-09-6es2-one-linkmanager-owns-dialing-and.md) |
| the router, custody rules or quotas, the digest exchange, or receipts | [ADR 2026-09.p6nb](../memory/decisions/2026-09-p6nb-the-iphone-relays-and-carries.md) |
| `KnitStoreSQL`, the schema or a migration, a SQL store, `secure_delete` or a checkpoint of the write-ahead log, or where the database file lives | [ADR 2026-09.nyya](../memory/decisions/2026-09-nyya-the-store-is-grdb-on.md) |
| a set, map or column keyed by a frame id, a frame key or an unparsed sender id | [ADR 2026-09.jc2x](../memory/decisions/2026-09-jc2x-wire-ids-compare-by-their.md) |
| a timer, a `Task`, the `Mesh` actor, or how the engine reads time | [ADR 2026-09.gq84](../memory/decisions/2026-09-gq84-the-mesh-engine-is-a.md) |
| `KnitBlueZ`, `knit-peer`, `scripts/interop.py`, `scripts/knit-hci.sh`, or anything that touches a Bluetooth adapter here | [ADR 2026-09.5ftc](../memory/decisions/2026-09-5ftc-a-headless-linux-peer-on.md) |
| `knit-peer` on a Mac, `PeerRadioHost`, `scripts/mac-peer.sh`, `mac-desktop.sh --stdio`, or `interop.py --mac` | [ADR 2026-09.vcdk](../memory/decisions/2026-09-vcdk-the-mac-peer-is-knit.md) |
| `KnitControl`, the control protocol, the app's debug bridge (`Sources/Knit/Debug/`), or `AppSession.eventTap` | [ADR 2026-09.kwa8](../memory/decisions/2026-09-kwa8-a-debug-build-takes-knit.md) |
| the bridge over Wi-Fi: `WiFiGate`, `RouterPin`, `WiFiCommand`, or `interop.py --host` | [ADR 2026-10.dz8d](../memory/decisions/2026-10-dz8d-a-debug-build-s-bridge.md) |
| the bridge's screen recordings: `RecordCommand`, `ScreenRecording`, `ReplayCapture`, `interop.py record-pull`, or the microphone key | [ADR 2026-10.x2cq](../memory/decisions/2026-10-x2cq-a-debug-build-s-bridge.md) |
| the GATT payload, its UUIDs, `FLAG_DIALS_GATT_PEERS`, `Radio.dialsGattPeers`, `Radio.heardHello`, `GattPayloads`, or `KnitBLE` | [ADR 2026-09.xzpt](../memory/decisions/2026-09-xzpt-an-iphone-is-found-through.md) |
| `LinkOutbox`, `Radio.writeDigest`, or how a radio queues what it writes | [ADR 2026-09.3ch7](../memory/decisions/2026-09-3ch7-a-link-holds-at-most.md) |
| the doorbell, `Radio.ring`, `Radio.servesDoorbell`, `CAP_DOORBELL`, `LinkManager+Doorbell`, or what wakes a suspended iPhone | [ADR 2026-09.khjj](../memory/decisions/2026-09-khjj-a-peer-wakes-a-suspended.md) |
| seeking peers in the background, `Radio.seekPeers`, `LinkManager+Seeking`, the wake budget, the scan's filter, or `interop.py iphone-seek` | [ADR 2026-10.mueg](../memory/decisions/2026-10-mueg-a-lonely-iphone-in-the.md) |
| the Keychain identity, `KeychainSecretStore`, or what onboarding publishes | [ADR 2026-09.tkww](../memory/decisions/2026-09-tkww-a-reinstall-keeps-the-keychain.md) |
| what photos the iPhone shows, sends or carries, a group photo, screening, or `CAP_FILES` | [ADR 2026-10.nh55](../memory/decisions/2026-10-nh55-profile-photos-and-photos-in.md) |
| FILE records, `FileIntake`, `LinkManager+Files`, `Radio.writeFileRecord`, or how a file streams on a link | [ADR 2026-10.h6zz](../memory/decisions/2026-10-h6zz-file-records-cross-a-link.md) |
| `blobreq`, `BlobExchange`, `MeshEngine+Blobs`, a `BlobStore`, our photo's push, or how a peer's photo is adopted | [ADR 2026-10.ym9y](../memory/decisions/2026-10-ym9y-the-iphone-asks-for.md) |
| `blobhave`, `blobhas`, `CAP_BLOB_HAVE`, `MeshEngine+BlobQueries`, who a blob is asked of and when, `queriesBlobHolders`, or `MeshTransport.fileTaken` | [ADR 2026-10.m9uq](../memory/decisions/2026-10-m9uq-the-iphone-answers-and-asks.md) |
| `blobprog`, `blobcancel`, `BlobProgressContent`, `BlobCancelContent`, `FileProgress`, `progressEveryMilliseconds`, `cancelQueuedFile`, `BlobHasItem.eta`, how long a held ask waits on a SENDING answer, or when an ask is withdrawn | [ADR 2026-10.ds45](../memory/decisions/2026-10-ds45-the-iphone-reports-a-file.md) |
| `FeedWindow`, `FilePace`, a file's pace or its budget, `Configuration.feedWindow`, `fileProgressReported`, how often a file streaming in is reported, or knit-peer's `--feed` | [ADR 2026-10.xwjc](../memory/decisions/2026-10-xwjc-the-iphone-s-file-feed.md) |
| a face, `Face`, `AvatarTint`, `AvatarView`, `Sources/Knit/Images/`, the profile photo's picker or cropper, or `-demoPhoto` | [ADR 2026-10.sepc](../memory/decisions/2026-10-sepc-a-face-is-a-person.md) |
| the demo's faces and photos, `App/DemoMedia/`, `DemoPictures`, `DemoPortrait`, `DemoSnapshot`, or what the `marketing` scene says | [ADR 2026-10.2acj](../memory/decisions/2026-10-2acj-the-demo-wears-real-faces.md) |
| a photo in a chat, `AttachmentCrypto`, `MessageAttachment`, `ChatAttachment`, the composer's photo, or the viewer's Save | [ADR 2026-10.6cas](../memory/decisions/2026-10-6cas-a-photo-in-a-chat.md) |
| a GIF or a moving photo, `AnimatedPhotoView`, `AnimationTiming`, `WebPStrip.animated`, `PhotoDecoder.animation`, `attachmentAnimated`, or what a line calls a GIF | [ADR 2026-10.ytvx](../memory/decisions/2026-10-ytvx-a-moving-photo-plays-in.md) |
| how a picked picture is made ready to send, `PickedPhoto`, `KnitWebP` or libwebp, `FrameSchedule`, `JPEGStrip`, `WebPStrip`, `StrippedPicture`, `ChatAnimation`, `Sticker`, `PhotoFailure` or `ChatPhoto.imageIOQuality` | [ADR 2026-10.m4ah](../memory/decisions/2026-10-m4ah-a-picked-picture-is-shrunk.md) |
| reusing a held picture or copying one from our own store, `heldPhoto`, `PhotoIdentity`, `MeshEngine+Identities`, `copyFromOwnStore`, `attachmentPlainHash` or `attachmentSourceHash` | [ADR 2026-10.f3mv](../memory/decisions/2026-10-f3mv-a-picture-keeps-the-identity.md) |
| blocking, `BlockStore`, `MeshEngine+Blocks`, `DropReason.blocked`, the Blocked people screen, or anything the delivery path reads that custody must not | [ADR 2026-10.5wgg](../memory/decisions/2026-10-5wgg-a-block-hides-a-person.md) |
| Support Knit, `SupportLinks`, `SupportView`, a tip link, StoreKit or the storefront, or the App Store id | [ADR 2026-10.zv5c](../memory/decisions/2026-10-zv5c-tip-links-show-on-the.md) |
| reporting, `AbuseReport`, `ReportEmail`, `AppSession.report`, `View+Report.swift`, the report address, or About's Email Knit | [ADR 2026-10.f6kf](../memory/decisions/2026-10-f6kf-a-report-blocks-the-person.md) |
| what is screened on sending, `ChatModel.send` or `choosePhoto`'s checks, a profile photo's screening, or `profilePhotoRefused` | [ADR 2026-10.spcy](../memory/decisions/2026-10-spcy-the-iphone-screens-on-sending.md) |
| the slur list, `App/Models/Slurs.txt`, `TextScreening`'s order of lists, or `TextScreening.bundled` | [ADR 2026-10.8e2u](../memory/decisions/2026-10-8e2u-every-conversation-runs-android-s.md) |
| the terms of use, `Terms`, `OnboardingStep.terms`, `acceptedTerms`, `TermsView`, or a launch that skips the terms | [ADR 2026-10.cgm3](../memory/decisions/2026-10-cgm3-everyone-agrees-to-terms-with.md) |
| the content filter, `PhotoScreening`, `ExplicitPhoto`, `Sources/Knit/Moderation/`, `App/Models/`, `tools/models/`, or `-demoSensitive` | [ADR 2026-10.rpmq](../memory/decisions/2026-10-rpmq-photos-from-others-are-screened.md) |
| words the content filter screens, `TextScreening`, `AbusiveText`, `WordFilter`, `SentencePieceTokenizer`, `MessageModeration`, `messages.moderation`, `tools/models/toxicity/`, or a hidden message | [ADR 2026-10.e4kz](../memory/decisions/2026-10-e4kz-messages-from-others-are-screened.md) |
| deleting a message or a chat, `deleted_messages`, `DeletedMessages`, `MeshEngine+Deletes`, `ThreadTable.listedGroups`, or anything that could bring a deleted message back | [ADR 2026-10.u7cq](../memory/decisions/2026-10-u7cq-a-delete-removes-messages-from.md) |
| reactions, the `reactions` table, `ReactionRecord`, `MeshEngine+Reactions`, `TextLimits.isAcceptedReaction`, a reaction chip or the picker | [ADR 2026-10.ehe6](../memory/decisions/2026-10-ehe6-reactions.md) |
| replies, `MessageReply`, `ReplyRef`, the `replyTo*` columns, `ChatQuote`, `QuoteView`, the composer's reply bar, `SwipeToReply`, `ThreadJump.to`, or a control line's `replyTo` | [ADR 2026-10.mn29](../memory/decisions/2026-10-mn29-replies-quote-in-every-thread.md) |
| mentions, `MessageMention`, `MessageMention.carried` or `SubstringIndex`, the `mentions` column, `MentionText`, `MentionCandidate`, `ChatModel+Mentions`, `ComposerTextView`, `MentionPicker`, `Swatches.mention`, `NotificationPolicy.mentionId`, a control line's `mentions`, `@everyone`, or `interop.py iphone-mention` | [ADR 2026-10.nbhj](../memory/decisions/2026-10-nbhj-mentions-highlight-the-sender-s.md), [ADR 2026-10.jwst](../memory/decisions/2026-10-jwst-everyone-is-one-mention-per.md) |
| unread counts, the `unread` column, `markRead`, `unreadCounts`, `MessageRecord.arrivesUnread`, `ChatRow.unreadCount`, `ChatListAssembler.badgeTotal`, `CountPill`, Knit's icon badge, `Notifier.setBadge`, `AppSession.syncBadge`, `AppSession+Reading`, or a demo line's `unread` | [ADR 2026-10.frmj](../memory/decisions/2026-10-frmj-unread-is-a-flag-the.md) |
| typing cues, `TypingContent`, `TypingBoard`, `MeshEngine+Typing`, `MeshEvent.typing`, `ChatModel+Typing`, `Typists`, `TypingRow`, the control line's `typing`, or `interop.py iphone-typing` | [ADR 2026-10.29z9](../memory/decisions/2026-10-29z9-typing-cues-go-one-hop.md) |
| `VerifyPayload`, a scanned code, `CodeScannerModel`, `CameraAccess`, `Sources/Knit/Codes/`, `-demoCamera`, or Add contact | [ADR 2026-10.65xx](../memory/decisions/2026-10-65xx-a-peer-s-profile-verifies.md) |
| a string a person reads, `Copy`, `App/Info.plist`'s usage strings, or a view's text | [ADR 2026-09.ycza](../memory/decisions/2026-09-ycza-user-facing-copy-lives-in.md) |
| `check.sh periphery`, a `verify:periphery` job, a `periphery:ignore`, or a Periphery finding | [ADR 2026-09.xgtz](../memory/decisions/2026-09-xgtz-periphery-blocks-on-the-mac.md) |
| a view's colors, `Palette`, `KnitUITests`, `AuditPolicy`, `scripts/check.sh uitest`, or an accessibility audit finding | [ADR 2026-09.jcdx](../memory/decisions/2026-09-jcdx-the-accessibility-audit-blocks.md) |
| a view's look or layout, `Swatches`, `KnitMarkPath`, `KnitMark`, `View+Buttons.swift`, `InfoSheet`, Liquid Glass, the app icon, or where Search will go | [ADR 2026-10.5waw](../memory/decisions/2026-10-5waw-knit-s-ios-look.md) |
| a thread's rows or scrolling, `MessageList`, `ThreadCollection`, `openRoute`, or a SwiftUI view drawn in a UIKit cell | [ADR 2026-10.pkbu](../memory/decisions/2026-10-pkbu-a-thread-is-a-uikit.md) |
| `KnitDeviceTests`, the `KnitDevice` scheme, `scripts/check.sh devicetest`, `SystemApps`, or an id that names a state | [ADR 2026-09.63em](../memory/decisions/2026-09-63em-device-ui-tests-run-by.md) |
| the store's screenshots, `KnitShots`, the `KnitShots` scheme, or `scripts/check.sh shots` | [ADR 2026-10.5u39](../memory/decisions/2026-10-5u39-store-screenshots-come-from-a.md) |
| the store's video, `-demoScene trailer`, `DemoDirector`, a scene's `script`, `AppSession.director`, `KnitTrailer`, or `scripts/check.sh trailer` | [ADR 2026-10.g3k9](../memory/decisions/2026-10-g3k9-the-store-s-video-is.md) |
| App Review's clips, `KnitClips`, `-demoScene block` or `filter`, a scene's `flaggedWords` or `flaggedPhotos`, `DemoTextClassifier` or `DemoPhotoClassifier`'s `flagging`, `DemoCast.Beat.blocks`, a demo post a block stops, `film_take`, or `scripts/check.sh clips` | [ADR 2026-10.yddp](../memory/decisions/2026-10-yddp-app-review-s-clips-are.md) |

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
