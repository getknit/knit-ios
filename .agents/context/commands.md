# Commands

## Gates

`scripts/check.sh` runs every gate CI runs, one subcommand each. Each build variant keeps its own scratch
tree, so switching between them never rebuilds the plain debug tree.

| Command | Runs | When |
| --- | --- | --- |
| `scripts/check.sh fast` | format, lint, build, unit tests | before every push (the `pre-push` hook) |
| `scripts/check.sh all` | fast, plus the ADR router check, coverage floors, TSan, ASan, analyze and lintorama | before a merge request, and after touching `KnitWire`, `KnitCrypto` or `KnitMesh` |
| `scripts/check.sh format` / `lint` | `swift format lint --strict`, `swiftlint lint --strict` | while editing |
| `scripts/check.sh build` / `test` | the strict build; Swift Testing with xUnit output | while editing |
| `scripts/check.sh coverage` | tests in `.build-cov`, then `scripts/coverage-gate.py` | before a phase closes |
| `scripts/check.sh tsan` / `asan` | tests under a sanitizer, in `.build-tsan` / `.build-asan` | after touching actors, locks or unsafe code |
| `scripts/check.sh analyze` | `swiftlint analyze` over the platform-free targets | before a merge request |
| `scripts/check.sh periphery` | Periphery over the Swift Build index store (advisory on Linux) | after deleting or renaming API |
| `scripts/check.sh adr` / `lintorama` | the ADR router check; markdown, YAML, shell and editorconfig | after touching docs |
| `scripts/check.sh ios` | the SDK fixup check, then `xtool dev build` | after touching `Knit`, `KnitBLE` or `App/` |

## Other scripts

- **Coverage floors:** `python3 scripts/coverage-gate.py --scratch-path .build-cov --ratchet` raises the
  floors in `scripts/coverage-floors.json` to today's figures. It never lowers one.
- **Fuzzing:** `scripts/fuzz.sh [seconds]` builds `Fuzz/` with `-sanitize=fuzzer,address` and runs every
  harness against its corpus. CI's budget is 60 s; run 600 before a phase closes.
- **The Darwin SDK:** `scripts/xtool-sdk-fixup.sh [--check|--undo]` repairs the SDK bundle's clang headers
  after every `xtool sdk install` (`.agents/context/toolchain.md`).
- **DCO sign-offs:** `scripts/dco-check.sh <base> <head>` checks a commit range, the same check the CI job
  runs.
- **Vectors shared with knit-next:** `python3 scripts/sync-vectors.py` copies `vectors/wire-v1.json` and
  `vectors/keyed-v1.json` into `Tests/Vectors/`, and generates `Sources/KnitCrypto/AliasWords.swift` from
  `AliasWords.kt`. Each copy records the knit-next commit, and whether the source had uncommitted changes.
  `--check` fails when a copy is stale, and `--knit-next PATH` reads another checkout or worktree. Run it
  whenever the knit-next pin moves.
- **Vectors this port emits:** `KNIT_WRITE_VECTORS=1 swift test --filter EmittedVectorTests` rewrites
  `Tests/Vectors/ios-emitted-v1.json`, keeping every committed frame that is still current, so a rewrite
  moves only what changed. `scripts/sync-vectors.py --export` copies it into knit-next, where
  `IosEmittedVectorTest` checks it with Tink and kotlinx.
- **Sanitizer and analyzer exceptions:** `scripts/lsan-suppressions.txt` hides one Swift Testing leak from
  the ASan gate, and `scripts/swiftlint-analyze-linux.yml` keeps `import Foundation` from reading as unused
  on Linux. Each file says why, and when to delete it.

## The Linux peer

`.agents/context/linux-peer.md` has the whole surface; obey `.agents/rules/devices.md` before any of it.

```sh
swift build --product knit-peer                                   # .build/out/Products/Debug-linux-x86_64/knit-peer
knit-peer scan --seconds 20                                       # the Knit nodes in range, never dialing
knit-peer keygen --above <node id> [--below <node id>]            # an identity for one dial order
knit-peer run --radio-profile android --name "knit-peer"          # JSON lines on stdin and stdout
python3 scripts/interop.py check --device <adb serial> --order phone-dials   # checklist L, with the go-ahead
python3 scripts/interop.py check … --blank-name --expect-avatar   # alias parity; FILE records from a phone with a photo
python3 scripts/interop.py check … --radio-profile ios            # the ios group, against an A1 build
python3 scripts/interop.py refusal --device <adb serial>          # the ios profile against Android 2.7
python3 scripts/interop.py replace --device <adb serial>          # A1's stale-link replacement
python3 scripts/interop.py check … --send-mtu 247                 # smaller SDUs, for a phone that loses large ones
sudo scripts/hci1-supervision.sh                                  # hci1's supervision timeout to 5 s, until a replug
scripts/hci1-supervision.sh --udev-rule                           # a udev rule that sets it on every plug-in
```

## Decisions

```sh
python3 scripts/adr.py new "<the decision, as a claim>" --topics a,b   # scaffold; prints the citation
python3 scripts/adr.py index                                          # regenerate the router
python3 scripts/adr.py index --check                                  # CI and the pre-commit hook
python3 scripts/adr.py lint                                           # markdownlint over the ADRs
```

## One-time setup per clone

```sh
git config core.hooksPath .githooks      # ADR check, staged-file lint, DCO sign-off, pre-push gates
scripts/xtool-sdk-fixup.sh               # after any `xtool sdk install`
```
