---
id: "2026-09.63em"
slug: device-ui-tests-run-by
title: "device UI tests run by hand from the Mac"
date: 2026-09-29
topics: [testing, app]
---

# ADR 2026-09.63em — device UI tests run by hand from the Mac

Status: Accepted (2026-09-29)

**Context:** MVP items 1 and 10 were checked by hand on 2026-09-28. Someone switched Bluetooth, took Knit's
permission away and gave it back, tapped Stop and Start, and read the status line off the screen, while scripts
watched the debug bridge and the iPhone's log. The bridge (ADR 2026-09.kwa8) checks the mesh and the store and left
the screens to "XCUITest on the Mac". The Simulator's UI tests (ADR 2026-09.jcdx) run on `-seedDemo`, a radio that
goes nowhere, so they never meet CoreBluetooth, the system's permission prompt or the Settings app. The maintainer
asked for the core of those checks on the phone, and not for the screens' words or controls, while the app is this
early.

**Decision:** a device-only XCUITest target, `KnitDeviceTests`, which only the `KnitDevice` scheme runs.
`scripts/check.sh devicetest` runs it on the Mac, signed in the desktop session like `check.sh device` (ADR
2026-09.zawh). No CI job runs it, because driving the phone needs a go-ahead every session (`.agents/rules/devices.md`).

- **Knit launches live,** never on `-seedDemo`: the real radio, the Keychain identity and the SQL stores.
- **The suite drives the system beside it:** Bluetooth off and on in the Settings app, the permission reset with
  `resetAuthorizationStatus(for: .bluetooth)` and answered in SpringBoard's prompt, and Knit's own page in Settings.
  Apple's words for these live in one place, `SystemApps`, and a failing step there attaches the app's element tree.
- **It reads states, not words.** The status line's identifier names its state, `chat_list_status_<state>`, from
  `ConnectionStatus.accessibilityState`. The line's Start and Settings buttons, and onboarding's two Allow buttons,
  have identifiers of their own. Android has no tags for these, and `AccessibilityID` says so.
- **Every test restores the phone,** before and as it ends: Bluetooth on, the permission allowed, the mesh running.
  A test that fails leaves the next one, and `interop.py`, a phone they can use.
- **What it covers:**
  - `RadioTests`: Stop and Start, from Settings and from the status line, and Bluetooth off and on.
  - `PermissionTests`: the refusal, its line, and its Settings button, then onboarding's Allow asking through the
    system's prompt.
  - `RelaunchTests`: the node, onboarding and the mesh surviving a relaunch.

The alternative a reader reaches for first is a bridge command that reports the screen's state. It would need no
second app, but it cannot switch Bluetooth or answer the system's prompt, and it trusts the view model rather than
what is drawn.

**Consequences / limits:**

- **The Mac's command line finds no account.** `xcodebuild` found none over ssh or in the desktop session
  on 2026-09-28, though Xcode's window holds one with the Personal Team. The runner,
  `app.getknit.knit.devicetests.xctrunner`, got its first profile from Xcode's window, through Product → Build For →
  Testing on the `KnitDevice` scheme. The gate uses that profile until it expires 7 days later, and then the window
  has to make the next one.
- **The runner is a second app** on the free team, which allows three, and a second App ID.
- **The phone must be ready.** Settings → Developer → Enable UI Automation is on, and the phone stays unlocked with
  Auto-Lock off for a run. With a passcode set, the first run timed out enabling automation mode until someone
  entered the passcode on the phone.
- **XCTest ends the apps it launched** as the run finishes, which left Knit closed and the mesh down after the
  first full runs. The gate opens Knit again with `devicectl`, pass or fail.
- **Apple's words move between iOS versions.** The ones in `SystemApps` held on iOS 27.0 on the iPhone 12.
- **Rerunning onboarding on a live phone** needs the mesh stopped first. With it running, the prompt came before
  onboarding's Allow, and XCTest answered it unseen. The likeliest cause is a background relaunch iOS made for the
  mesh's links as the permission reset ended Knit, a launch that remembered onboarding and started the radio. With
  the mesh stopped, the prompt came only from Allow. A first install has nothing for iOS to relaunch. The test fails
  if a prompt comes before Allow.
- **Onboarding publishes the profile** (ADR 2026-09.tkww), so the onboarding test types the profile's own name back,
  and each run moves the profile's version.
- **Not covered:** the unsupported device, which stays with the Simulator's `-demoRadio unsupported`, and locking,
  unlocking and rebooting (items 1 and 9), which stay with `interop.py`, since XCUITest cannot type the passcode on
  the lock screen.
- **The guards:** the suite itself; `gate_xcode`, which compiles it for testing, so `build:ios:xcode` fails when it no
  longer builds; `AccessibilityIDTests` and `ChatListTests`' state test, which pin the identifiers and the states.
