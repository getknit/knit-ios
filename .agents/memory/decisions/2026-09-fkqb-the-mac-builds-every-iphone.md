---
id: "2026-09.fkqb"
slug: the-mac-builds-every-iphone
title: "the Mac builds every iPhone app, and xtool is retired"
date: 2026-09-28
topics: [toolchain, build, ci]
---

# ADR 2026-09.fkqb — the Mac builds every iPhone app, and xtool is retired

Status: Accepted (2026-09-28)

**Context:** xtool on Linux was the stopgap for building the app before the Mac Mini arrived (ADR
2026-09.d3jv). ADR 2026-09.de8f kept its `build:ios` job on `knit-local` until installing on the iPhone moved
to Xcode. That happened on 2026-09-28: `check.sh device` built the signed `.dev` app in the Mac's desktop
session (ADR 2026-09.zawh), and `devicectl` installed and launched it on the iPhone 12. By then the phone had
no xtool build on it, and the debug bridge answered `interop.py` from the Linux machine as before. xtool cost
upkeep of its own. Its SDK bundle needed `scripts/xtool-sdk-fixup.sh` after every `xtool sdk install` (ADR
2026-09.5vbh). Its installs used an `XTL-` bundle id with a Keychain identity of their own, and counted
against the free team's three apps. The Darwin SDK also had to stay on one Linux machine, outside every image,
cache and artifact.

**Decision:** xtool is gone from the repo: `xtool.yml`, `scripts/xtool-sdk-fixup.sh`, `check.sh ios` and the
`build:ios` job. Every iPhone build now happens on the Mac, from `App/project.yml`: `build:ios:xcode` unsigned,
`build:ios:signed` signed, and `test:ios:simulator` in the Simulator. `check.sh xcode` takes over the check that
the app still holds KnitBLE's delegate methods, so earlier ADRs that name `check.sh ios` as a guard (ADR
2026-09.khjj, ADR 2026-09.wde9) now mean `check.sh xcode`. `verify:periphery` leaves `knit-local` for the
`macos` runner, which has Periphery 3.8.0 from Homebrew, and runs `check.sh periphery` with no `needs`. It stays
advisory, and the reason changes from ADR 2026-09.jgs6's: the Mac scan reports KnitBlueZ, whose callers compile
only on Linux, and five findings outside it were still open on 2026-09-28. `knit-local` keeps the heavy Linux
jobs: the sanitizers, fuzzing and analyze.

Keeping xtool as a fallback for when the Mac is down was the obvious alternative. It would mean a second iPhone
build that nothing checks, a bundle fix that every SDK reinstall undoes, and an SDK on Linux against Apple's
terms. A Mac outage does not stop work anyway: `check.sh fast` and the Linux jobs still run.

**Consequences / limits:**

- **No iPhone build without the Mac.** When the Mac's runner is down, the Apple jobs wait and the pipeline
  does not finish; nothing on Linux compiles `Knit` or `KnitBLE` for iOS any more. A fork needs a Mac of its
  own, as ADR 2026-09.de8f says.
- **The SDK on the Linux machine is now unused.** Removing `~/.swiftpm/swift-sdks/darwin.artifactbundle` and
  `/usr/local/bin/xtool` is the maintainer's call; nothing in the repo reads them. Any SDK left there stays
  out of images, caches and artifacts, as before.
- **Periphery on Linux** still runs by hand (`check.sh periphery`) and sees less than it did: the index no
  longer holds an iOS build.
- **The guards:** `.gitlab-ci.yml` has no job on `knit-local` that builds for iOS, and `build:ios:xcode` carries
  no `allow_failure`. Blocking on Periphery (`PERIPHERY_STRICT=1` on the Mac, with KnitBlueZ left to Linux) is
  still owed in `.agents/context/toolchain.md`.
