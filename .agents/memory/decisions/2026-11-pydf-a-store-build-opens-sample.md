---
id: "2026-11.pydf"
slug: a-store-build-opens-sample
title: "A store build opens sample chats anyone can try"
date: 2026-11-05
topics: [store, app, ui, moderation]
---

# ADR 2026-11.pydf — A store build opens sample chats anyone can try

Status: Accepted (2026-11-05)

**Context:** App Review held 1.0.0 (5) under guideline 2.1(a) on 2026-11-05: "We are unable to successfully access all
or part of the app", on an iPad Air in iPhone compatibility mode. Nothing was broken. `OnboardingModel.finish` needs no
Bluetooth and `Mesh.start` can't hang, so the reviewer reached the chat list and found it empty, because Knit fills up
only with people nearby. Apple asked for a demo account "that has access to all features", with "access to messages
from other users", or for "a demonstration mode", and added that a demo video is not sufficient.

Knit has no accounts to hand over. The notes had said so since 2026-10-09 and five videos were attached, so another
reply would have repeated what had just failed. Guideline 2.1(a) allows a built-in demo mode "with prior approval by
Apple", and this message gave it. ADR 2026-10.8cy5 had ruled that out: a store build has no way into the demo.

**Decision:** every build opens sample chats, and anyone can open them.

- **Visible, not a reviewer's secret.** Try sample chats sits on the first-run card and in Settings. Guideline 2.5.19 forbids "hidden, dormant, or undocumented features", and a reviewer can't miss a button.
  It also gives someone alone with a new app something to look at. The maintainer chose this on 2026-11-05 over a code
  printed only in the review notes, which keeps the product unchanged but depends on the reviewer reading them, and
  over a reply with no build, which Apple had all but answered already.
- **After the terms.** Both ways in are behind onboarding, and `openSample` refuses without the current terms agreed.
  Guideline 1.2 asks that everyone agrees before using the app, and App Review checks it (ADR 2026-10.cgm3). The first
  draft also put the button on the welcome page, where a reviewer could have tested everything and never met the terms.
  It stays off the permissions page too: App Review rejected that page once (guideline 5.1.1(iv)), and a second action
  beside Start invites another look. Bluetooth need not be allowed: `finish` opens the chat list either way.
- **A second environment, not a swap.** `Launch.stage` keeps the live environment, whose radio, links and notifications
  go on running. `Launch.sample` holds `AppEnvironment.sample(beside:)`, which `RootView` draws over it through a view
  with its own `.id`. Stopping the live one to open a sample would have put restoration and relinking in the path of a
  demo.
- **Nothing shared but the filter's models.** The sample has stores in memory, `DemoRadio` and an identity of its own,
  made new at each opening and gone on Leave. It touches no Keychain, database or App Group. It takes no device tag, posts no notification, sets no
  badge, opens no debug bridge and logs nowhere, since `UnifiedLog` can't tell two meshes apart and `interop.py` reads
  its lines. Nothing keeps it, so every launch comes up live.
- **Routing stays with the live app.** Only the live `MainView` takes a notification or a contact link
  (`takesRequests`). A tapped notification, an opened link or a share's link closes the sample first, because a contact
  added inside it would land in memory and be lost.
- **The scene:** `DemoScene.sample` is the marketing scene plus a stranger, whose posts give Report, Block and the
  filter something to act on. Its filters flag one post and one ordinary photo on purpose. Anything the user types or
  picks meets the real models (`SampleTextClassifier`, `SamplePhotoClassifier`), so someone testing the filter gets its
  real answer, and the scene's own words skip the model so the sample opens at once.
- **Answers:** the director's new loop gives what the user sends a delivered tick and a reply, in any thread. A blocked
  person stays silent.
- **It must not read as real.** Knit is for outages. The banner sits above the navigation stack, can't be dismissed, and
  says the people are made up and nothing reaches anyone. Every answer opens "Sample reply:", because "On my way" from someone made up could mislead a
  person who needs help, whatever the banner says over it.
- **Photos, no faces.** The six Unsplash photos moved to `App/SampleMedia/`, which every build bundles. The UI Faces
  portraits stay in `App/DemoMedia/`, debug only: their licence page says they aren't recommended for public, live
  projects (ADR 2026-10.2acj). So sample people wear initials in every build, a debug one too, and a trial shows what
  App Review sees.

**Consequences / limits:**

- **The demo's code ships.** ADR 2026-10.8cy5's demo branch stays debug-only and a release build still reads no launch
  argument, so `-seedDemo` and its flags can't be reached. `DemoSeed`, `DemoMesh`, `DemoDirector` and the `sample`
  scene are live code in a store build now, not unreferenced data.
- **A reviewer walks onboarding first.** That costs four taps and the Bluetooth alert before the sample, and it is the
  point: the terms and the permission page are what App Review checked in October, and the notes say to allow or decline.
- **Two meshes run in one process while a sample is open.** The design pass found no process-global state in
  `KnitMesh`, `KnitStore`, `KnitCrypto` or `KnitSync`. Never build a `BLERadio` for a sample: CoreBluetooth's restore
  identifiers are process-wide. The sample's session hears `setActive`, and its mesh hears nothing of the background,
  where seeking would write `link seeking` lines the harness takes for the live mesh's.
- **Answers may wait.** The director runs on `Task.sleep`, which wakes nothing, so a reply due in the background can
  land only on return.
- **Notifications stay real.** Settings in the sample shows the app's true permission, and its button raises the
  system's real prompt. The permission belongs to the app, not the session.
- **Never give the sample the demo's identity.** `DemoSeed.identity` is derived from constants, so anyone with this
  repository holds its private keys. Someone who added a sample's link or code would be sealing DMs to a key the whole
  world can open. `IdentityKeys.generate()` makes each opening's key instead: a link that leaves the sample names a key
  nobody holds, and what is sent to it reaches nobody and can be read by nobody. A link carries no device tag either.
- **A sheet covers the banner.** New message and the photo viewers are presentations over it, so it isn't on them while
  they're up. Every message is still written under the banner, and each sheet closes back to it.
- **iPadOS draws window controls over the banner.** In compatibility mode an iPhone app runs in a window whose controls
  sit at its top left, where a navigation bar steps aside and a custom view doesn't. They covered the banner's first
  words on an iPad Air 11-inch (M3) Simulator, App Review's device, so `SampleBanner` takes `containerCornerOffset`, which
  iOS 26 added and which works in compatibility mode. No test can see this: look at a screenshot from that Simulator
  after changing the banner.
- **The banner stops growing at `accessibility1`.** Uncapped, at the largest size it took half the screen, cut its own
  sentence off at "nothing you sen…" and left a thread too little room to scroll. It caps as the system's bars do, wraps
  whole, and the Large Content Viewer reads it larger. The audit asks for no clipping check, so nothing fails on a
  truncated banner: look at `sample_banner (largest)` in the largest-size walk's attachments.
- **The trap is `safeAreaInset`.** It is the first thing to reach for and it is wrong: it insets a `NavigationStack`'s
  content and leaves its bar underneath, so the banner hid every back button and Settings on 2026-11-05, while two walks
  still passed. `KnitUITests+Sample.swift` now asserts the bar stays hittable.
- **A report from a sample still emails.** Report and Email Knit opens the real address, and `iosreports@getknit.app`
  may see reports of made-up people. They name the demo's fixed node ids.
- **The entry points never sit over a thread.** `openSample` clears the live session's visible thread as well, because
  a thread left visible would keep its new messages read and quiet.
- **A debug bridge can open them.** `{"cmd":"sample","action":"open"}` does what a button does, so a script can check the live
  mesh under a sample on an iPhone nobody is at. `check_release_app` holds the bridge out of a store build.
- **The guards:** `SampleChatsTests`, through a real mesh and session; `DemoDirectorTests`' scene list;
  `CopyCatalogTests`; `KnitUITests+Sample.swift`, which walks a reviewer's path and audits it at every size and in dark
  mode, and whose `testTheSampleChatsComeAfterTheTerms` holds the order; `check_xcode_app`, which fails any build without `App/SampleMedia`'s photos; `check_release_app`, which still
  fails on the demo's launch line and on `DemoMedia`.
