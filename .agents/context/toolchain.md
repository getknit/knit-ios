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

## xtool and the Darwin SDK

- **Versions:** xtool 1.20.1, with a Darwin SDK built from Xcode 27.0 (`27A266a`), which provides iPhoneOS,
  iPhoneSimulator and MacOSX 27.0.
- **Build:** `xtool dev build` cross-compiles `arm64-apple-ios` into `xtool/Knit.app`. xtool builds only the
  `Knit` product's closure, so the Linux-only targets never compile for iOS.
- **Bundle id:** xtool installs dev builds under an `XTL-<team>.` prefix, so a Keychain identity made by an
  xtool install does not carry over to an Xcode-signed build (use `app.getknit.knit.dev` there).
- **Static archives:** xtool links each target as a static archive (the `.o` files under
  `.build/out/Products/Debug-iphoneos/` are `ar` archives), and the linker keeps only the members something
  names. A file that only the Objective-C runtime calls into, like KnitBLE's CoreBluetooth delegates, is
  dropped without a warning; the first install on the iPhone stopped at the Bluetooth grant for that reason.
  The `Knit` target links with `-ObjC`, and `scripts/check.sh ios` checks the app for the delegate methods.
- **Installing on the iPhone:** `xtool dev run --usb` builds, signs and installs over USB, and
  `idevicesyslog -p Knit` reads the app's log (a debug build logs at notice, the least it relays). The team is on
  free provisioning: an install lasts 7 days, and the phone trusts the developer once under VPN & Device
  Management. `xtool launch` fails on iOS 27, so Knit is opened by hand. An install waits at Verifying while
  Knit is open on the phone, until someone swipes it away.
- **xtool drops a serial's leading zeros** (`Certificate.serialNumber()`) and then finds no match on Apple's
  side, so it asks to revoke a certificate whose serial starts with `0` and make another, on every install. The
  prompt needs a terminal. One in sixteen certificates does this; the one made on 2026-09-26 does not.

**The SDK bundle needs one fix.** xtool 1.20.1's bundle ships clang builtin headers older than Swift 6.4's
clang 21. Their `float.h` still does `#include_next <float.h>` on Apple platforms, which lands on the Xcode
27 SDK's own `float.h`. The SDK fences that header off in `_c_standard_library_obsolete`, and every C module
scan then fails with `requires feature 'found_incompatible_headers__check_search_paths'`.

- `scripts/xtool-sdk-fixup.sh` points the bundle at the compiling toolchain's own headers, keeping the
  bundle's compiler-rt libraries.
- `xtool sdk install` rebuilds the bundle and drops the fix, so rerun the script afterwards.
- `--check` tells whether it is in place, and `scripts/check.sh ios` runs that check first.
- ADR router: `.agents/memory/decisions.md`.

**The SDK never leaves this machine.** Apple's terms tie the Xcode SDKs to Apple hardware, and xtool on
Linux is a stopgap. The SDK stays out of images, caches and artifacts; only the built `Knit.app` is
uploaded. The Mac Mini takes over iOS builds once `build:ios` moves to its runner.

## Linters and analyzers

- **SwiftLint 0.65.1** (`/usr/local/bin/swiftlint` here; CI installs the pinned `swiftlint_linux_amd64.zip`
  and checks its SHA-256). On Linux it needs SourceKit from the toolchain:
  `LINUX_SOURCEKIT_LIB_PATH=~/.local/share/swiftly/toolchains/6.4.0/usr/lib`. The scripts and hooks derive
  it themselves.
- **swift-format** comes with the toolchain (`swift format`), configured in `.swift-format`.
- **Periphery 3.8.0** ships macOS binaries only, so on Linux it is built from source and installed at user
  level. It finds the Swift Build index store only when told to (`--index-store-path .build/out`), which
  `scripts/check.sh periphery` does:

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
  system SQLite (3.45.1: a WAL pool, migrations, BINARY ordering), and cross-builds for `arm64-apple-ios`
  against the SDK's SQLite. `KnitStoreSQL` and its tests build on Linux like the other platform-free
  targets. A plain `swift build --swift-sdk arm64-apple-ios` fails under Swift Build ("unable to find
  platform for 'iphoneos'"), so a manual iOS build of a package needs `--build-system native`; the app
  itself goes through `xtool dev build`.
- **GRDB in the package (P5):** pinned at 7.11.1 in both `Package.resolved` files. The `STRICT` tables need
  SQLite 3.37 or later: iOS 18 and noble both have it, and an older SQLite fails the first migration rather
  than opening a looser schema. CI's Swift image installs `libsqlite3-dev` in `.swift`'s `before_script`.
- **Not needed:** `libbluetooth-dev`. `CBluetoothShim` writes out the few socket definitions itself.

## CI runners

- **linux-host, the Linux instance runner,** takes the untagged jobs in the `swift:6.4-noble` image (pinned by digest in
  `.gitlab-ci.yml`). It is the `gitlab-runner` Docker container on the maintainer's machine, configured in
  `~/.gitlab-runner/config.toml`: two jobs at once, each capped at 8 GB and 8 cores, so CI never takes the
  whole desktop. Leave that directory to it.
- **The `knit-local` runner** takes the five jobs that need the machine itself: `build:ios` and
  `verify:periphery` (the Darwin SDK, xtool and Periphery live only here, ADR 2026-09.d3jv), and the heavy
  `test:tsan`, `test:asan` and `verify:fuzz`. Until it is registered they wait for a runner, and no
  pipeline finishes.
  - **What it is:** project runner 7 on `knit/knit-ios`, tag `knit-local`, locked to the project, not
    taking untagged jobs. It is the apt package's system service with the shell executor, so jobs run as
    `maintainer`, who owns `~/.swiftpm/swift-sdks`, in a login shell whose `~/.profile` puts swiftly, xtool,
    Periphery and SwiftLint on the `PATH`. Its builds and cache live in `~/.local/share/knit-local-runner`.
  - **One job at a time** (`concurrent = 1` in `/etc/gitlab-runner/config.toml`), reniced by the `.local`
    template: a shell job cannot be capped the way linux-host's containers are.
  - **Creating it:** tags live on the server, because a `glrt-` token refuses `--tag-list`, so the runner
    is created through the API first:

    ```sh
    glab api --hostname source.jeffmixon.com --method POST user/runners -f runner_type=project_type \
      -F project_id=<id> -f description=knit-local -f tag_list=knit-local -F run_untagged=false -F locked=true
    ```

  - **Registering it** with the returned token, as root, because the service reads `/etc/gitlab-runner`:

    ```sh
    sudo gitlab-runner uninstall
    sudo gitlab-runner install --user maintainer --working-directory /home/maintainer/.local/share/knit-local-runner
    sudo gitlab-runner register --non-interactive --url https://source.jeffmixon.com --token "$TOKEN" \
      --executor shell --description knit-local \
      --builds-dir /home/maintainer/.local/share/knit-local-runner/builds \
      --cache-dir /home/maintainer/.local/share/knit-local-runner/cache
    sudo sed -i 's/^concurrent = .*/concurrent = 1/' /etc/gitlab-runner/config.toml
    sudo systemctl daemon-reload && sudo systemctl restart gitlab-runner
    ```

    `gitlab-runner install` rewrites the unit but leaves the old process running, which is why the restart
    is there.
  - **A shell runner runs pipeline code as `maintainer`,** with full access to that home directory. Keep it a
    project runner, and move it to an account of its own before anyone else can push to knit-ios.
- **`mac-runner`, the Mac's runner,** is instance runner 9 with the tag `macos`, and it takes no untagged
  jobs: any project's `macos` jobs run there, and nothing else does. No knit-ios job carries the tag yet.
  - **What it is:** gitlab-runner's shell executor (bash) as `maintainer`, in a LaunchAgent in the desktop
    session, because the Simulator needs one. It takes one job at a time (`concurrent = 1` in
    `~/.gitlab-runner/config.toml`), and its builds and cache live in `~/.local/share/gitlab-runner`.
  - **Recreating it:** the same two steps as `knit-local`, with `runner_type=instance_type`,
    `tag_list=macos` and `run_untagged=false`. Register it without `sudo`, which makes it a LaunchAgent, then
    `gitlab-runner install --working-directory ~/.local/share/gitlab-runner` and `gitlab-runner start`.
  - **Every project's jobs run as `maintainer`,** whose home holds the glab token. Give it an account of its own
    before a project that someone else can push to uses the tag.

## The Mac Mini

`mac.example`, set up on 2026-09-27: an M6 Mac Mini with 12 cores and 16 GB on macOS 27.0, reached as
`maintainer` over ssh with passwordless `sudo`. It logs in to the desktop by itself, restarts after a power cut,
and never sleeps.

- **Xcode 27.0 (`27A266a`)**, the build the Linux Darwin SDK came from, is the selected developer
  directory. The iOS 27.0 Simulator runtime came with it, and developer mode is on. Its Swift is 6.4
  (`swiftlang-6.4.0.34.1`), which matches `.swift-version`, so the Mac builds with Xcode's toolchain and has
  no swiftly.
- **Homebrew has the rest:** SwiftLint 0.65.1 and Periphery 3.8.0 (the pinned versions); bash 5 and
  Python 3.14, because macOS ships bash 3.2 and Python 3.9; xcbeautify, xcodes, libimobiledevice and
  ideviceinstaller; glab, gh and gitlab-runner; Colima and the docker CLI. `~/.zshenv` and `~/.bash_profile`
  put Homebrew on the `PATH` for every shell, login or not.
- **Docker runs in Colima,** a `vz` VM with Rosetta, 4 CPUs and 4 GB, started at login. `zaventh/lintorama:7`
  is amd64 only, so it runs under Rosetta until the image ships an arm64 build.
- **The checkouts** are `~/source/knit-ios`, with the hooks on, and `~/source/knit-next`. Git reaches GitLab
  through `glab auth git-credential`. Commits made there are unsigned, because the GPG key stays on the Linux
  desktop.
- **What passes there** (2026-09-27, at `b03c841`): `check.sh fast`, in three minutes. `xcodebuild build
  -scheme Knit` builds every target of the package for `generic/platform=iOS` and for the Simulator,
  unsigned, with no Xcode project.
- **What does not pass yet:**
  - **`check.sh analyze`** runs in 26 minutes, and SourceKit gets through `KnitAppCore` without crashing.
    It fails on seven findings that only macOS sees. swift-crypto's `Crypto` re-exports CryptoKit on Apple
    platforms, so four `import Crypto` lines in `KnitCrypto` read as unused. `knit-peer`'s macOS stub
    `main()` has no `unused_declaration` exemption, and the Linux branch's exemption reads as superfluous.
    It also analyzes `Knit` from the macOS host build, where the app's iOS code does not compile; that
    needs an iOS compiler log from `xcodebuild`.
  - **`check.sh periphery`** is advisory and exits 0 with 21 findings, 18 of them in `KnitBlueZ`, whose
    callers compile only on Linux. Linux reports 8. The two share three: `ChatListModel`'s `linked` and
    `revision`, and `StoredText`'s `column`.

## Still owed on the Mac

- Move `build:ios` to the `macos` runner, and make `verify:periphery` blocking there
  (`PERIPHERY_STRICT=1`), with `KnitBlueZ` left to Linux. ADR 2026-09.d3jv changes with it.
- Make `check.sh analyze` pass on macOS: a macOS counterpart to `scripts/swiftlint-analyze-linux.yml`, and
  `Knit` and `KnitBLE` analyzed from an iOS build.
- Add a macOS test job: `swift test`, the KnitBLE delegate tests, and Simulator XCUITest with
  `performAccessibilityAudit`.
- Pick the Xcode project generator by ADR. No `.pbxproj` is committed.
- Sign Xcode in to the Apple ID, and pair the iPhone with the Mac. Both need someone at the Mac.
