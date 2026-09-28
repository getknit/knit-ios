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

- **The Mac Mini from here:** `scripts/mac.sh run <command…>` copies this working tree, `.git` included, to
  `~/source/knit-ios-mirror` on the Mac, runs the command there and returns its exit status. Use
  `run bash -c '…'` for pipes and `&&`. `sync`, `pull <path> [dest]` and `shell` do one step each. Ignored
  files stay where they are, so each side keeps its own `.build/`, and `.env` and `.private/` never leave
  this machine. Anything changed in the mirror is lost at the next sync.
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
knit-peer scan --seconds 20                                       # the Knit nodes in range, iPhones too; never dials
knit-peer keygen --above <node id> [--below <node id>]            # an identity for one dial order
knit-peer run --radio-profile android --name "knit-peer"          # JSON lines on stdin and stdout
python3 scripts/interop.py check --device <adb serial> --order phone-dials   # checklist L, with the go-ahead
python3 scripts/interop.py check … --blank-name --expect-avatar   # alias parity; FILE records from a phone with a photo
python3 scripts/interop.py check … --radio-profile ios            # the ios group, against an A1 build
python3 scripts/interop.py refusal --device <adb serial>          # the ios profile against Android 2.7
python3 scripts/interop.py replace --device <adb serial>          # A1's stale-link replacement
python3 scripts/interop.py check … --send-mtu 8192                # SDUs above the default 247, to test a phone
python3 scripts/interop.py soak --device <serial> --extras        # MVP item 11's hour, both ways, with the go-ahead
python3 scripts/interop.py relay --device <serial>                # MVP item 7's line; a second peer on hci0, its go-ahead too
python3 scripts/interop.py iphone --device <serial>               # MVP items 2 to 6, iPhone and phone both driven; Knit open on both
python3 scripts/interop.py iphone-relay --device <serial>         # MVP item 7: phone, iPhone, then a peer on hci0; Knit open on both
python3 scripts/interop.py iphone-wake --device <serial>          # MVP item 9 from the phone: someone locks the iPhone, a DM a minute
python3 scripts/interop.py iphone-wake --device <serial> --expect-wakes   # the same from an A4 build, which must ring and wake Knit for every DM
python3 scripts/interop.py iphone-wake --sender peer              # the same from a peer on hci0, which rings the iPhone's doorbell
python3 scripts/interop.py iphone-rings                           # the iPhone rings a peer's doorbell (hci1, ios profile); Knit open
python3 scripts/interop.py android-rings --device <serial>        # A4: custody converges, then an Android phone rings the peer's doorbell (hci1, ios profile)
python3 scripts/interop.py iphone-scan --first ios --away-window 150   # P8's scan-filter check: peers on hci0 and hci1; someone locks the iPhone
python3 scripts/interop.py bridge '{"cmd":"status"}' --watch 60   # the iPhone's bridge by hand: replies, then events
python3 scripts/soak.py run [--hours 10]                          # a night against every phone in range; drives none
python3 scripts/soak.py status | report [--json] | stop           # the latest run (.build/soak/current)
sudo scripts/hci1-supervision.sh                                  # hci1's supervision timeout to 5 s, until a replug
sudo scripts/bluetoothd-no-battery.sh [--undo]                    # bluetoothd without its battery plugin, for iPhone runs
scripts/hci1-supervision.sh --udev-rule                           # a udev rule that sets it on every plug-in
```

## The app

```sh
scripts/check.sh ios                                              # xtool dev build: xtool/Knit.app
xtool dev run --usb                                               # build, sign and install on the iPhone, with the go-ahead
idevicesyslog -p Knit                                             # the app's log, one JSON line per entry in a debug build
idevicecrashreport -k -e <dir>                                    # copy the phone's crash and hang reports, keeping them there
ifuse --container XTL-<team id>.app.getknit.knit -o ro <dir>     # mount Knit's sandbox read-only; fusermount -u <dir> to drop it
iproxy 5648:5648                                                  # the debug bridge on localhost:5648, for any client
```

A debug build answers `knit-peer`'s control lines on the phone's loopback, port 5648 (ADR 2026-09.kwa8), while
Knit is open. `scripts/interop.py` starts `iproxy` itself; run it by hand only to reach the bridge from something
else, with one JSON command per line.

The debug log carries link events, not messages; the bridge's `messages`, `peers` and `digest` answer what the
store holds. When Knit is not running, copy
`<dir>/Library/Application Support/Database/knit.sqlite` and its `-wal` out of the mount and open the copy with
`sqlite3`. The mount is read-only, and SQLite needs to write the `-shm` file. Text columns are UTF-8 blobs, so
cast them (`CAST(body AS TEXT)`). `messages.arrivedAt - sentAt` gives the delay across the air, and `delivered`
is the tick.

Launch arguments, set in the scheme on the Mac (P7):

- `-seedDemo` runs the app on seeded stores in memory, a fixed identity and a radio that goes nowhere: four
  people, a room conversation, an accepted DM and a message request.
- `-demoRadio on|off|unauthorized|unsupported` (with `-seedDemo`) is the state that radio reports, which is how
  the status line's messages are checked, the unsupported device's among them (MVP item 10).
- `-demoScene edge-cases|marketing` (with `-seedDemo`) picks what is seeded. `edge-cases`, the default, is the
  cast above: two people with one name, one with none, and nobody linked. `marketing` is for store screenshots
  and social posts, after knit-next's hiking theme: seven named people, a room, two DMs and a request, with
  three people shown as linked (`DemoMesh`), so the status line reads "Connected to 3 nearby devices".

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
