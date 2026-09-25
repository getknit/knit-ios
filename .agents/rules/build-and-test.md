# Building and testing

- **Before pushing,** `scripts/check.sh fast` passes. The `pre-push` hook runs it.
- **After touching `KnitWire`, `KnitCrypto` or `KnitMesh`,** `scripts/check.sh all` passes, sanitizers
  included. Wire code also gets `scripts/fuzz.sh`.
- **After touching `Knit`, `KnitBLE`, `App/` or `xtool.yml`,** `scripts/check.sh ios` passes. If it fails in
  clang's module scan, run `scripts/xtool-sdk-fixup.sh` first (`.agents/context/toolchain.md`).
- **Never commit build products:** `.build*/`, `xtool/`, `Fuzz/Crashes/`.
- **A dependency change** (a package, the Swift toolchain, SwiftLint, a CI image) starts with the
  `upgrade-notes` skill. Commit the regenerated `Package.resolved` in the same change, add or update its
  `THIRD-PARTY-NOTICES.md` row, and note it in `.agents/context/toolchain.md`.
- **Coverage floors move up only.** Ratchet them (`scripts/coverage-gate.py --ratchet`) in the change that
  earns it, and never edit `scripts/coverage-floors.json` downward to make a gate pass.
- **A gate that cannot run is not a gate that passed.** If docker, the SDK or a tool is missing, say so;
  never report the step green.
