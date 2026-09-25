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
uploaded. The Mac Mini takes over iOS builds when it arrives.

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

- **lintorama:** `zaventh/lintorama:7` runs yamllint, the GitLab CI schema, actionlint, shellcheck, mdl and
  editorconfig-checker over every tracked file, through its `lint-extras` entrypoint.

## System packages

- **Needed:** `libdbus-1-dev` and `pkg-config` (the `CDBus` target), `docker` (lintorama), and
  `usbmuxd`/libimobiledevice for installing on a phone later.
- **Not installed yet:** `libsqlite3-dev`, which GRDB needs on Linux (`sudo apt install libsqlite3-dev`).
- **Not needed:** `libbluetooth-dev`. `CBluetoothShim` writes out the few socket definitions itself.

## CI runners

- **Shared Linux runners** take the light jobs in the `swift:6.4-noble` image (pinned by digest in
  `.gitlab-ci.yml`).
- **The `knit-local` runner** on the maintainer's machine takes the heavy and SDK-bound jobs:
  - sanitizers, fuzzing and `build:ios`;
  - it runs as the user who owns `~/.swiftpm/swift-sdks`, with the shell executor, so it sees swiftly,
    xtool and the SDK.
  - Register it once with `gitlab-runner register --executor shell --tag-list knit-local`.

## When the Mac arrives

- Install Xcode 27 and register a `macos` runner. Move `build:ios` to it, and make `verify:periphery`
  blocking there (`PERIPHERY_STRICT=1`).
- Add a macOS test job: `swift test`, the KnitBLE delegate tests, and Simulator XCUITest with
  `performAccessibilityAudit`.
- Pick the Xcode project generator by ADR. No `.pbxproj` is committed.
