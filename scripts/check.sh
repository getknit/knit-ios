#!/usr/bin/env bash
# The gates, one subcommand each. CI calls the same subcommands, so a green local run means a green pipeline.
#
#     scripts/check.sh fast        # format, lint, build, unit tests (the pre-push hook)
#     scripts/check.sh all         # every gate that runs on Linux
#     scripts/check.sh <gate> ...  # format lint build test coverage tsan asan analyze periphery adr lintorama ios xcode device
#
# Each build variant (coverage, TSan, ASan, analyze) gets its own --scratch-path, so switching between them never
# rebuilds the plain debug tree. `.agents/context/commands.md` explains when to run which.

set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

# This machine runs a lot besides Knit, so every build here is a considerate neighbour: at most $SWIFT_JOBS
# compilers at a time, at low CPU priority, the way linux-host's CI containers are capped (.agents/rules/build-and-test.md).
# Raise them for one run with SWIFT_JOBS=16 KNIT_NICE=0 when the machine is otherwise idle.
swift_jobs=${SWIFT_JOBS:-8}
jobs=(-j "$swift_jobs")
if [ "${KNIT_NICE:-10}" != 0 ]; then
	renice -n "${KNIT_NICE:-10}" -p $$ >/dev/null 2>&1 || true
fi

swift_sources=(Package.swift Sources Tests Fuzz/Package.swift Fuzz/Sources)
pure_targets=(Sources/KnitWire Sources/KnitCrypto Sources/KnitStore Sources/KnitMesh Sources/KnitAppCore Sources/KnitPeer Sources/KnitBlueZ)

# SwiftLint looks for SourceKit beside the `swift` binary, which under swiftly is a proxy rather than the
# toolchain. Ask the compiler where its resources live instead.
if [ "$(uname -s)" = Linux ] && [ -z "${LINUX_SOURCEKIT_LIB_PATH:-}" ]; then
	resources=$(swift -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')
	LINUX_SOURCEKIT_LIB_PATH=$(readlink -f "$resources/..")
	export LINUX_SOURCEKIT_LIB_PATH
fi

step() { printf '\n== %s\n' "$*"; }

gate_format() {
	step "swift-format lint --strict"
	swift format lint --strict --recursive --parallel "${swift_sources[@]}"
}

gate_lint() {
	step "swiftlint lint --strict"
	swiftlint lint --strict --quiet
}

gate_build() {
	step "swift build (warnings are errors)"
	swift build "${jobs[@]}" --build-tests --only-use-versions-from-resolved-file
}

gate_test() {
	step "swift test"
	# Swift Testing appends -swift-testing to the name: CI reads .build/xunit-swift-testing.xml.
	swift test "${jobs[@]}" --disable-xctest --only-use-versions-from-resolved-file --xunit-output .build/xunit.xml
}

gate_coverage() {
	step "coverage floors"
	swift test "${jobs[@]}" --disable-xctest --only-use-versions-from-resolved-file --enable-code-coverage --scratch-path .build-cov
	python3 scripts/coverage-gate.py --scratch-path .build-cov
}

gate_tsan() {
	step "swift test --sanitize=thread"
	swift test "${jobs[@]}" --disable-xctest --only-use-versions-from-resolved-file --sanitize=thread --scratch-path .build-tsan
}

gate_asan() {
	step "swift test --sanitize=address"
	# The suppressions file hides one Swift Testing leak and says why; keep every other leak fatal.
	LSAN_OPTIONS="suppressions=$PWD/scripts/lsan-suppressions.txt:print_suppressions=0" \
		swift test "${jobs[@]}" --disable-xctest --only-use-versions-from-resolved-file --sanitize=address --scratch-path .build-asan
}

gate_analyze() {
	step "swiftlint analyze (platform-free targets)"
	# The compiler log must come from a fresh build, or SwiftLint sees no invocations to analyze.
	rm -rf .build-analyze
	local log=.build-analyze.log
	swift build "${jobs[@]}" -v --only-use-versions-from-resolved-file --scratch-path .build-analyze >"$log" 2>&1
	# Apple-only targets compile to empty modules here, and SourceKit reports their SwiftUI and CoreBluetooth
	# imports as noise; the Mac runner analyzes the whole tree.
	local output status=0
	# The Linux override keeps `import Foundation`, which SourceKit misattributes here; the file says why.
	local configs=(--config .swiftlint.yml)
	[[ "$(uname -s)" == Linux ]] && configs+=(--config scripts/swiftlint-analyze-linux.yml)
	# SourceKit keeps every file's compiler instance, and the ten Clang modules it holds open, until the run ends.
	# Docker's soft limit of 1024 descriptors runs out a hundred files in, so lift it to the hard limit.
	ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
	output=$(swiftlint analyze "${configs[@]}" --strict --quiet --compiler-log-path "$log" "${pure_targets[@]}" 2>&1) ||
		status=$?
	grep -v -E 'no such module|^[[:space:]]+(import|\^)' <<<"$output" || true
	return "$status"
}

gate_periphery() {
	step "periphery scan"
	if ! command -v periphery >/dev/null 2>&1; then
		echo "periphery is not installed; .agents/context/toolchain.md has the Linux build steps" >&2
		return 1
	fi
	# Swift Build writes the index store to .build/out, which Periphery does not look for by default. The
	# store also holds xtool's iOS build, so Apple-only code is visible when `check.sh ios` ran first.
	swift build "${jobs[@]}" --build-tests --only-use-versions-from-resolved-file
	# Advisory on Linux until the Mac runner exists (PERIPHERY_STRICT=1 there): a declaration that only
	# Apple-only code uses reads as unused when the iOS build has not been indexed.
	periphery scan --quiet --skip-build --index-store-path .build/out --retain-public ${PERIPHERY_STRICT:+--strict}
}

gate_adr() {
	step "ADR router is in sync"
	python3 scripts/adr.py index --check
}

gate_lintorama() {
	step "lintorama (markdown, YAML, shell, editorconfig)"
	docker run --rm -v "$root":/code zaventh/lintorama:7
}

gate_ios() {
	step "xtool dev build (arm64-apple-ios)"
	scripts/xtool-sdk-fixup.sh --check
	# xtool takes no -j, so its compilers share $swift_jobs cores instead of spreading over all of them.
	local cpus=()
	if command -v taskset >/dev/null 2>&1 && [ "$(nproc)" -gt "$swift_jobs" ]; then
		cpus=(taskset -c "0-$((swift_jobs - 1))")
	fi
	"${cpus[@]}" xtool dev build
	check_delegates xtool/Knit.app/Knit
}

# Only the Objective-C runtime calls these, so only Package.swift's -ObjC keeps them in the app. Without the
# restore ones, iOS stops Knit the moment Bluetooth is allowed; without the write one, the doorbell wakes Knit
# and nothing answers it.
check_delegates() {
	local selector
	for selector in centralManager:willRestoreState: peripheralManager:willRestoreState: \
		centralManager:didDiscoverPeripheral:advertisementData:RSSI: peripheralManager:didOpenL2CAPChannel:error: \
		peripheralManager:didReceiveWriteRequests:; do
		if ! grep -q -a -F "$selector" "$1"; then
			echo "$1 lacks the delegate method $selector: is -ObjC still in the Knit target's linkerSettings?" >&2
			return 1
		fi
	done
}

# The Xcode project, on the Mac only (ADR 2026-09.de8f): XcodeGen generates App/Knit.xcodeproj from
# App/project.yml. The project resolves its packages into a Package.resolved of its own, which is never committed,
# so seed it with the root package's pins; each build then forbids resolution and checks they held.
xcode_project() {
	if [ "$(uname -s)" != Darwin ]; then
		echo "this gate needs Xcode; run it on the Mac: scripts/mac.sh run scripts/check.sh $*" >&2
		return 1
	fi
	xcodegen generate --spec App/project.yml --quiet
	mkdir -p "$(dirname "$xcode_resolved")"
	cp Package.resolved "$xcode_resolved"
	xcode_pretty=(cat)
	if command -v xcbeautify >/dev/null 2>&1; then
		xcode_pretty=(xcbeautify --quiet)
	fi
}

xcode_resolved=App/Knit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcode_app=.build-xcode/Build/Products/Debug-iphoneos/Knit.app
xcode_build=(-project App/Knit.xcodeproj -scheme Knit -configuration Debug -derivedDataPath .build-xcode
	-jobs "$swift_jobs" -disableAutomaticPackageResolution)

# What every iPhone build must hold: the committed pins, App/Info.plist's version keys, and KnitBLE's delegates.
check_xcode_app() {
	python3 - "$xcode_resolved" "$xcode_app/Info.plist" <<'PY'
import json, plistlib, sys
def pins(path):
	return {p["identity"]: p["state"] for p in json.load(open(path))["pins"]}
if pins(sys.argv[1]) != pins("Package.resolved"):
	sys.exit(f"{sys.argv[1]} drifted from Package.resolved: the app built other package versions")
built, ours = (plistlib.load(open(path, "rb")) for path in (sys.argv[2], "App/Info.plist"))
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
	if built.get(key) != ours[key]:
		sys.exit(f"the Xcode build's {key} is {built.get(key)!r}, App/Info.plist's is {ours[key]!r}: "
			"update MARKETING_VERSION or CURRENT_PROJECT_VERSION in App/project.yml")
PY
	# A Debug build keeps the app's code in Knit.debug.dylib, and Knit is a launcher for it.
	if [ -f "$xcode_app/Knit.debug.dylib" ]; then
		check_delegates "$xcode_app/Knit.debug.dylib"
	else
		check_delegates "$xcode_app/Knit"
	fi
}

# The unsigned build any Mac can run: the iPhone and the Simulator, into .build-xcode.
gate_xcode() {
	step "xcodebuild App/Knit.xcodeproj (iOS and Simulator, unsigned)"
	xcode_project xcode
	local destination
	for destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator'; do
		xcodebuild "${xcode_build[@]}" -destination "$destination" CODE_SIGNING_ALLOWED=NO build | "${xcode_pretty[@]}"
	done
	check_xcode_app
}

# The signed iPhone build (ADR 2026-09.zawh). Signing needs the login Keychain, which only the desktop session has
# unlocked, so xcodebuild runs there through scripts/mac-desktop.sh, from ssh and CI alike. -allowProvisioningUpdates
# lets it renew the free team's 7-day profile. The team comes from App/Local.xcconfig or $KNIT_DEVELOPMENT_TEAM.
gate_device() {
	step "xcodebuild App/Knit.xcodeproj (iPhone, signed in the desktop session)"
	xcode_project device
	local team=()
	if [ -n "${KNIT_DEVELOPMENT_TEAM:-}" ]; then
		team=("DEVELOPMENT_TEAM=$KNIT_DEVELOPMENT_TEAM")
	elif ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' App/Local.xcconfig; then
		echo "no signing team: set KNIT_DEVELOPMENT_TEAM, or DEVELOPMENT_TEAM in App/Local.xcconfig" >&2
		return 1
	fi
	# An incremental build that fetches a new profile copies it into the app without signing again, which leaves a
	# broken seal (2026-09-28). The objects stay cached, so linking, copying and signing a fresh bundle is cheap.
	rm -rf "$xcode_app"
	scripts/mac-desktop.sh xcodebuild "${xcode_build[@]}" -destination 'generic/platform=iOS' \
		-allowProvisioningUpdates "${team[@]}" build | "${xcode_pretty[@]}"
	check_xcode_app
	codesign --verify --strict --deep "$xcode_app"
	# The profile's end date, so a renewal that stopped working shows here days before installs fail.
	security cms -D -i "$xcode_app/embedded.mobileprovision" >"$xcode_app.profile.plist"
	python3 - "$xcode_app.profile.plist" <<'PY'
import datetime, plistlib, sys
profile = plistlib.load(open(sys.argv[1], "rb"))
left = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) - datetime.datetime.now(datetime.timezone.utc)
print(f"signed for team {profile['TeamIdentifier'][0]}; profile {profile['Name']!r} "
	f"covers {len(profile.get('ProvisionedDevices', []))} devices and expires in {left.days} days {left.seconds // 3600} hours")
PY
	rm -f "$xcode_app.profile.plist"
}

run() {
	for gate in "$@"; do
		"gate_$gate"
	done
}

case "${1:-fast}" in
fast) run format lint build test ;;
all) run format lint adr build test coverage tsan asan analyze lintorama ;;
format | lint | build | test | coverage | tsan | asan | analyze | periphery | adr | lintorama | ios | xcode | device) run "$@" ;;
*)
	echo "usage: $0 [fast|all|format|lint|build|test|coverage|tsan|asan|analyze|periphery|adr|lintorama|ios|xcode|device]" >&2
	exit 2
	;;
esac
