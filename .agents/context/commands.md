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
| `scripts/check.sh periphery` | Periphery over the Swift Build index store; on the Mac, run `xcode periphery` for the app's index too | after deleting or renaming API; on Linux the Stop hook runs it when Swift changed |
| `scripts/check.sh adr` / `lintorama` | the ADR router check; markdown, YAML, shell and editorconfig | after touching docs |
| `scripts/check.sh xcode` | on the Mac: XcodeGen, then `xcodebuild` for the iPhone and the Simulator, unsigned, and the delegate check | after touching `Knit`, `KnitBLE` or `App/`, through `scripts/mac.sh run` |
| `scripts/check.sh uitest` | on the Mac: `KnitUITests` in the Simulator, every MVP screen through the accessibility audit at the default and the largest text size, into `.build-xcode/uitest.xcresult`; `KNIT_UI_TESTS` narrows the run | after touching a view, `Palette` or `App/`, through `scripts/mac.sh run` |
| `scripts/check.sh device` | on the Mac: the signed iPhone build, in the desktop session; renews the profile, with the App Store Connect API key when `KNIT_ASC_KEY_ID` and `KNIT_ASC_ISSUER_ID` name one, and prints its expiry | before installing on the iPhone |
| `scripts/check.sh devicetest` | on the Mac: `KnitDeviceTests` on the iPhone, signed in the desktop session, into `.build-xcode/devicetest.xcresult`; `KNIT_DEVICE` picks the phone, `KNIT_DEVICE_TESTS` narrows the run | after touching the radio, permissions, onboarding or the status line, with the go-ahead |
| `scripts/check.sh release` | on the Mac: the Release build for the iPhone, unsigned, checked for debug-only code, the privacy manifests, the export answer and the iPhone alone (ADR 2026-10.8cy5) | after touching `#if DEBUG`, the demo, `App/` or a dependency, through `scripts/mac.sh run` |
| `scripts/check.sh archive` | on the Mac: the App Store build, archived and checked as `release` checks, then signed for distribution in the desktop session and exported to `.build-xcode/export/Knit.ipa`; nothing leaves the Mac | before an upload, and after touching signing |
| `scripts/check.sh upload` | on the Mac: the same archive, uploaded to App Store Connect for TestFlight; raise `CURRENT_PROJECT_VERSION` first | to ship a build, with the go-ahead |
| `scripts/check.sh shots` | on the Mac: `KnitShots` in the "Knit shots" Simulator, an iPhone 18 Pro Max with its status bar frozen, every screen the store listing shows on the marketing scene in light and dark, into `.build-xcode/shots/<light\|dark>_<shot>.png` (ADR 2026-10.5u39); `KNIT_SHOTS` names some tests, `KNIT_SHOT_MODES` one appearance | for store screenshots, through `scripts/mac.sh run` |
| `scripts/check.sh trailer` | on the Mac: films the "Knit shots" Simulator while `-demoScene trailer` plays in the Nearby room, opened by `KnitTrailer`, into `.build-xcode/trailer/<mode>_trailer.mov` with its `.marks` (ADR 2026-10.g3k9); dark unless `KNIT_SHOT_MODES` names others | for the store's video, through `scripts/mac.sh run` |
| `scripts/check.sh clips` | on the Mac: films each of App Review's clips, a `KnitClips` test on its own `-demoScene`, into `.build-xcode/clips/<mode>_<clip>.mov` with its `.marks` (ADR 2026-10.yddp); `KNIT_CLIPS` names them (`block`), dark unless `KNIT_SHOT_MODES` names others | for App Review's video, through `scripts/mac.sh run` |

## Other scripts

- **The Mac Mini from here:** `scripts/mac.sh run <command…>` copies this working tree, `.git` included, to
  `~/source/knit-ios-mirror` on the Mac at `$KNIT_MAC_HOST` (set it, or put it in `.private/lab.env`), runs
  the command there and returns its exit status. Use `run bash -c '…'` for pipes and `&&`. `sync`, `pull
  <path> [dest]` and `shell` do one step each. Ignored files stay where they are, so each side keeps its own
  `.build/`, and `.env` and `.private/` never leave this machine. Anything changed in the mirror is lost at
  the next sync.
- **Coverage floors:** `python3 scripts/coverage-gate.py --scratch-path .build-cov --ratchet` raises the
  floors in `scripts/coverage-floors.json` to today's figures. It never lowers one.
- **Fuzzing:** `scripts/fuzz.sh [seconds]` builds `Fuzz/` with `-sanitize=fuzzer,address` and runs every
  harness against its corpus. CI's budget is 60 s; run 600 before a phase closes.
- **DCO sign-offs:** `scripts/dco-check.sh <base> <head>` checks a commit range, the same check the CI job
  runs.
- **The photo model:** `tools/models/nsfw/` converts the content filter's model and checks it (its `README.md`).
  `uv run python convert.py --check` there proves `App/Models/NSFW.mlpackage` is what the recipe writes, and
  `scripts/mac.sh run bash -c 'cd tools/models/nsfw && uv run --frozen python parity.py --coreml'` compares it with
  Android's TFLite. Run both whenever the model or one of its pins moves. In a debug build, the bridge's
  `{"cmd":"screen","photo":"<base64>"}` returns the iPhone's scores for a photo, and `score.py` returns Android's.
- **The text model:** `tools/models/toxicity/` does the same for the message classifier (its `README.md`), against
  Detoxify's checkpoint: `uv run python convert.py --check` there, and
  `scripts/mac.sh run bash -c 'cd tools/models/toxicity && uv run --frozen python parity.py --coreml'`. After a change
  to the tokenizer's Swift, `uv run python tokens.py` rewrites the ids `SentencePieceTokenizerTests` reads. The bridge's
  `{"cmd":"screen-text","text":"…"}` returns the iPhone's scores for a message, and `score.py "…"` the checkpoint's.
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
python3 scripts/interop.py check … --blank-name --expect-avatar   # alias parity; the phone's photo, pushed and adopted
python3 scripts/interop.py check … --peer-avatar <jpeg>           # the peer's photo, pushed to the phone
python3 scripts/interop.py check … --radio-profile ios            # the ios group, against an A1 build
python3 scripts/interop.py refusal --device <adb serial>          # the ios profile against Android 2.7 only
python3 scripts/interop.py replace --device <adb serial>          # A1's stale-link replacement, with a peer the phone never sights
python3 scripts/interop.py check … --send-mtu 8192                # SDUs above the default 247, to test a phone
python3 scripts/interop.py soak --device <serial> --extras        # MVP item 11's hour, both ways, with the go-ahead
python3 scripts/interop.py relay --device <serial>                # MVP item 7's line; a second peer on hci0, its go-ahead too
python3 scripts/interop.py relay … --expect-avatar --peer-avatar <jpeg>   # photos pulled through the middle peer
python3 scripts/interop.py check … --mac                          # checklist M: the peer on the Mac, on CoreBluetooth (ADR 2026-09.vcdk)
python3 scripts/interop.py soak … --mac --extras                  # checklist M's hour, the peer on the Mac
python3 scripts/interop.py iphone --device <serial>               # MVP items 2 to 6, iPhone and phone both driven; Knit open on both
python3 scripts/interop.py iphone --device <serial> --links 10    # the same, then links up to ten, each ending at the 5 s timeout; the iPhone above the phone
python3 scripts/interop.py iphone-peer --order iphone-above       # the same against a fresh peer on hci0; iphone-below is the other order
python3 scripts/interop.py iphone-relay --device <serial>         # MVP item 7: phone, iPhone, then a peer on hci0; Knit open on both
python3 scripts/interop.py iphone-relay … --expect-avatar --peer-avatar <jpeg>   # each end's photo, served by the iPhone between them
python3 scripts/interop.py iphone-group --device <serial>         # v1 groups along that line, the peer as the third member (ADR 2026-09.n393)
python3 scripts/interop.py group --device <serial>                # v1 groups between two peers and the phone, which needs two links free
python3 scripts/interop.py iphone-soak --device <serial> --peer --extras   # MVP item 11 on the iPhone: an hour, the peer on hci0; Auto-Lock off
python3 scripts/interop.py iphone-wake --device <serial>          # MVP item 9 from the phone: someone locks the iPhone, a DM a minute
python3 scripts/interop.py iphone-wake --device <serial> --expect-wakes   # the same from an A4 build, which must ring and wake Knit for every DM
python3 scripts/interop.py iphone-wake --sender peer              # the same from a peer on hci0, which rings the iPhone's doorbell
python3 scripts/interop.py android-keeps-iphone --device <serial> --quiet <serials…>   # AND-3: the phone keeps a backgrounded iPhone's link and admits its re-dial; devicectl moves Knit, nobody at the iPhone
python3 scripts/interop.py iphone-reboot --restart                # MVP item 1: the identity survives closing Knit and a reboot; someone unlocks
python3 scripts/interop.py iphone-rings                           # the iPhone rings a peer's doorbell (hci1, ios profile); Knit open
python3 scripts/interop.py android-rings --device <serial>        # A4: custody converges, then an Android phone rings the peer's doorbell (hci1, ios profile; --link dialed|accepted)
python3 scripts/interop.py android-reads --device <serial> --order peer-below|peer-above   # A3's gate: the phone reads the peer's GATT payload, and dials it or is dialed
python3 scripts/interop.py android-reads --device <serial> --order peer-above --links 10  # #102: ten links the peer dials, each ending at the 5 s timeout
python3 scripts/interop.py android-forgets --device <serial>     # A3's gate: each forget rule of the payload lifetime fires once on the phone
python3 scripts/interop.py android-strangers --device <serial> --variant none|forged --quiet <other serials>   # knit-next #154: beside a rotating 0xFE30 stranger, reads stay in budget and dials never wait
python3 scripts/interop.py iphone-forgets --hci0                 # each forget rule fires once on the iPhone (hci0 needs its go-ahead)
python3 scripts/interop.py iphone-scan --first ios --away-window 150   # P8's scan-filter check: peers on hci0 and hci1; someone locks the iPhone
python3 scripts/interop.py iphone-seek --far hci1 --mode drop [--drop radio-off]   # does a locked Knit hear a link a peer dialed end? someone locks the iPhone
python3 scripts/interop.py iphone-seek --far hci0|phone --mode relink [--device <serial>]   # the far side restarts; Knit relinks while locked (go-ahead)
python3 scripts/interop.py iphone-seek --far hci1 --mode budget --minutes 10   # no link, a peer it cannot dial: seeking stops at eight wakes
python3 scripts/interop.py bridge '{"cmd":"status"}' --watch 60   # the iPhone's bridge by hand: replies, then events
python3 scripts/interop.py bridge '{"cmd":"wifi-pin"}'           # over USB: let the bridge listen on Wi-Fi on this network
python3 scripts/interop.py bridge --host <phone-ip> '{"cmd":"wifi"}'   # over Wi-Fi: the network, its pin, the listener
python3 scripts/interop.py bridge --host <phone-ip> '{"cmd":"record-start","mic":true}'   # record the screen; someone taps Allow
python3 scripts/interop.py record-pull --host <phone-ip> --out take.mp4   # record-stop, then fetch, check and delete the file
python3 scripts/soak.py run [--hours 10]                          # a night against every phone in range; drives none
python3 scripts/soak.py status | report [--json] | stop           # the latest run (.build/soak/current)
sudo scripts/hci1-supervision.sh                                  # dongles A and B's supervision timeout to 5 s, until a replug
sudo scripts/bluetoothd-no-battery.sh [--undo]                    # bluetoothd without its battery plugin, for iPhone runs
scripts/hci1-supervision.sh --udev-rule                           # udev rules that set it on every plug-in
scripts/knit-hci.sh [a|b] name                                    # dongle A's (or B's) hciN this boot; adapters go by address
sudo knit-hci [a|b] btmon -w capture.btsnoop                      # root tools on Knit's adapters alone (devices.md); also hcitool, btmgmt
scripts/dongle-firmware.sh build                                  # firmware/knit-hci for the nRF52840 dongles
scripts/dongle-firmware.sh flash /dev/ttyACM0                     # over USB, once its reset button put it in its bootloader
```

`scripts/mac-peer.sh` runs on the Mac, and `interop.py --mac` calls it over ssh. `build` builds knit-peer and signs
it in the desktop session with a fixed identifier, so macOS's one Bluetooth grant lasts across builds; `run` starts it
there through `scripts/mac-desktop.sh --stdio`, with stdin and stdout attached to the caller.

## The app

Every iPhone build comes from the Mac (ADR 2026-09.fkqb). With the iPhone on this machine's USB:

```sh
idevicesyslog -p Knit                                             # the app's log, one JSON line per entry in a debug build
idevicecrashreport -k -e <dir>                                    # copy the phone's crash and hang reports, keeping them there
ifuse --container app.getknit.knit.dev -o ro <dir>                # mount Knit's sandbox read-only; fusermount -u <dir> to drop it
iproxy 5648:5648                                                  # the debug bridge on localhost:5648, for any client
```

The build, from here through `scripts/mac.sh run` (the Mac's own checkout takes the same commands).
`check.sh xcode` generates `App/Knit.xcodeproj`, which Xcode opens for the Simulator and the scheme's launch
arguments:

```sh
scripts/mac.sh run scripts/check.sh xcode                         # .build-xcode/Build/Products/Debug-iphoneos/Knit.app, and -iphonesimulator
scripts/mac.sh run scripts/check.sh device                        # the same app, signed for the iPhone (team and API key in App/Local.xcconfig)
scripts/mac.sh run scripts/mac-desktop.sh <command…>              # any command in the Mac's desktop session, where the Keychain is open
scripts/mac.sh run scripts/check.sh devicetest                    # the device tests on the iPhone: unlocked, Auto-Lock off, UI Automation on, passcode typed on the phone each run; with the go-ahead
scripts/mac.sh run env KNIT_DEVICE_TESTS=KnitDeviceTests/RadioTests scripts/check.sh devicetest   # one class, or Class/testName
scripts/mac.sh run env KNIT_DEVICE_KEEP_KNIT=build scripts/check.sh devicetest   # builds the steps that leave the running Knit alone
KNIT_MAC_SYNC=0 scripts/mac.sh run env KNIT_DEVICE_KEEP_KNIT=1 KNIT_DEVICE_TESTS=KnitDeviceTests/BackgroundTests/testSendKnitToBackground scripts/check.sh devicetest   # or testBringKnitToFront
scripts/mac.sh run env KNIT_UI_TESTS=KnitUITests/KnitUITests/testTheChatListAndTheRoomTakeAPost scripts/check.sh uitest   # one walk
scripts/mac.sh run xcrun xcresulttool get test-results summary --path .build-xcode/devicetest.xcresult   # what failed, and why
scripts/mac.sh run bash -c 'xcrun simctl boot "iPhone 18 Pro"; xcrun simctl install booted .build-xcode/Build/Products/Debug-iphonesimulator/Knit.app'
scripts/mac.sh run xcrun simctl launch --terminate-running-process booted app.getknit.knit.dev -seedDemo -demoScene marketing
scripts/mac.sh run xcrun simctl io booted screenshot .build-xcode/shot.png   # then: scripts/mac.sh pull .build-xcode/shot.png
scripts/mac.sh run scripts/check.sh shots                         # the store's screenshots, then: scripts/mac.sh pull .build-xcode/shots
scripts/mac.sh run env KNIT_SHOTS="testChatList testNearby" KNIT_SHOT_MODES=dark scripts/check.sh shots   # some, in one appearance
scripts/mac.sh run scripts/check.sh trailer                       # the store's video, then: scripts/mac.sh pull .build-xcode/trailer
scripts/mac.sh run scripts/check.sh clips                         # App Review's clips, then: scripts/mac.sh pull .build-xcode/clips
xcrun devicectl list devices                                      # at the Mac, once the iPhone is paired (toolchain.md)
xcrun devicectl device install app --device <id> .build-xcode/Build/Products/Debug-iphoneos/Knit.app   # after check.sh device, with the go-ahead
xcrun devicectl device process launch --device <id> app.getknit.knit.dev   # launches Knit, which otherwise waits for someone to open it
scripts/mac.sh run scripts/check.sh release                       # .build-xcode/Build/Products/Release-iphoneos/Knit.app, unsigned
scripts/mac.sh run scripts/check.sh archive                       # .build-xcode/Knit.xcarchive and .build-xcode/export/Knit.ipa, for the App Store
scripts/mac.sh run scripts/check.sh upload                        # the same, to App Store Connect; CI's manual release:testflight runs it from main
```

A store build is `app.getknit.knit`, a separate app from the `.dev` build, and only one Knit fits on a phone. It reads
no launch argument: `-seedDemo` and the flags below work only in a debug build (ADR 2026-10.8cy5). Before an upload,
raise `CURRENT_PROJECT_VERSION` in `App/project.yml` and `CFBundleVersion` in `App/Info.plist` together.

A debug build answers `knit-peer`'s control lines on the phone's loopback, port 5648 (ADR 2026-09.kwa8), while
Knit is open. `scripts/interop.py` starts `iproxy` itself; run it by hand only to reach the bridge from something
else, with one JSON command per line.

On a network pinned over USB, the bridge also listens on the phone's Wi-Fi address, port 5648 (ADR 2026-10.dz8d).
`wifi-pin` over USB pins the network the phone is on, `wifi` reports the network, the pins and where the bridge
listens, and `wifi-unpin` (with `"all":true` for every network) undoes a pin. Every iPhone command in
`interop.py` then takes `--host <phone-ip>`, or `KNIT_IPHONE_HOST`; `--host ''` forces USB. The log, crash reports
and restarts still need the cable. Keep the phone on 5 GHz Wi-Fi for runs that time the BLE link, since 2.4 GHz
Wi-Fi shares the phone's radio with Bluetooth.

The bridge records the screen for knit-next's demo film (ADR 2026-10.x2cq), with ReplayKit's in-app recorder:
only Knit's own screens, and the microphone unless `"mic":false`. Every reply echoes `tag`, and a refusal carries
`"ok":false`, a `code` and an `error`.

| Command | Answer |
| --- | --- |
| `{"cmd":"record-start","mic":true}` | once recording runs: `"recording":true`, `microphone`, `startedAt` (wall ms). A ReplayKit recording left over from before is stopped first. Refused with `busy`, `declined`, `unavailable`, `timeout` (nobody tapped Allow within 120 s), `elsewhere` (ReplayKit still says it records, as with Control Center's Screen Recording running) or `failed` |
| `{"cmd":"record-stop"}` | the finished file: `file`, `bytes`, `sha256`, `startedAt`, `durationMs`, `microphone`, `endedBy` (`stop` or `background`). Asked again, the same answer. Refused with `idle`, `busy` (still starting), `lost` (iOS ended the take and kept nothing), `empty` (stopped before the screen changed, so no frame and no file) or `failed` |
| `{"cmd":"record-fetch","offset":0,"length":1048576}` | `data`, base64 of at most 1 MiB (`length` defaults to that and is capped there), with `offset`, `length`, `bytes` and `eof`. Refused with `none` or `range` |
| `{"cmd":"record-delete"}` | `deleted`, the file's name or `null` |
| `{"cmd":"record-status"}` | `state` (`idle`, `stale`, `starting`, `recording` or `finishing`), `capturing` (what ReplayKit itself says), `take` (as `record-stop` gives it, or `null`) and `lost`. `stale` is ReplayKit recording while the bridge asked for nothing; the next start stops it |

iOS asks the person holding the phone at a start, and an Allow covers further starts for eight minutes (seen on iOS
27.0.1), so a `record-start` then `record-stop` at prep time covers a take that starts within that window. Leaving Knit ends the take and keeps the file, which
`record-stop` returns once Knit is back. A new start deletes the last file, and a relaunch forgets it. Pulling runs a
megabyte per round trip; `record-pull` prints the rate it got.

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
- `-demoOnboarding` (with `-seedDemo`) starts at onboarding, as a first run does. The UI tests walk it.
- `-demoCamera denied|allowed` (with `-seedDemo`) gives the profile's scanner a camera that answers one thing. The
  Simulator has no scanner, so this is how the UI tests reach the refused state and the one where the camera fails
  to start (ADR 2026-10.65xx). Without it the Simulator shows the state for a device that cannot scan.
- `-demoNotification` (with `-seedDemo`) asks to notify at launch, then posts the room's notification each time
  Knit goes to the background. Nothing reaches the demo's radio, so this is how the UI tests get a notification to
  tap.
- `-demoScene edge-cases|fresh|marketing` (with `-seedDemo`) picks what is seeded. `fresh` seeds nothing, so the chat
  list shows its first-run card. `edge-cases`, the default, is the
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
```
