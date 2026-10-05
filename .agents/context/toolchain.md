# Toolchain

The versions are deliberate. Before changing one, run the `upgrade-notes` skill (`.agents/skills/`) for the
exact interval, then update this file in the same change.

## Swift

- **Toolchain:** Swift 6.4 through swiftly (`.swift-version` pins `6.4.0`). Its `swift` binary is a proxy,
  so scripts ask the compiler for its paths (`swift -print-target-info`) rather than resolving the binary.
- **Build system:** Swift Build (`swiftbuild`) is SwiftPM's default from 6.4; the native build system is
  deprecated. Build products live under `.build/out/Products/<Configuration>-<platform>/`, and the index
  store is `.build/out`.
- **Manifest:** `swift-tools-version: 6.2`, for `.treatAllWarnings(as: .error)` and `.strictMemorySafety()`.
- **Strict settings** (in `Package.swift`):
  - Swift 6 language mode, with complete concurrency checking;
  - warnings as errors (remote dependencies are suppressed by Swift Build, so theirs cannot fail us);
  - `ExistentialAny`, `InternalImportsByDefault` and `MemberImportVisibility`;
  - strict memory safety on the platform-free targets.
- **Escape hatch:** `KNIT_WARNINGS_AS_ERRORS=0` builds through a new toolchain's warnings locally. CI never
  sets it.

## The iPhone app

- **Built on the Mac only** (ADR 2026-09.fkqb). Xcode builds the project `App/project.yml` generates (ADR
  2026-09.de8f), and "The Mac" below has the setup. xtool, which built the app on Linux until 2026-09-28,
  is retired, and nothing on Linux compiles `Knit` or `KnitBLE` for iOS.
- **Static archives:** the app links each package target as a static archive, and the linker keeps only the
  members something names. A file that only the Objective-C runtime calls into, like KnitBLE's CoreBluetooth
  delegates, is dropped without a warning; the first install on the iPhone stopped at the Bluetooth grant for
  that reason. The `Knit` target links with `-ObjC`, and `scripts/check.sh xcode` checks the app for the
  delegate methods.
- **Free provisioning:** on a free Personal Team an install lasts 7 days, and the phone trusts the developer once
  under VPN & Device Management. The maintainer's team has been a paid one since 2026-10-03, and its development
  profiles last a year ("Signing on the Mac" below). An install waits at Verifying while Knit is open on the
  phone, until someone swipes it away.

## Linters and analyzers

- **SwiftLint 0.65.1** (`/usr/local/bin/swiftlint` here; CI installs the pinned `swiftlint_linux_amd64.zip`
  or `swiftlint_linux_arm64.zip` to match the runner, and checks each against its own SHA-256). On Linux it needs SourceKit from the toolchain:
  `LINUX_SOURCEKIT_LIB_PATH=~/.local/share/swiftly/toolchains/6.4.0/usr/lib`. The scripts and hooks derive
  it themselves.
- **swift-format** comes with the toolchain (`swift format`), configured in `.swift-format`.
- **Periphery 3.8.0** blocks on both platforms (ADR 2026-09.xgtz). It finds the Swift Build index store only
  when told to (`--index-store-path .build/out`), which `scripts/check.sh periphery` does. On the Mac the gate
  also reads the iPhone build's index in `.build-xcode`, so run `check.sh xcode periphery` there, and leaves
  `KnitBlueZ` to Linux. An index keeps records of deleted files until the tree is rebuilt, so clear
  `.build/out` before trusting a finding in code that is gone. A Claude Stop hook,
  `.claude/hooks/periphery-stop.sh`, runs the Linux gate whenever the Swift files changed since its last clean
  pass (ADR 2026-09.jgs6). Periphery ships macOS binaries only, so on Linux it is built from source and
  installed at user level:

  ```sh
  git clone --depth 1 --branch 3.8.0 https://github.com/peripheryapp/periphery.git
  cd periphery && swift build -c release --product periphery
  install -m 0755 .build/out/Products/Release-linux-x86_64/periphery ~/.local/bin/periphery
  ```

- **`swiftlint analyze` skips `KnitAppCore`, `Knit` and `KnitBLE` on Linux.** The last two compile to empty
  modules here. For `KnitAppCore`, SourceKit, run in-process by SwiftLint 0.65.1 with the Swift 6.4 toolchain,
  crashes (SIGSEGV) expanding `@Observable` in any file of the module, whether macro plugins load in-process or
  through `swift-plugin-server`; the real compiler builds the same files under every other gate.
  `scripts/swiftlint-analyze-linux.yml` holds the exclusions, since SwiftLint analyzes every file its
  configuration includes whatever paths it is given. The Mac runner analyzes the whole tree. Try `KnitAppCore`
  again on the next toolchain or SwiftLint, and drop it from the list once it passes.
- **`swiftlint analyze` needs about ten file descriptors per analyzed file.** SourceKit keeps each file's
  compiler instance and its Clang `.pcm` modules open until the run ends. The `swift` image's soft limit of
  1024 runs out about a hundred files in, and SourceKit then fails every request and crashes (exit 132), so
  `check.sh analyze` raises the soft limit to the hard one first.
- **lintorama:** `zaventh/lintorama:7` runs yamllint, the GitLab CI schema, actionlint, shellcheck, mdl and
  editorconfig-checker over every tracked file, through its `lint-extras` entrypoint.

## System packages

- **Needed:** `libdbus-1-dev` and `pkg-config` (the `CDBus` target), `libsqlite3-dev` (GRDB on Linux),
  `docker` (lintorama), and `usbmuxd`/libimobiledevice for installing on a phone later.
- **GRDB on Linux (spike a, 2026-09-25):** GRDB 7.11.1 builds and passes under Swift Build against the
  system SQLite (3.45.1: a WAL pool, migrations, BINARY ordering), and cross-built for `arm64-apple-ios`
  against the SDK's SQLite. `KnitStoreSQL` and its tests build on Linux like the other platform-free
  targets.
- **GRDB in the package (P5):** pinned at 7.11.1 in both `Package.resolved` files. The `STRICT` tables need
  SQLite 3.37 or later: iOS 18 and noble both have it, and an older SQLite fails the first migration rather
  than opening a looser schema. CI's Swift image installs `libsqlite3-dev` in `.swift`'s `before_script`.
- **Not needed:** `libbluetooth-dev`. `CBluetoothShim` writes out the few socket definitions itself.

## CI

- **GitLab runs the gating pipeline,** `.gitlab-ci.yml`, on the maintainer's own runners. The light Linux jobs
  run in the `swift:6.4-noble` image (pinned by digest), on amd64 and arm64 alike. The heavy ones (`test:tsan`,
  `test:asan`, `verify:fuzz`, `verify:analyze` and `verify:periphery:linux`) run on a shell runner with no
  memory cap (ADR 2026-09.fkqb), and every Apple job runs on the Mac below. Runner setup is in the
  maintainer's private notes.
- **GitHub Actions checks pull requests** (`.github/workflows/`): the DCO sign-off, then format, lint, build,
  tests and coverage in the same `swift:6.4-noble` image, plus the ADR router and lintorama. Those jobs need no
  Mac, phone or Bluetooth adapter. The sanitizers, fuzzing, analyze, Periphery and the iPhone build run on
  GitLab only.
- **Runners differ in speed.** `test:coverage` took 643 s on the slowest Linux runner and about 250 s on the
  fastest (2026-09-28). A test that waits on a thread needs a deadline with room for that, as
  `LoopRig.settleMilliseconds` has.
- **`verify:analyze` needs more than 8 GB on Linux.** SourceKit keeps every file's compiler instance until the
  run ends, and an 8 GB cap killed it at 8.35 GB.
- **Architectures:** `swift:6.4-noble`, `python:3.13-alpine`, `alpine/git` and `zaventh/lintorama:7` all
  publish arm64 images. The line total can differ from amd64 by a line or so (10827 against 10826 of 11114),
  which the whole-percent floors absorb.

## The model pipeline

`tools/models/nsfw/` converts the photo classifier into `App/Models/NSFW.mlpackage` and checks it against
Android's TFLite (its `README.md` has the steps). It is Python 3.11 through uv, and `uv.lock` pins everything.

- **coremltools 9.0**, the newest release. Its TensorFlow 2 frontend is tested up to **TensorFlow 2.12.0**,
  which caps **numpy at 1.23.5**. Moving any of the three means rerunning `convert.py --check` and
  `parity.py --coreml`.
- **TensorFlow installs on Linux only** (`tensorflow-cpu`, behind a `sys_platform` marker): 2.12 has no wheel for
  Apple silicon. The Mac's half, `parity.py --coreml`, needs only coremltools and numpy.
- **The conversion is reproducible.** coremltools writes the same weights on every run. `convert.py` replaces the
  manifest's random UUIDs with ones derived from each part's path, drops the conversion date from the spec, and
  writes the spec's maps in key order, so `--check` compares bytes.

`tools/models/toxicity/` does the same for the message classifier (ADR 2026-10.e4kz), from Detoxify's PyTorch
checkpoint, also Python 3.11 through uv with its own `uv.lock`.

- **coremltools 9.0, torch 2.7.0 and transformers 4.57.6.** coremltools 9.0 is tested with PyTorch up to 2.7.0; a
  newer one converts with a warning, and 2.7.1 wrote a different spec. Moving any of the three means rerunning
  `convert.py --check` and `parity.py --coreml`.
- **torch, transformers and ai-edge-litert install on Linux only,** torch from PyTorch's CPU index. The Mac's half,
  `parity.py --coreml`, needs only coremltools and numpy (2.2.6 here; the photo pipeline keeps 1.23.5 for TensorFlow).
  `ai-edge-litert` 2.1.5, the version detoxify-mobile validates with, runs Android's TFLite for comparison.

## Dongle firmware

`firmware/knit-hci` is the Bluetooth controller the Linux peer runs on, built for the nRF52840 Dongle
(`.agents/context/linux-peer.md`, "The nRF52840 dongles"). It builds outside SwiftPM, with its own tools, all
installed at user level. `scripts/dongle-firmware.sh` checks the Zephyr commit before it builds.

- **Zephyr `v4.4-branch` at `f8523a9c66`**, 208 commits past v4.4.2, in a west workspace at `~/zephyrproject`
  with west 1.5.0 in its `.venv`. The project filter keeps only `hal_nordic`, `cmsis` and `cmsis_6`. v4.4.2
  itself wedges the dongles (`ea86c1235c` fixed it on the branch), so move to v4.4.3 once it is tagged rather
  than back to v4.4.2.
- **Zephyr SDK 1.0.1**, the version Zephyr 4.4 asks for: the minimal bundle in `~/zephyr-sdk-1.0.1` and only its
  `arm-zephyr-eabi` GNU toolchain (GCC 14.3.0), both checked against the release's `sha256.sum`, registered with
  `setup.sh -c`.
- **nrfutil 8.2.1** in `~/.local/bin`, Nordic's closed-source launcher, with its `nrf5sdk-tools` command 1.1.0
  for the Open Bootloader's DFU packages. Flashing needs the user in `dialout`, for the bootloader's `ttyACM`
  port.

## The Mac

An M6 Mac Mini with 12 cores and 16 GB on macOS 27.0, set up on 2026-09-27, builds and tests the iPhone app. It
logs in to the desktop by itself, because the Simulator and signing need a desktop session.

- **Xcode 27.0 (`27A266a`)** is the selected developer
  directory. The iOS 27.0 Simulator runtime came with it, and developer mode is on. Its Swift is 6.4
  (`swiftlang-6.4.0.34.1`), which matches `.swift-version`, so the Mac builds with Xcode's toolchain and has
  no swiftly.
- **Homebrew has the rest:** SwiftLint 0.65.1 and Periphery 3.8.0 (the pinned versions); XcodeGen 2.46.0;
  bash 5 and Python 3.14, because macOS ships bash 3.2 and Python 3.9; xcbeautify, xcodes, libimobiledevice and
  ideviceinstaller; rsync 3, because macOS ships openrsync; uv 0.12, for the model pipeline's parity check. Put Homebrew on the `PATH` for every shell, login or
  not, in `~/.zshenv` and `~/.bash_profile`.
- **Docker runs in Colima,** a `vz` VM with Rosetta, 4 CPUs, 4 GB and 4 GB of swap, started at login. It runs
  lintorama there. `zaventh/lintorama:7` publishes an arm64 image, so it runs without Rosetta.
- **`scripts/mac.sh` drives the Mac from Linux** (`.agents/context/commands.md`). It owns
  `~/source/knit-ios-mirror` on the Mac and overwrites it with the local working tree at each sync, so do real
  work at the Mac in a checkout of its own. It calls `/opt/homebrew/bin/rsync` by path: openrsync speaks
  protocol 29 and gets the filter rules wrong.
- **What passes there** (2026-09-27, at `b03c841`): `check.sh fast`, in three minutes. `xcodebuild build
  -scheme Knit` builds every target of the package for `generic/platform=iOS` and for the Simulator,
  unsigned, with no Xcode project.
- **The app project** (ADR 2026-09.de8f): XcodeGen generates `App/Knit.xcodeproj` from `App/project.yml`,
  and `check.sh xcode` builds it unsigned for the iPhone and the Simulator into `.build-xcode`. The
  `build:ios:xcode` job runs the same gate on the `macos` runner. The app target is only a host: one `stub.c`,
  linked to the package's `Knit` product.
  - **Version keys:** a generated `Info.plist` takes its version keys from `MARKETING_VERSION` and
    `CURRENT_PROJECT_VERSION`, not from `App/Info.plist`, so `project.yml` repeats both and the gate checks
    they agree.
  - **Package pins:** the project keeps a `Package.resolved` of its own. The gate seeds it from the root
    file and fails if the pins drift.
  - **The debug dylib:** a Debug build keeps the app's code in `Knit.debug.dylib`, where the gate looks for
    KnitBLE's delegate methods.
- **Signing on the Mac:** Xcode is signed in to the maintainer's team, a free Personal Team until it joined the
  Apple Developer Program on 2026-10-03 under the same team id. Its first run on the iPhone (2026-09-27) made an
  Apple Development certificate and a profile for `app.getknit.knit.dev`. Set up once at
  the desk: Xcode, Settings, Accounts, the Apple ID; the iPhone plugged in and trusted, then set to "Connect via
  network" in Devices so it can go back to its usual machine's USB. `App/Local.xcconfig` (git ignores it) holds
  `DEVELOPMENT_TEAM = <team id>`.
  - **Signing runs in the desktop session** (ADR 2026-09.zawh). Over ssh, `codesign` fails with
    `errSecInternalComponent`, even after "Always Allow" on the key and under `sudo launchctl asuser`: the
    login Keychain stays locked to an ssh session. `scripts/mac-desktop.sh` runs a command as a one-shot
    launchd job in `gui/501`, where the Keychain is open, and `check.sh device` builds the signed app through
    it. `-allowProvisioningUpdates` renews the profile there too: with the cached one moved aside, it
    fetched a new one from Apple (2026-09-28). CI's `build:ios:signed` takes the same path, with the team in
    `KNIT_DEVELOPMENT_TEAM`.
  - **The command line lost the account (2026-09-28, late).** `xcodebuild` reported "No Accounts" over ssh and in
    the desktop session alike, while Xcode's window listed the account with the Personal Team, and Xcode's
    `DVTDeveloperAccountManagerAppleIDLists` preference was empty. It signs with profiles it already has but
    makes none.
  - **An App Store Connect API key gets past it.** `check.sh device` and `devicetest` hand `xcodebuild` the key
    that `KNIT_ASC_KEY_ID` and `KNIT_ASC_ISSUER_ID` name, read from the environment or else `App/Local.xcconfig`,
    with its `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` or `KNIT_ASC_KEY_PATH`. With the
    cached `.dev` profile moved aside, the key fetched a new one from Apple (2026-10-03). Without a key, a new App
    ID's profile, or one that expired, comes from Xcode's window: open the mirror's `App/Knit.xcodeproj`, pick the
    scheme and the iPhone, and build (Product → Build For → Testing for the device tests).
  - **`app.getknit.knit` belongs to the App Store build.** It was registered to the team on 2026-10-03, through the
    App Store Connect API. Development builds still sign only the `.dev` id, so a development build and a
    TestFlight build are two apps, each with a Keychain identity of its own.
  - **The App Store build** (ADR 2026-10.8cy5): `check.sh archive` archives the `Knit` scheme in Release through
    `mac-desktop.sh`, signed for development as any archive under automatic signing is, and the export signs it again
    for distribution. On 2026-10-03 the API key's first export made `iOS Team Store Provisioning Profile:
    app.getknit.knit` and signed with `Apple Distribution: … (<team id>)`. That identity is not in the Mac's
    Keychain, where `security find-identity` lists only the development one, so it looks cloud-managed: Apple holds
    the key. `check.sh upload` uploads the same build.
  - **Exporting needs macOS's rsync first on the `PATH`.** Packaging runs `/usr/bin/rsync`, which starts its other
    end as the first `rsync` on the `PATH`. Homebrew's rsync 3 refused `--extended-attributes`, and the export failed
    with "Copy failed" (2026-10-03). `check.sh archive` puts `/usr/bin` first for the export alone.
  - **One Knit per phone.** Two installs would both advertise the GATT payload and scan, and a peer would see
    two nodes on one iPhone, as with Android, which has no debug package for that reason.
  - **The `.dev` profile lasts a year** from 2026-10-03, the first under the paid membership. The device tests'
    profiles are still the free team's 7-day ones, which expire on 2026-10-05 and 2026-10-06; the next
    `check.sh devicetest` renews them with the key. `check.sh device` prints the profile's expiry.
  - **The device tests need the phone ready:** Settings → Developer → Enable UI Automation on, the phone unlocked,
    and Auto-Lock off for the run. With a passcode set, every run waits on the phone for the passcode before iOS
    enables automation mode, and times out if nobody enters it in time.
  - **Installing from the Mac (2026-09-28):** `check.sh device` builds the signed app, and `devicectl device
    install app` then `devicectl device process launch` put it on the iPhone 12, over the network connection.
    The iPhone holds the `.dev` build alone now; xtool's was already gone. The debug bridge answers `interop.py`
    from the Linux machine over USB as before, since it never named a bundle id; only `ifuse` does.
  - **Bluetooth for `knit-peer`:** allowed at the Mac on 2026-09-28 for the signature `scripts/mac-peer.sh`
    makes, identifier `app.getknit.knit-peer` under the same team (ADR 2026-09.vcdk). A new signing
    certificate asks again. From ssh, CoreBluetooth reports it unauthorized whatever the grant.
  - **The phone's log:** `idevicesyslog` finds the iPhone only over USB, not while it is connected over the
    network. Console.app at the Mac reads it either way. The bridge itself also answers over Wi-Fi, on a
    network pinned over USB (ADR 2026-10.dz8d).
- **What does not pass yet:**
  - **`check.sh analyze`** runs in 26 minutes, and SourceKit gets through `KnitAppCore` without crashing.
    It fails on seven findings that only macOS sees. swift-crypto's `Crypto` re-exports CryptoKit on Apple
    platforms, so four `import Crypto` lines in `KnitCrypto` read as unused. `knit-peer`'s macOS stub
    `main()` has no `unused_declaration` exemption, and the Linux branch's exemption reads as superfluous.
    It also analyzes `Knit` from the macOS host build, where the app's iOS code does not compile; that
    needs an iOS compiler log from `xcodebuild`.

## Still owed on the Mac

- Make `check.sh analyze` pass on macOS: a macOS counterpart to `scripts/swiftlint-analyze-linux.yml`, and
  `Knit` and `KnitBLE` analyzed from an iOS build.
