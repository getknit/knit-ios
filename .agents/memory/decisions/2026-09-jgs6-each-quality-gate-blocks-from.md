---
id: "2026-09.jgs6"
slug: each-quality-gate-blocks-from
title: "each quality gate blocks from the commit that gives it work"
date: 2026-09-25
topics: [tooling, ci, testing]
---

# ADR 2026-09.jgs6 — each quality gate blocks from the commit that gives it work

Status: Accepted (2026-09-25)

**Context:** in knit-next, detekt, ktlint and Kover run as allowed failures in CI. The CI comments say the
Stop hooks enforce them locally, but commit `0ff5ca2f` removed those hooks on 2026-08-17, and a full Android
lint now runs nowhere. The rules exist on paper. knit-ios starts with no backlog to baseline.

**Decision:** every gate blocks in CI from the commit that first gives it something to check, with no
baseline:

- swift-format and SwiftLint in `--strict`, with every opt-in rule on;
- warnings as errors, strict concurrency, and strict memory safety on the platform-free targets;
- coverage floors that only ratchet up;
- TSan, ASan and fuzz crashes.

The advisory exceptions each have a written reason:

- Periphery on Linux, which cannot see Apple-only code;
- a random chaos seed, beside the fixed seeds that block;
- Trivy, as in knit-next.

The Claude Stop hook runs only the no-build linters, because knit-next dropped its build and test hooks
once each turn cost minutes. Builds and tests run in `pre-push` and CI instead.

**Amended 2026-10-03:** `-warnings-as-errors` reached every Xcode build of the app, yet two warnings in
`PhotoPickerButton.swift` built anyway, in every configuration. iOS 27 declares `PhotosPicker`'s label closure
`@Sendable` on an initializer marked `@preconcurrency`, and the compiler does not promote a warning raised against
such an API. `check.sh build`, `xcode` and `release` now keep the build's output and fail on any compiler warning in
this repository's files (`no_warnings`), leaving warnings in checked-out dependencies to their owners. Fresh builds of
every configuration, Debug and Release for the iPhone and the Simulator, the device tests, and SwiftPM on Linux and
macOS, then had none.

**Amended 2026-10-04:** a second Stop hook, `.claude/hooks/periphery-stop.sh`, runs `check.sh periphery` on Linux.
Nothing ran Periphery before a push, so its findings surfaced only in CI, and two in test code had landed by this date.
The hook hashes the Swift files, `Package.resolved` and `check.sh`, and scans only when the hash differs from its last
clean pass. Its build is incremental and keeps `check.sh`'s `SWIFT_JOBS` and `nice` caps; on a built tree the whole run
took 4 s. Other builds and the tests stay out of Stop hooks, and the Mac's scan, which needs the iPhone build's index,
stays in CI.

**Consequences / limits:** a new toolchain's warnings stop the build. `KNIT_WARNINGS_AS_ERRORS=0` gets past them
locally, and CI never sets it. Disabling a lint rule means a line with its reason in `.swiftlint.yml`. The
guard is `.gitlab-ci.yml` itself: it carries no `allow_failure` beyond the named advisories, and every job
runs a `scripts/check.sh` gate that is also run locally.
