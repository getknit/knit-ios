# Building and testing

- **Be a considerate neighbour.** This machine runs a lot besides Knit. `check.sh` and `fuzz.sh` cap the
  compilers at `SWIFT_JOBS` (8) and run at nice 10, and the CI runners are capped too (the shared Linux
  runner: two jobs of 8 GB and 8 cores; `knit-local`: one job). Give new scripts and CI jobs the same caps,
  never raise a runner's `concurrent`, run the one gate you need while iterating, and save `check.sh all` and
  long runs (ten minutes of fuzzing, knit-next's whole Gradle suite) for the end of a change.
- **Before pushing,** `scripts/check.sh fast` passes. The `pre-push` hook runs it.
- **After touching `KnitWire`, `KnitCrypto` or `KnitMesh`,** `scripts/check.sh all` passes, sanitizers
  included. Wire code also gets `scripts/fuzz.sh`.
- **After touching `Knit`, `KnitBLE` or `App/`,** `scripts/mac.sh run scripts/check.sh xcode` passes on the
  Mac, the only place the app builds (ADR 2026-09.fkqb). A change to a view also runs
  `scripts/mac.sh run scripts/check.sh uitest`, the accessibility audit (ADR 2026-09.jcdx).
- **Never commit build products:** `.build*/`, `Fuzz/Crashes/`.
- **A dependency change** (a package, the Swift toolchain, SwiftLint, a CI image) starts with the
  `upgrade-notes` skill. Commit the regenerated `Package.resolved` in the same change, add or update its
  `THIRD-PARTY-NOTICES.md` row, and note it in `.agents/context/toolchain.md`.
- **Coverage floors move up only.** Ratchet them (`scripts/coverage-gate.py --ratchet`) in the change that
  earns it, and never edit `scripts/coverage-floors.json` downward to make a gate pass.
- **A gate that cannot run is not a gate that passed.** If docker, the SDK or a tool is missing, say so;
  never report the step green.
