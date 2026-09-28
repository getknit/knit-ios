---
id: "2026-09.de8f"
slug: xcodegen-generates-the-app-project
title: "XcodeGen generates the app project, and the Mac builds the iOS app"
date: 2026-09-27
topics: [toolchain, build, ci]
---

# ADR 2026-09.de8f — XcodeGen generates the app project, and the Mac builds the iOS app

Status: Accepted (2026-09-27)

**Context:** until the Mac Mini arrived, xtool on Linux was the only way to build the app (ADR 2026-09.d3jv).
It wraps the `Knit` library product in an executable with an empty `stub.c`, and `@main` comes from the
library. On the Mac, `xcodebuild -scheme Knit` built the package's targets but not an app: nothing held a
bundle id, an icon, signing or launch arguments. The app target has almost nothing of its own: the
71-line spec generates a 377-line `project.pbxproj` and a 119-line scheme. `.gitignore` already kept
`*.xcodeproj/` out.

**Decision:** `App/project.yml` is an XcodeGen spec (2.46.0, from Homebrew), and `App/Knit.xcodeproj` is
generated from it and never committed. The project copies xtool's arrangement: a `KnitApp` target with one
`Host/stub.c`, linked to the root package's `Knit` product, named `Knit.app`. The target is not called `Knit`
because that is the package's module. The icon lives in `App/Assets.xcassets`, and `xtool.yml` points there
too. `App/Info.plist` stays the one source for the usage string and background modes. Debug builds take
`app.getknit.knit.dev` and Release builds `app.getknit.knit` (ADR 2026-09.txqp). The signing team goes in a
git-ignored `App/Local.xcconfig`. `scripts/check.sh xcode` generates the project and builds it unsigned
for the iPhone and the Simulator. `build:ios:xcode` runs that on the `macos` runner, and it blocks.
xtool's `build:ios` stays on `knit-local` until installing on the phone moves to Xcode.

Tuist was the other generator considered. Its Swift manifests come with a version manager and a build cache
of their own, more than one host target needs. Committing the project, with Xcode's synchronized folders,
would need no tool at all, but every settings change would then be a `.pbxproj` diff to review.

**Consequences / limits:**

- **Version keys:** a generated `Info.plist` takes its version keys from `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` rather than from `App/Info.plist`, which blanked them in the first build. The
  spec repeats both values, and `check.sh xcode` fails when the built plist disagrees with `App/Info.plist`.
- **Package pins:** the generated project resolves packages into a `Package.resolved` of its own. The gate
  seeds it from the root file, builds with `-disableAutomaticPackageResolution`, and fails if the pins drift.
- **The debug dylib:** Xcode's Debug build moves the app's code into `Knit.debug.dylib`, so the gate looks
  for KnitBLE's delegate methods there.
- **Forks:** an Xcode build needs a Mac, and a fork signs with its own team in `Local.xcconfig`.
- **Keychain:** a `.dev` install is a separate app from xtool's `XTL-` one, with its own Keychain identity.
- **The guards:** `check.sh xcode` and the `build:ios:xcode` job, which carries no `allow_failure`.
