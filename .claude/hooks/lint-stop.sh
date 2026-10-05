#!/usr/bin/env bash
# Stop hook: before a turn ends, run the linters that need no build.
#
#   - lintorama (markdown, YAML, shell, editorconfig) over the tree, in its published container;
#   - swift-format and SwiftLint over the Swift files changed since HEAD, tracked or not.
#
# Clean -> exit 0 and the turn ends. Findings -> exit 2 with them on stderr, which Claude Code feeds back so
# the model fixes them. Builds and tests stay out on purpose: knit-next dropped its build and test Stop hooks
# once each turn cost minutes. `scripts/check.sh fast` runs them in the pre-push hook instead. Periphery, which
# needs an incremental build, has a Stop hook of its own: periphery-stop.sh.
#
# Honors `stop_hook_active`, so an unfixable finding cannot trap a session in a loop, and exits 0 when docker
# or the image is missing (offline), so a missing tool never wedges a turn.

set -uo pipefail

input=$(cat)
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
	exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$project_dir" || exit 0

findings=""

image="zaventh/lintorama:7"
if command -v docker >/dev/null 2>&1 && { docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null 2>&1; }; then
	# In a linked worktree `.git` is a pointer file; mount the common git dir at the same absolute path.
	git_mounts=(-v "$project_dir"/.git:/code/.git)
	if [ -f "$project_dir/.git" ]; then
		common_dir=$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
		[ -n "$common_dir" ] && git_mounts+=(-v "$common_dir":"$common_dir")
	fi
	if ! output=$(docker run --rm -v "$project_dir":/code "${git_mounts[@]}" "$image" 2>&1); then
		findings+=$'lintorama:\n'"$output"$'\n'
	fi
fi

mapfile -t changed < <(git status --porcelain --untracked-files=all -- '*.swift' | awk '$1 != "D" {print $NF}')
if [ ${#changed[@]} -gt 0 ]; then
	if [ "$(uname -s)" = Linux ] && [ -z "${LINUX_SOURCEKIT_LIB_PATH:-}" ]; then
		resources=$(swift -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')
		LINUX_SOURCEKIT_LIB_PATH=$(readlink -f "$resources/..")
		export LINUX_SOURCEKIT_LIB_PATH
	fi
	if ! output=$(swift format lint --strict "${changed[@]}" 2>&1); then
		findings+=$'swift-format:\n'"$output"$'\n'
	fi
	if ! output=$(swiftlint lint --strict --quiet --force-exclude "${changed[@]}" 2>&1); then
		findings+=$'swiftlint:\n'"$output"$'\n'
	fi
fi

if [ -n "$findings" ]; then
	{
		echo "Stop blocked: the linters found issues. Fix them, then finish:"
		echo
		printf '%s' "$findings"
	} >&2
	exit 2
fi
exit 0
