#!/usr/bin/env bash
# Point the xtool Darwin SDK's clang resource directory at the headers of the Swift toolchain that compiles.
#
# xtool 1.20.1's SDK bundle ships clang builtin headers older than the Swift 6.4 toolchain's clang 21. Their
# float.h still does `#include_next <float.h>` on Apple platforms, which lands on the Xcode 27 SDK's own
# float.h, a header the SDK now fences off in `_c_standard_library_obsolete`. Every C module scan then fails
# with "requires feature 'found_incompatible_headers__check_search_paths'", and nothing builds for iOS.
#
# The fix links the toolchain's own builtin headers into the bundle, keeps the bundle's compiler-rt libraries
# (lib/) for the link step, and repoints usr/lib/swift/clang at the result. `xtool sdk install` rebuilds the
# bundle and drops the fix, so rerun this afterwards. `--undo` restores the original link.
#
#     scripts/xtool-sdk-fixup.sh          # apply (idempotent)
#     scripts/xtool-sdk-fixup.sh --undo   # restore
#     scripts/xtool-sdk-fixup.sh --check  # exit 1 if the fix is not in place

set -euo pipefail

bundle="${XTOOL_SDK_BUNDLE:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
lib="$bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
# The compiler says where its own resources live; that works under swiftly, whose `swift` is a proxy binary.
resources=$(swift -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')
toolchain_clang=$(readlink -f "$resources/../clang")

[ -d "$lib/clang" ] || { echo "xtool-sdk-fixup: no Darwin SDK at $bundle (run xtool sdk install first)" >&2; exit 2; }

version=$(find "$lib/clang" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -n | tail -1)
fixed="$version-swift"
headers="$toolchain_clang/$version/include"

case "${1:-apply}" in
--check)
	[ "$(readlink "$lib/swift/clang")" = "../clang/$fixed" ] || { echo "xtool-sdk-fixup: not applied" >&2; exit 1; }
	echo "xtool-sdk-fixup: applied ($lib/swift/clang -> ../clang/$fixed)"
	;;
--undo)
	ln -sfn "../clang/$version" "$lib/swift/clang"
	rm -rf "${lib:?}/clang/$fixed"
	echo "xtool-sdk-fixup: restored $lib/swift/clang -> ../clang/$version"
	;;
apply)
	[ -d "$headers" ] || { echo "xtool-sdk-fixup: toolchain has no clang $version headers at $headers" >&2; exit 2; }
	mkdir -p "$lib/clang/$fixed"
	ln -sfn "$headers" "$lib/clang/$fixed/include"
	ln -sfn "../$version/lib" "$lib/clang/$fixed/lib"
	ln -sfn "../$version/share" "$lib/clang/$fixed/share"
	ln -sfn "../clang/$fixed" "$lib/swift/clang"
	echo "xtool-sdk-fixup: $lib/swift/clang -> ../clang/$fixed (headers from $headers)"
	;;
*)
	echo "usage: $0 [--check|--undo]" >&2
	exit 2
	;;
esac
