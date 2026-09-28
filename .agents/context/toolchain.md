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
  2026-09.de8f), and "The Mac Mini" below has the setup. xtool, which built the app on Linux until 2026-09-28,
  is retired, and nothing on Linux compiles `Knit` or `KnitBLE` for iOS.
- **Static archives:** the app links each package target as a static archive, and the linker keeps only the
  members something names. A file that only the Objective-C runtime calls into, like KnitBLE's CoreBluetooth
  delegates, is dropped without a warning; the first install on the iPhone stopped at the Bluetooth grant for
  that reason. The `Knit` target links with `-ObjC`, and `scripts/check.sh xcode` checks the app for the
  delegate methods.
- **Free provisioning:** an install lasts 7 days, and the phone trusts the developer once under VPN & Device
  Management. An install waits at Verifying while Knit is open on the phone, until someone swipes it away.

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
  `.build/out` before trusting a finding in code that is gone. Periphery ships macOS binaries only, so on
  Linux it is built from source and installed at user level:

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

## CI runners

- **linux-host, the Linux instance runner,** takes the untagged jobs in the `swift:6.4-noble` image (pinned by
  digest in `.gitlab-ci.yml`). It is the `gitlab-runner` Docker container on the maintainer's machine,
  configured in `~/.gitlab-runner/config.toml`: two jobs at once, each capped at 8 GB and 8 cores, so CI never
  takes the whole desktop. Leave that directory to it.
- **`service`, instance runner 4,** also takes untagged jobs, in Docker. It is slower than linux-host: pipeline
  808's `test:coverage` took 643 s there, against about 250 s on linux-host (2026-09-28). A test that waits on a
  thread needs a deadline with room for that, as `LoopRig.settleMilliseconds` has.
- **The `knit-local` runner** takes the four heavy jobs, `test:tsan`, `test:asan`, `verify:fuzz` and
  `verify:analyze` (ADR 2026-09.fkqb), and `verify:periphery:linux`, since Periphery is built from source
  there. Analyze needs more than linux-host's 8 GB:
  SourceKit keeps every file's compiler instance until the run ends, and linux-host's cap killed it at 8.35 GB.
  Until the runner is registered these jobs wait for it, and no pipeline finishes.
  - **What it is:** project runner 7 on `knit/knit-ios`, tag `knit-local`, locked to the project, not
    taking untagged jobs. It is the apt package's system service with the shell executor, so jobs run as
    `maintainer`, in a login shell whose `~/.profile` puts swiftly and SwiftLint on the `PATH`. Its builds and cache live in `~/.local/share/knit-local-runner`.
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
  jobs: any project's `macos` jobs run there, and nothing else does. `build:ios:xcode`, `build:ios:signed`,
  `test:macos`, `test:ios:simulator` and `verify:periphery` carry the tag.
  - **What it is:** gitlab-runner's shell executor (bash) as `maintainer`, in a LaunchAgent in the desktop
    session, because the Simulator needs one. It takes one job at a time (`limit = 1` in
    `~/.gitlab-runner/config.toml`), and its builds and cache live in `~/.local/share/gitlab-runner`.
  - **Recreating it:** the same two steps as `knit-local`, with `runner_type=instance_type`,
    `tag_list=macos` and `run_untagged=false`. Register it without `sudo`, which makes it a LaunchAgent, then
    `gitlab-runner install --working-directory ~/.local/share/gitlab-runner` and `gitlab-runner start`.
  - **Every project's jobs run as `maintainer`,** whose home holds the glab token. Give it an account of its own
    before a project that someone else can push to uses the tag.
- **`mac-docker-runner`, the Mac's Linux runner,** is instance runner 11 (2026-09-28). It takes any project's
  untagged jobs, beside linux-host and service, and carries the tags `docker` and `arm64` for a job that wants it.
  Its jobs run in containers inside the VM, not as `maintainer`, and without `privileged`. A job from another
  project that needs more than 4 GB and the swap can hold is killed here, so give such a job a tag this
  runner lacks.
  - **What it is:** gitlab-runner's Docker executor in the same process as `mac-runner`, running jobs in
    Colima's VM (`host = unix:///Users/maintainer/.colima/default/docker.sock`). The process takes two jobs at once
    (`concurrent = 2`), one per runner (`limit = 1` each), so an Xcode job never waits behind a Linux one. Jobs
    get `SWIFT_JOBS=4`, one compiler per VM CPU.
  - **Sized to leave the Mac for iOS work:** the VM keeps 4 CPUs and 4 GB, because it holds on to memory it
    has used and the Mac has 16 GB. It has 4 GB of swap for the rare peak, set up by a `provision` script in
    `~/.colima/default/colima.yaml` that runs at every VM start.
  - **Measured in the VM** (2026-09-28, image `swift:6.4-noble` on arm64): `check.sh build` in 61 s at a
    2.2 GB peak, `test` in 5 s, and `coverage` in 100 s at 3.6 GB. Without swap, SwiftPM's own coverage export
    was killed at that peak. The same build took 627 s on `service` and about 90 s on linux-host.
  - **Architectures:** `swift:6.4-noble`, `python:3.13-alpine`, `alpine/git` and `zaventh/lintorama:7` all
    publish arm64 images. The line total can differ from amd64 by a line or so (10827 against 10826 of 11114),
    which the whole-percent floors absorb.
  - **Recreating it:** create it through the API with `runner_type=instance_type`, `tag_list=docker,arm64` and
    `run_untagged=true`, then register it without `sudo`:
    `gitlab-runner register --executor docker --docker-image alpine:3.22 --docker-host
    unix:///Users/maintainer/.colima/default/docker.sock --env SWIFT_JOBS=4 --limit 1`, passing the token on
    standard input rather than the command line. A runner's type cannot change: `gitlab-runner unregister`
    removes only its manager, so delete the old runner through the API too (`DELETE runners/<id>`).

## The Mac Mini

`mac.example`, set up on 2026-09-27: an M6 Mac Mini with 12 cores and 16 GB on macOS 27.0, reached as
`maintainer` over ssh with passwordless `sudo`. It logs in to the desktop by itself, restarts after a power cut,
and never sleeps.

- **Xcode 27.0 (`27A266a`)** is the selected developer
  directory. The iOS 27.0 Simulator runtime came with it, and developer mode is on. Its Swift is 6.4
  (`swiftlang-6.4.0.34.1`), which matches `.swift-version`, so the Mac builds with Xcode's toolchain and has
  no swiftly.
- **Homebrew has the rest:** SwiftLint 0.65.1 and Periphery 3.8.0 (the pinned versions); XcodeGen 2.46.0;
  bash 5 and Python 3.14, because macOS ships bash 3.2 and Python 3.9; xcbeautify, xcodes, libimobiledevice and
  ideviceinstaller; rsync 3, because macOS ships openrsync; glab, gh and gitlab-runner; GnuPG and
  pinentry-mac; Colima, the docker CLI and docker-credential-helper. `~/.zshenv` and `~/.bash_profile` put
  Homebrew on the `PATH` for every shell, login or not.
- **Docker runs in Colima,** a `vz` VM with Rosetta, 4 CPUs, 4 GB and 4 GB of swap, started at login. It runs
  lintorama here and the `mac-docker-runner` runner's jobs. `zaventh/lintorama:7` now publishes an arm64 image,
  so it runs without Rosetta.
- **The checkouts** are `~/source/knit-ios`, with the hooks on, and `~/source/knit-next`. Git reaches GitLab
  through `glab auth git-credential`.
- **`~/source/knit-ios-mirror` belongs to `scripts/mac.sh`,** which drives the Mac from linux-host. Each sync
  overwrites it with linux-host's working tree, so do real work at the Mac in `~/source/knit-ios`. The script
  calls `/opt/homebrew/bin/rsync` by path: openrsync speaks protocol 29 and gets the filter rules wrong.
- **linux-host reaches the Mac through one shared connection.** The `Host mac.example` block in linux-host's
  `~/.ssh/config` keeps a master connection open for 20 minutes (`ControlMaster`, `ControlPersist`), so
  each later command takes about 30 ms. `scripts/mac.sh` passes the same options, so it works without
  the block.
- **Signing:** the maintainer's GPG key is imported, and git signs every commit and tag with it. A LaunchAgent
  (`org.gnupg.gpg-agent`) starts `gpg-agent` in the desktop session at login, so `pinentry-mac` can show its
  dialog and read the passphrase from the Keychain even when the first `gpg` call comes over ssh. The
  passphrase is asked once: tick "Save in Keychain" at the Mac, or unlock over ssh with
  `gpg --pinentry-mode loopback`, which lasts until the agent restarts.
- **The login Keychain is locked to ssh sessions.** `docker login` stores through
  `docker-credential-osxkeychain` (`credsStore` in `~/.docker/config.json`), so run it at the Mac's desktop;
  the CI runner shares that session. glab keeps its token in its config file for the same reason.
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
- **Signing on the Mac:** Xcode is signed in to the free Personal Team `<team id>`, and its first run on the
  iPhone (2026-09-27) made an Apple Development certificate and a profile for `app.getknit.knit.dev`. Set up
  once at the desk: Xcode, Settings, Accounts, the Apple ID; the iPhone plugged in and trusted, then set to
  "Connect via network" in Devices so it can go back to this machine's USB. `App/Local.xcconfig` (git
  ignores it) holds `DEVELOPMENT_TEAM = <team id>`.
  - **Signing runs in the desktop session** (ADR 2026-09.zawh). Over ssh, `codesign` fails with
    `errSecInternalComponent`, even after "Always Allow" on the key and under `sudo launchctl asuser`: the
    login Keychain stays locked to an ssh session. `scripts/mac-desktop.sh` runs a command as a one-shot
    launchd job in `gui/501`, where the Keychain is open, and `check.sh device` builds the signed app through
    it. `-allowProvisioningUpdates` renews the 7-day profile there too: with the cached one moved aside, it
    fetched a new one from Apple (2026-09-28). CI's `build:ios:signed` takes the same path, with the team in
    `KNIT_DEVELOPMENT_TEAM`.
  - **Anyone running as `maintainer` can sign as the team,** a `macos` job from any project included. The job's
    rule keeps forks out; an account of its own for the runner is the real fix.
  - **The `.dev` id keeps `app.getknit.knit` unclaimed.** Apple gives a bundle id to the first team that
    registers it, and the free team registers every id it signs, so it signs only the `.dev` one.
  - **One Knit per phone.** Two installs would both advertise the GATT payload and scan, and a peer would see
    two nodes on one iPhone, as with Android, which has no debug package for that reason.
  - **Free provisioning** limits a team to three installed apps, each for 7 days.
  - **Installing from the Mac (2026-09-28):** `check.sh device` builds the signed app, and `devicectl device
    install app` then `devicectl device process launch` put it on the iPhone 12, over the network connection.
    The iPhone holds the `.dev` build alone now; xtool's was already gone. The debug bridge answers `interop.py`
    from linux-host over USB as before, since it never named a bundle id; only `ifuse` does.
  - **Bluetooth for `knit-peer`:** allowed at the Mac on 2026-09-28 for the signature `scripts/mac-peer.sh`
    makes, identifier `app.getknit.knit-peer` under team `<team id>` (ADR 2026-09.vcdk). A new signing
    certificate asks again. From ssh, CoreBluetooth reports it unauthorized whatever the grant.
  - **The phone's log:** `idevicesyslog` finds the iPhone only over USB, not while it is connected over the
    network. Console.app at the Mac reads it either way.
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
