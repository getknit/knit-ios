---
id: "2026-09.zawh"
slug: the-mac-signs-in-its
title: "The Mac signs in its desktop session, reached through a launchd job"
date: 2026-09-28
topics: [toolchain, build, ci, signing]
---

# ADR 2026-09.zawh — The Mac signs in its desktop session, reached through a launchd job

Status: Accepted (2026-09-28)

**Context:** the first signed build (ADR 2026-09.de8f) came from Xcode at the Mac's desk. On the free Personal
Team `<team id>`, it made an Apple Development certificate and a 7-day profile for `app.getknit.knit.dev`. Over
ssh, `codesign` failed with `errSecInternalComponent`, both before and after "Always Allow" on the key, and so
did `sudo launchctl asuser`. An ssh login gets a security session of its own, and the login Keychain stays
locked in it. That looked like needing a second keychain with its password in a file. It would also have
needed a weekly visit to the desk, because renewing a free profile needs the Xcode account, which is kept in
the same locked Keychain.

A launchd job loaded into `gui/501` runs in the desktop session instead, and there `codesign` signed a test
binary (2026-09-28). `xcodebuild -allowProvisioningUpdates` in such a job, started from ssh, built and signed
Knit. With the cached profile moved aside, it fetched a new one from Apple.

**Decision:** `scripts/mac-desktop.sh` runs a command as a one-shot launchd job in the desktop session. It passes
the directory, the niceness and the build variables, streams the output and returns the exit status.
`scripts/check.sh device` builds the signed iPhone app through it, renews the profile as needed, verifies the
seal, and prints when the profile expires. ssh and CI take the same path: `build:ios:signed` runs the gate on
the `macos` runner, only in `knit/knit-ios`. The alternative, a separate signing keychain unlocked by a script,
keeps a keychain password on disk and still cannot renew profiles.

**Consequences / limits:**

- **Anyone who runs commands as `maintainer` on the Mac can sign as the team.** That covers an ssh login, and a
  `macos` job from any project on the server, since the runner is an instance runner. The job's rule keeps
  forks from signing through this pipeline, but a separate account for the runner is the real fix, as
  `toolchain.md` already says.
- **The Mac must be logged in at the desktop.** It logs in by itself after a restart; if it ever stops doing
  that, the gate fails, because `gui/501` does not exist.
- **Incremental builds break the seal.** An incremental build that fetched a new profile copied it into the app
  without signing again, so the gate removes `Knit.app` before each signed build.
- **Free provisioning** still limits the team to three installed apps, and each profile lasts 7 days. A paid
  team with an App Store Connect API key would drop the Keychain from the path altogether.
- **The guards:** `check.sh device`, which runs `codesign --verify --strict` and reads the profile, and the
  `build:ios:signed` job, which carries no `allow_failure`.
