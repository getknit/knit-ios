#!/usr/bin/env bash
# Stop hook: before a turn ends, run `scripts/check.sh periphery` when the Swift sources changed since its last
# clean pass, so unused code is caught in the turn that leaves it rather than in CI.
#
# The gate builds, which lint-stop.sh avoids, but the build is incremental in the shared `.build` and runs under
# check.sh's SWIFT_JOBS and nice caps: a few seconds when the tree is already built. A content fingerprint of the
# Swift files (tracked or not), Package.resolved and check.sh is kept in `.build` after each clean pass, so a turn
# that touched no Swift costs only the hash. Commits made during the turn do not hide a change, since the
# fingerprint ignores Git history.
#
# Clean -> exit 0. Findings or a failed build -> exit 2 with the output on stderr, which Claude Code feeds back so
# the model fixes them. Linux only: the Mac's gate also needs the iPhone build's index (`check.sh xcode
# periphery`), which CI's `verify:periphery` job runs. Honors `stop_hook_active`, and exits 0 when Periphery or
# Swift is missing, so a missing tool never wedges a turn.

set -uo pipefail

input=$(cat)
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
	exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$project_dir" || exit 0

[ "$(uname -s)" = Linux ] || exit 0
command -v periphery >/dev/null 2>&1 || exit 0
command -v swift >/dev/null 2>&1 || exit 0

mapfile -d '' listed < <(git ls-files -z --cached --others --exclude-standard -- '*.swift' Package.resolved scripts/check.sh)
files=()
for file in "${listed[@]}"; do
	[ -f "$file" ] && files+=("$file")
done
[ ${#files[@]} -gt 0 ] || exit 0
fingerprint=$({ printf '%s\n' "${files[@]}"; git hash-object -- "${files[@]}"; } | sha256sum | cut -d ' ' -f 1)

stamp=.build/periphery-stop.clean
if [ "$(cat "$stamp" 2>/dev/null)" = "$fingerprint" ]; then
	exit 0
fi

if output=$(scripts/check.sh periphery 2>&1); then
	mkdir -p .build && printf '%s\n' "$fingerprint" >"$stamp"
	exit 0
fi

{
	echo "Stop blocked: scripts/check.sh periphery failed. Remove the unused code (or fix the build), then finish."
	echo "A deliberate keep takes a periphery:ignore with its reason (ADR 2026-09.xgtz)."
	echo
	# SwiftPM's progress lines say nothing the model can act on.
	printf '%s\n' "$output" | grep -v -e '^\[' -e '^== ' -e '^Building for' | tail -n 80
} >&2
exit 2
