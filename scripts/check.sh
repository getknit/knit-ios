#!/usr/bin/env bash
# The gates, one subcommand each. CI calls the same subcommands, so a green local run means a green pipeline.
#
#     scripts/check.sh fast        # format, lint, build, unit tests (the pre-push hook)
#     scripts/check.sh all         # every gate that runs on Linux
#     scripts/check.sh <gate> ...  # format lint build test coverage tsan asan analyze periphery adr lintorama xcode uitest device devicetest
#                                  # release archive upload shots
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
pure_targets=(Sources/KnitSync Sources/KnitWire Sources/KnitCrypto Sources/KnitStore Sources/KnitMesh Sources/KnitAppCore Sources/KnitPeer Sources/KnitBlueZ)

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
	mkdir -p .build
	swift build "${jobs[@]}" --build-tests --only-use-versions-from-resolved-file 2>&1 | tee .build/build.log
	no_warnings .build/build.log
}

# Fails when the build that logged $1 warned in this repository's own code. -warnings-as-errors cannot promote a warning
# about a call into an API marked @preconcurrency: PhotosPicker's @Sendable label warned in every Xcode build and built
# anyway, until 2026-10-03 (ADR 2026-09.jgs6). Warnings from the packages we depend on, checked out under a .build
# directory, are theirs to fix.
no_warnings() {
	local found
	found=$(grep -E '^/[^ ]+:[0-9]+:[0-9]+: warning:' "$1" | grep -v -E '/\.build[^/]*/' | sort -u) || true
	if [ -n "$found" ]; then
		printf '%s\n' "$found" >&2
		echo "the build warned in this repository's code: fix the cause" >&2
		return 1
	fi
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
	# Swift Build writes the index store to .build/out, which Periphery does not look for by default.
	swift build "${jobs[@]}" --build-tests --only-use-versions-from-resolved-file
	local stores=(--index-store-path .build/out) excludes=()
	if [ "$(uname -s)" = Darwin ]; then
		# The host build compiles the app to an empty module, so the Mac also reads the index of the iPhone build
		# `check.sh xcode` leaves (CI runs that gate first). KnitBlueZ is Linux's to judge: its callers compile only
		# there, and on a Mac its D-Bus names all read as unused.
		if [ ! -d "$xcode_index" ]; then
			echo "no iPhone index at $xcode_index: run scripts/check.sh xcode periphery" >&2
			return 1
		fi
		stores+=(--index-store-path "$xcode_index")
		excludes=(--report-exclude 'Sources/KnitBlueZ/**' --report-exclude 'Tests/KnitBlueZTests/**')
	fi
	# A property of an Equatable type is read by its synthesized ==, which Periphery does not see.
	periphery scan --quiet --strict --retain-public --retain-equatable-properties "${stores[@]}" "${excludes[@]}"
}

gate_adr() {
	step "ADR router is in sync"
	python3 scripts/adr.py index --check
}

gate_lintorama() {
	step "lintorama (markdown, YAML, shell, editorconfig)"
	# A worktree's .git is a file naming the main checkout's Git dir, so mount that at its host path too. Only when
	# git names one: docker would otherwise create an empty, root-owned directory there.
	local gitdir mounts=()
	if gitdir=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
		mounts=(-v "$gitdir":"$gitdir")
	fi
	docker run --rm -v "$root":/code "${mounts[@]}" zaventh/lintorama:7
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
xcode_release_app=.build-xcode/Build/Products/Release-iphoneos/Knit.app
# The App Store build (ADR 2026-10.8cy5): the archive, and what exporting it leaves here.
xcode_archive=.build-xcode/Knit.xcarchive
xcode_export=.build-xcode/export
# Xcode indexes while it builds; Periphery reads this store for the app's own code.
xcode_index=.build-xcode/Index.noindex/DataStore
# Each gate names its scheme: Knit for the app and the Simulator's UI tests, KnitDevice for the iPhone's device tests,
# KnitShots for the store's screenshots.
xcode_common=(-project App/Knit.xcodeproj -derivedDataPath .build-xcode -jobs "$swift_jobs" -disableAutomaticPackageResolution)
xcode_build=("${xcode_common[@]}" -configuration Debug)
xcode_release=("${xcode_common[@]}" -configuration Release)

# What every iPhone build must hold: the committed pins, App/Info.plist's version keys, KnitBLE's delegates and the photo
# model. The app is $1, or else the Debug build's.
check_xcode_app() {
	local app=${1:-$xcode_app}
	python3 - "$xcode_resolved" "$app/Info.plist" <<'PY'
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
	if [ -f "$app/Knit.debug.dylib" ]; then
		check_delegates "$app/Knit.debug.dylib"
	else
		check_delegates "$app/Knit"
	fi
	# The content filter's photo model, compiled (ADR 2026-10.rpmq). Without it every photo goes through and nothing says
	# so; its float16 weights come to about 8.6 MB.
	local weights="$app/NSFW.mlmodelc/weights/weight.bin"
	if [ ! -f "$weights" ] || [ $(($(wc -c <"$weights"))) -lt 8000000 ]; then
		echo "$app has no whole NSFW.mlmodelc: the content filter would let every photo through" >&2
		return 1
	fi
	# Its text model, tokenizer and word list (ADR 2026-10.e4kz). The float16 weights come to about 23 MB, and the tokenizer
	# and the list are Android's files, byte for byte.
	weights="$app/Toxicity.mlmodelc/weights/weight.bin"
	if [ ! -f "$weights" ] || [ $(($(wc -c <"$weights"))) -lt 20000000 ]; then
		echo "$app has no whole Toxicity.mlmodelc: the content filter would let every message through" >&2
		return 1
	fi
	local file
	for file in ToxicityTokenizer.json Profanity.txt; do
		if ! cmp -s "$app/$file" "App/Models/$file"; then
			echo "$app/$file is missing or is not App/Models/$file: the content filter would screen messages without it" >&2
			return 1
		fi
	done
}

# What a store build must hold beyond that (ADR 2026-10.8cy5): no debug-only code, a privacy manifest in the app and in
# every resource bundle, the export-compliance answer, and the iPhone alone. The app is $1.
check_release_app() {
	local app=$1 marker
	check_xcode_app "$app"
	# Strings only debug code holds, each long enough to be stored whole rather than inline: the bridge's queue label
	# (Sources/Knit/Debug/) and the demo's launch line (AppEnvironment.demo). Either one here means a debug path ships.
	for marker in app.getknit.knit.bridge "running the demo on seeded stores in memory"; do
		if grep -q -a -F "$marker" "$app/Knit"; then
			echo "$app/Knit holds debug-only code: it contains \"$marker\"" >&2
			return 1
		fi
	done
	python3 - "$app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.load(open(app / "Info.plist", "rb"))
if info.get("ITSAppUsesNonExemptEncryption") is not True:
	sys.exit(f"{app}/Info.plist lacks ITSAppUsesNonExemptEncryption = YES: Knit seals messages with its own encryption")
if info.get("UIDeviceFamily") != [1]:
	sys.exit(f"{app} is built for device families {info.get('UIDeviceFamily')}, not the iPhone alone (ADR 2026-10.kedu)")
# GRDB and swift-crypto each bring a manifest in a resource bundle; App/PrivacyInfo.xcprivacy is the app's own.
for place in [app, *sorted(app.glob("*.bundle"))]:
	path = place / "PrivacyInfo.xcprivacy"
	if not path.is_file():
		sys.exit(f"{place} has no PrivacyInfo.xcprivacy")
	manifest = plistlib.load(open(path, "rb"))
	if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains"):
		sys.exit(f"{path} declares tracking")
print(f"{app.name}: no debug code; privacy manifests in the app and {len(list(app.glob('*.bundle')))} bundles")
PY
}

# The unsigned build any Mac can run: the iPhone and the Simulator, into .build-xcode.
gate_xcode() {
	step "xcodebuild App/Knit.xcodeproj (iOS and Simulator, unsigned)"
	xcode_project xcode
	local destination log=.build-xcode/xcode.log
	mkdir -p .build-xcode
	: >"$log"
	for destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator'; do
		xcodebuild "${xcode_build[@]}" -scheme Knit -destination "$destination" CODE_SIGNING_ALLOWED=NO build |
			tee -a "$log" | "${xcode_pretty[@]}"
	done
	check_xcode_app
	# The device tests compile here too, unsigned, so a change that breaks them fails in CI rather than at the phone.
	xcodebuild "${xcode_build[@]}" -scheme KnitDevice -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
		build-for-testing | tee -a "$log" | "${xcode_pretty[@]}"
	# So does the store's screenshot walk, which only `check.sh shots` runs (ADR 2026-10.5u39).
	xcodebuild "${xcode_build[@]}" -scheme KnitShots -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
		build-for-testing | tee -a "$log" | "${xcode_pretty[@]}"
	no_warnings "$log"
}

# The Release build for the iPhone, unsigned, held to what a store build must hold (ADR 2026-10.8cy5). It needs no
# Keychain, so it runs over ssh, and CI runs it on every pipeline: a debug path that stops compiling out shows here
# rather than at upload.
gate_release() {
	step "xcodebuild App/Knit.xcodeproj (iPhone, Release, unsigned)"
	xcode_project release
	local log=.build-xcode/release.log
	mkdir -p .build-xcode
	xcodebuild "${xcode_release[@]}" -scheme Knit -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build |
		tee "$log" | "${xcode_pretty[@]}"
	no_warnings "$log"
	check_release_app "$xcode_release_app"
}

# The UI tests and the accessibility audit, in the Simulator (MVP item 12): every MVP screen on -seedDemo's stores,
# each through performAccessibilityAudit. The Simulator build signs to run locally, which needs no Keychain, so this
# runs over ssh too. The result bundle keeps each failing audit's screenshot.
#
# CI and a run over ssh each get a Simulator of their own, "Knit CI" and "Knit local", or the one KNIT_SIMULATOR
# names. When they shared one, a local run started during CI's lost its test runner at once, and two of CI's tests
# failed (2026-09-28).
gate_uitest() {
	step "xcodebuild test (UI tests and the accessibility audit, in the Simulator)"
	xcode_project uitest
	local simulator=${KNIT_SIMULATOR:-}
	if [ -z "$simulator" ]; then
		simulator="Knit local"
		[ -n "${CI:-}" ] && simulator="Knit CI"
		simulator_named "$simulator"
	fi
	# KNIT_UI_TESTS narrows the run to one walk while iterating, as KNIT_DEVICE_TESTS does on the iPhone.
	local only=()
	if [ -n "${KNIT_UI_TESTS:-}" ]; then
		only=("-only-testing:$KNIT_UI_TESTS")
	fi
	local results=.build-xcode/uitest.xcresult
	rm -rf "$results"
	xcodebuild "${xcode_build[@]}" -scheme Knit -destination "platform=iOS Simulator,name=$simulator" "${only[@]}" \
		-resultBundlePath "$results" -collect-test-diagnostics never test | "${xcode_pretty[@]}"
}

# Makes a Simulator named $1 unless one exists, on the newest iOS runtime: the model $2, or an iPhone 18 Pro, the model
# the audit was set on (ADR 2026-09.jcdx).
simulator_named() {
	if ! xcrun simctl list devices available | grep -qF -- "    $1 ("; then
		xcrun simctl create "$1" "${2:-iPhone 18 Pro}" >/dev/null
	fi
}

# The store's screenshots (ADR 2026-10.5u39): KnitShots walks the screens the listing shows on the marketing scene, in
# light and dark, and each lands in .build-xcode/shots/ as <light|dark>_<shot>.png. It runs in a Simulator of its own,
# "Knit shots", an iPhone 18 Pro Max, whose 6.9-inch screen is the size App Store Connect asks for, so no shot is scaled.
# The status bar is frozen first: 9:41, a full battery, and no cellular or Wi-Fi bars, since Knit needs neither. The
# walk is built once and run once per appearance. KNIT_SHOTS narrows the run to some of KnitShots' tests by name
# (testChatList testNearby), and KNIT_SHOT_MODES to one appearance (light or dark). Nothing here checks the app, so no
# CI job runs it.
gate_shots() {
	step "xcodebuild test (KnitShots, the store's screenshots, in the Simulator)"
	xcode_project shots
	local simulator=${KNIT_SIMULATOR:-Knit shots}
	simulator_named "$simulator" "iPhone 18 Pro Max"
	# Booted afresh, and the appearance set here with `simctl ui`, which a running Simulator draws at once. In this
	# Simulator, XCUIDevice.appearance set from the test changed what it reported and nothing it drew: every dark shot came
	# out byte for byte the light one (iOS 27.0, 2026-10-07), though KnitUITests' dark walk draws dark in "Knit local".
	xcrun simctl shutdown "$simulator" 2>/dev/null || true
	xcrun simctl boot "$simulator"
	xcrun simctl bootstatus "$simulator" -b >/dev/null
	xcrun simctl status_bar "$simulator" override --time 9:41 --batteryState discharging --batteryLevel 100 \
		--cellularMode notSupported --wifiBars 0 --dataNetwork hide
	local only=() test
	for test in ${KNIT_SHOTS:-}; do
		only+=("-only-testing:KnitShots/KnitShots/$test")
	done
	local destination="platform=iOS Simulator,name=$simulator" out=.build-xcode/shots status=0 mode results
	rm -rf "$out" .build-xcode/shots-*.xcresult
	xcodebuild "${xcode_build[@]}" -scheme KnitShots -destination "$destination" build-for-testing | "${xcode_pretty[@]}"
	for mode in ${KNIT_SHOT_MODES:-light dark}; do
		xcrun simctl ui "$simulator" appearance "$mode"
		results=.build-xcode/shots-$mode.xcresult
		# xcodebuild hands a TEST_RUNNER_ variable to the test runner without its prefix. A shot whose screen never
		# appeared fails its test, and the rest are still worth keeping, so the run goes on to export them.
		TEST_RUNNER_KNIT_SHOT_MODE=$mode xcodebuild "${xcode_build[@]}" -scheme KnitShots -destination "$destination" \
			"${only[@]}" -resultBundlePath "$results" -collect-test-diagnostics never test-without-building |
			"${xcode_pretty[@]}" || status=$?
		xcrun xcresulttool export attachments --path "$results" --output-path "$out/$mode" >/dev/null
	done
	xcrun simctl ui "$simulator" appearance light
	# The export names each file by a UUID; manifest.json maps it back to the attachment's name, which XCTest suffixes.
	# A heredoc at the margin, so Python's indentation can be tabs, as .editorconfig asks of shell files.
	python3 - "$out" <<'PY'
import json, pathlib, re, shutil, sys
out = pathlib.Path(sys.argv[1])
for manifest in out.glob("*/manifest.json"):
	for test in json.loads(manifest.read_text()):
		for attachment in test["attachments"]:
			name = re.match(r"(?:light|dark)_[a-z-]+", attachment["suggestedHumanReadableName"])
			if name:
				shutil.copy(manifest.parent / attachment["exportedFileName"], out / f"{name[0]}.png")
PY
	local count
	count=$(find "$out" -maxdepth 1 -name "*.png" | wc -l | tr -d " ")
	echo "$count screenshots in $out/"
	return "$status"
}

# The signed iPhone build (ADR 2026-09.zawh). Signing needs the login Keychain, which only the desktop session has
# unlocked, so xcodebuild runs there through scripts/mac-desktop.sh, from ssh and CI alike. -allowProvisioningUpdates
# lets it renew the team's profile. The team comes from App/Local.xcconfig or $KNIT_DEVELOPMENT_TEAM, and the App
# Store Connect API key that renews it without Xcode's account from signing_key.
gate_device() {
	step "xcodebuild App/Knit.xcodeproj (iPhone, signed in the desktop session)"
	xcode_project device
	local team key
	signing_team
	signing_key
	# An incremental build that fetches a new profile copies it into the app without signing again, which leaves a
	# broken seal (2026-09-28). The objects stay cached, so linking, copying and signing a fresh bundle is cheap.
	rm -rf "$xcode_app"
	scripts/mac-desktop.sh xcodebuild "${xcode_build[@]}" -scheme Knit -destination 'generic/platform=iOS' \
		-allowProvisioningUpdates "${team[@]}" "${key[@]}" build | "${xcode_pretty[@]}"
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

# The signing team, into the caller's `team`: the build setting for $KNIT_DEVELOPMENT_TEAM, or nothing when
# App/Local.xcconfig names one, which the project reads itself.
signing_team() {
	team=()
	if [ -n "${KNIT_DEVELOPMENT_TEAM:-}" ]; then
		team=("DEVELOPMENT_TEAM=$KNIT_DEVELOPMENT_TEAM")
	elif ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' App/Local.xcconfig; then
		echo "no signing team: set KNIT_DEVELOPMENT_TEAM, or DEVELOPMENT_TEAM in App/Local.xcconfig" >&2
		return 1
	fi
}

# The App Store Connect API key, into the caller's `key`: xcodebuild's flags for $KNIT_ASC_KEY_ID and
# $KNIT_ASC_ISSUER_ID, or for the same names in App/Local.xcconfig. With them, -allowProvisioningUpdates makes and
# renews profiles without an Xcode account, which the command line lost on 2026-09-28 (ADR 2026-09.zawh). The .p8 is
# $KNIT_ASC_KEY_PATH, or else ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8. With neither name set, the flags
# stay empty and xcodebuild falls back to Xcode's account.
signing_key() {
	key=()
	local id=${KNIT_ASC_KEY_ID:-} issuer=${KNIT_ASC_ISSUER_ID:-} path
	[ -n "$id" ] || id=$(local_setting KNIT_ASC_KEY_ID)
	[ -n "$issuer" ] || issuer=$(local_setting KNIT_ASC_ISSUER_ID)
	if [ -z "$id$issuer" ]; then
		echo "no App Store Connect API key: only Xcode's account can make or renew a profile" >&2
		return 0
	fi
	if [ -z "$id" ] || [ -z "$issuer" ]; then
		echo "an App Store Connect API key needs KNIT_ASC_KEY_ID and KNIT_ASC_ISSUER_ID both" >&2
		return 1
	fi
	path=${KNIT_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$id.p8}
	if [ ! -r "$path" ]; then
		echo "no App Store Connect API key at $path" >&2
		return 1
	fi
	key=(-authenticationKeyPath "$path" -authenticationKeyID "$id" -authenticationKeyIssuerID "$issuer")
}

# The value App/Local.xcconfig gives the setting $1, or nothing.
local_setting() {
	[ -f App/Local.xcconfig ] || return 0
	sed -n "s/^$1 *= *\([^ ]*\) *\$/\1/p" App/Local.xcconfig | tail -n 1
}

# The iPhone's device tests (KnitDeviceTests): Knit launched live on the phone, on the real radio and permission, with
# the Settings app and SpringBoard driven beside it. Driving the phone needs the maintainer's go-ahead every session
# (.agents/rules/devices.md), so no CI job runs this. The phone is $KNIT_DEVICE, or else the one iPhone the Mac sees
# connected. It stays unlocked for the run, with Auto-Lock off and Settings > Developer > Enable UI Automation on.
# $KNIT_DEVICE_TESTS narrows the run, as in KnitDeviceTests/RadioTests/testBluetoothOffAndOn. Signing, and the
# runner's profile, come from the desktop session and the API key, as gate_device's do.
gate_devicetest() {
	step "xcodebuild test on the iPhone (KnitDeviceTests, signed in the desktop session)"
	xcode_project devicetest
	local team key
	signing_team
	signing_key
	local udid=${KNIT_DEVICE:-}
	if [ -z "$udid" ]; then
		udid=$(connected_iphone)
	fi
	local only=()
	if [ -n "${KNIT_DEVICE_TESTS:-}" ]; then
		only=("-only-testing:$KNIT_DEVICE_TESTS")
	fi
	local results=.build-xcode/devicetest.xcresult status=0
	# A fresh bundle for the same broken-seal reason as gate_device's.
	rm -rf "$xcode_app" "$results"
	scripts/mac-desktop.sh xcodebuild "${xcode_build[@]}" -scheme KnitDevice -destination "platform=iOS,id=$udid" \
		-allowProvisioningUpdates "${team[@]}" "${key[@]}" "${only[@]}" -resultBundlePath "$results" test |
		"${xcode_pretty[@]}" ||
		status=$?
	# XCTest ends the apps it launched as the run finishes, which left Knit closed and the mesh down (2026-09-29).
	# Open it again, pass or fail, so the phone runs as interop.py expects.
	if ! xcrun devicectl device process launch --device "$udid" app.getknit.knit.dev >/dev/null; then
		echo "could not open Knit again on $udid: open it on the phone" >&2
	fi
	return "$status"
}

# The App Store build (ADR 2026-10.8cy5): the Knit scheme archived in Release in the desktop session, held to
# check_release_app, then signed for distribution and exported into .build-xcode/export as an .ipa. Nothing leaves
# the Mac. With the App Store Connect API key, -allowProvisioningUpdates gets the team's Apple Distribution signing and
# makes or renews the profiles for app.getknit.knit, as gate_device's builds do for the .dev id.
gate_archive() {
	step "xcodebuild archive and export (Release, signed for the App Store in the desktop session)"
	archive_and_export export
}

# The same build, uploaded to App Store Connect, where TestFlight picks it up once Apple has processed it. Raise
# CURRENT_PROJECT_VERSION in App/project.yml and App/Info.plist first: App Store Connect refuses a build number it
# already has.
gate_upload() {
	step "xcodebuild archive and upload to App Store Connect (in the desktop session)"
	archive_and_export upload
}

# Archives the app, checks it, then exports it to $1: `export` (an .ipa here) or `upload` (App Store Connect).
archive_and_export() {
	local destination=$1 team key
	xcode_project archive
	signing_team
	signing_key
	local team_id=${KNIT_DEVELOPMENT_TEAM:-$(local_setting DEVELOPMENT_TEAM)}
	rm -rf "$xcode_archive" "$xcode_export"
	mkdir -p "$xcode_export"
	scripts/mac-desktop.sh xcodebuild "${xcode_release[@]}" -scheme Knit -destination 'generic/platform=iOS' \
		-archivePath "$xcode_archive" -allowProvisioningUpdates "${team[@]}" "${key[@]}" archive | "${xcode_pretty[@]}"
	check_release_app "$xcode_archive/Products/Applications/Knit.app"
	# Xcode leaves the build number alone: the one in App/Info.plist is the one App Store Connect sees.
	python3 - "$destination" "$team_id" >"$xcode_export/ExportOptions.plist" <<'PY'
import plistlib, sys
destination, team = sys.argv[1:]
sys.stdout.buffer.write(plistlib.dumps({
	"method": "app-store-connect",
	"destination": destination,
	"teamID": team,
	"signingStyle": "automatic",
	"manageAppVersionAndBuildNumber": False,
	"uploadSymbols": True,
}))
PY
	# Packaging runs /usr/bin/rsync, macOS's openrsync, which starts its other end as the first `rsync` on the PATH.
	# Homebrew's rsync 3 refuses openrsync's --extended-attributes, and the export failed with "Copy failed"
	# (2026-10-03), so the export runs with /usr/bin first.
	PATH="/usr/bin:$PATH" scripts/mac-desktop.sh xcodebuild -exportArchive -archivePath "$xcode_archive" -exportPath "$xcode_export" \
		-exportOptionsPlist "$xcode_export/ExportOptions.plist" -allowProvisioningUpdates "${key[@]}" | "${xcode_pretty[@]}"
	if [ "$destination" = export ]; then
		check_store_ipa "$xcode_export/Knit.ipa" "$team_id"
	fi
}

# The exported .ipa is $1: its app must carry a sound seal and an App Store profile for team $2, which names no devices,
# and must not be debuggable, which only a development build is.
check_store_ipa() {
	local unpacked=$xcode_export/unpacked status=0
	rm -rf "$unpacked"
	ditto -x -k "$1" "$unpacked"
	local app=$unpacked/Payload/Knit.app
	codesign --verify --strict --deep "$app"
	codesign -d --entitlements - --xml "$app" 2>/dev/null >"$unpacked/entitlements.plist"
	security cms -D -i "$app/embedded.mobileprovision" >"$unpacked/profile.plist"
	python3 - "$unpacked/entitlements.plist" "$unpacked/profile.plist" "$2" <<'PY' || status=$?
import plistlib, sys
entitlements, profile = (plistlib.load(open(path, "rb")) for path in sys.argv[1:3])
if entitlements.get("get-task-allow"):
	sys.exit("the exported app is debuggable (get-task-allow): it was signed for development, not the App Store")
if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
	sys.exit(f"the exported app's profile {profile['Name']!r} is not an App Store profile: it names devices")
if profile["TeamIdentifier"] != [sys.argv[3]]:
	sys.exit(f"the exported app is signed for team {profile['TeamIdentifier']}, not {sys.argv[3]}")
print(f"Knit.ipa: signed for the App Store by team {sys.argv[3]}, profile {profile['Name']!r}")
PY
	rm -rf "$unpacked"
	return "$status"
}

# The UDID of the one physical iPhone the Mac sees connected; none, or more than one, fails and names what it saw.
connected_iphone() {
	local list status=0
	list=$(mktemp)
	xcrun devicectl list devices --json-output "$list" >/dev/null
	python3 - "$list" <<'PY' || status=$?
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [
	d for d in devices
	if d["hardwareProperties"].get("reality") == "physical"
	and d["hardwareProperties"].get("deviceType") == "iPhone"
	and d["connectionProperties"].get("tunnelState") == "connected"
]
if len(phones) != 1:
	names = [f"{d['deviceProperties'].get('name')} ({d['hardwareProperties'].get('udid')})" for d in phones]
	sys.exit(f"want one connected iPhone, the Mac sees {len(phones)}: {names}; set KNIT_DEVICE to its UDID")
print(phones[0]["hardwareProperties"]["udid"])
PY
	rm -f "$list"
	return "$status"
}

run() {
	for gate in "$@"; do
		"gate_$gate"
	done
}

case "${1:-fast}" in
fast) run format lint build test ;;
all) run format lint adr build test coverage tsan asan analyze lintorama ;;
format | lint | build | test | coverage | tsan | asan | analyze | periphery | adr | lintorama | xcode | uitest | device | devicetest | \
	release | archive | upload | shots) run "$@" ;;
*)
	echo "usage: $0 [fast|all|format|lint|build|test|coverage|tsan|asan|analyze|periphery|adr|lintorama|xcode|uitest|device|devicetest|release|archive|upload|shots]" >&2
	exit 2
	;;
esac
