---
id: "2026-10.8cy5"
slug: a-store-build-is-a
title: "A store build is a Release archive that the Mac checks, signs and uploads"
date: 2026-10-03
topics: [build, signing, ci, store]
---

# ADR 2026-10.8cy5 — A store build is a Release archive that the Mac checks, signs and uploads

Status: Accepted (2026-10-03); the export answer superseded by ADR 2026-10.nwt2 (2026-10-11)

**Context:** nothing had built Knit in Release before 2026-10-03, and the first Release build compiled with the demo
still reachable. `Launch` read `-seedDemo` and the `-demo…` flags from the process's arguments in any build, and
`AppEnvironment.make` ran the demo's seeded stores, fixed identity and silent radio whenever they asked. Someone who
installs from the store cannot pass launch arguments, but a store build should have no way into the demo at
all. The debug bridge was already out, behind `#if DEBUG` (ADR 2026-09.kwa8). The app also had no
privacy manifest and no export-compliance answer, and signing knew only development builds (ADR 2026-09.zawh).

Checking a binary for a flag's name does not work: Swift stores a string of 15 bytes or fewer inside the
instructions that use it, so `-seedDemo` never shows in the binary even while its parser is linked.

**Decision:**

- **A release build reads no launch argument.** `Launch.arguments` is empty outside `DEBUG`, and `make`'s demo
  branch and `AppEnvironment.demo` compile only in a debug build. The UI tests, the device tests and the screenshot
  scenes all run debug builds, so none of them changes. The alternative, `#if DEBUG` around every demo type in
  `KnitAppCore`, would spread build conditions through a platform-free target for no added guarantee: nothing in a
  release build reaches those types.
- **The privacy manifest,** `App/PrivacyInfo.xcprivacy`, declares UserDefaults with reason `CA92.1`, for the
  onboarding flag in `DefaultsPreferences`, and no tracking and no collected data: messages go from phone to phone and
  never reach a server of ours, which is what Apple counts as collection. GRDB and swift-crypto's `Crypto` ship
  manifests of their own, in the `GRDB_GRDB` and `swift-crypto_Crypto` resource bundles that land in the app.
- **The export answer** is `ITSAppUsesNonExemptEncryption` = YES in `App/Info.plist`. Knit seals direct messages,
  groups and photos with its own scheme, beyond the TLS that iOS provides, so the exempt answer would be false. The
  key records only that the encryption is there. Whether the route is the mass-market classification with an annual
  self-classification report is for someone who knows export law, and App Store Connect may still ask about the
  algorithms and France until Apple issues an `ITSEncryptionExportComplianceCode`.
- **Three gates in `scripts/check.sh`,** each on the Mac:
  - `release` builds Release for the iPhone, unsigned, and holds it to `check_release_app`: no debug-only code, a
    privacy manifest in the app and in every resource bundle, the export answer, and the iPhone alone (ADR
    2026-10.kedu). CI's `build:ios:release` runs it on every pipeline, so a debug path that stops compiling out fails
    there rather than at upload.
  - `archive` archives the `Knit` scheme in the desktop session, holds the archived app to the same checks, then
    exports it for App Store Connect into `.build-xcode/export/Knit.ipa` and checks that the export is signed for the
    App Store: a sound seal, no `get-task-allow`, and a profile that names no devices. Nothing leaves the Mac.
  - `upload` does the same with the export's destination set to `upload`. CI's `release:testflight` runs it by hand,
    from `main` or a tag of `knit/knit-ios` only, after every other stage has passed.
- **Signing:** the archive signs for development, as any archive under automatic signing does, and the export signs
  again for distribution. With the App Store Connect API key, `-allowProvisioningUpdates` makes the team's Apple
  Distribution certificate and both profiles for `app.getknit.knit` without Xcode's account. The export options come
  from the gate, not a committed file, so the team stays in `App/Local.xcconfig` or `KNIT_DEVELOPMENT_TEAM`. They turn
  off `manageAppVersionAndBuildNumber`, so the build number App Store Connect sees is the one in `App/Info.plist`.

**Consequences / limits:**

- **The marker strings.** `check_release_app` looks for two strings that only debug code holds: the bridge's queue
  label and the demo's launch line in `AppEnvironment.demo`. Each is longer than 15 bytes, so it is stored whole.
  Renaming either without updating the gate makes the check pass without checking anything; the comment at each place
  says so. On 2026-10-03 both were in the Debug build's `Knit.debug.dylib` and neither was in the Release `Knit`.
- **The demo's data still ships, unreachable.** The marketing scene's text is in the Release binary as data nothing
  references: dead stripping does not remove it. Nothing in a release build calls the code that would seed it.
- **The first signed run** (2026-10-03) made the App Store profile for `app.getknit.knit` and exported an `.ipa`
  signed by Apple Distribution, which `check_store_ipa` accepted. Its export first failed with "Copy failed": Xcode's
  packaging starts the other end of `/usr/bin/rsync` as the first `rsync` on the `PATH`, Homebrew's on the Mac,
  which refuses `--extended-attributes`. The gate puts `/usr/bin` first for the export.
- **The build number is raised by hand** before each upload, in `App/project.yml` and `App/Info.plist` together
  (`check.sh xcode` fails when they differ). App Store Connect refuses a number it already has.
- **`release:testflight` carries `allow_failure: true`** because a manual job in `rules` otherwise holds its pipeline
  open until someone runs it. It is not an advisory gate in ADR 2026-09.jgs6's sense, and `build:ios:release`, which
  is a gate, carries none.
- **A TestFlight build is `app.getknit.knit`,** a separate app from the `.dev` build, with a Keychain identity of its
  own. Only one Knit fits on a phone (`.agents/context/toolchain.md`).
- **The guards:** `StoreDeclarationTests` in `RepoConventionTests` (the manifest against the required-reason calls in
  the shipped sources, both ways; no tracking or collection; the export answer), `check.sh release` with
  `build:ios:release`, and `check_store_ipa` in `check.sh archive`.

**Amended 2026-10-11:** the export answer is now `ITSAppUsesNonExemptEncryption` = NO (ADR 2026-10.nwt2). Knit's
encryption is CryptoKit's, which needs no export documentation, and the YES above failed the first upload.
