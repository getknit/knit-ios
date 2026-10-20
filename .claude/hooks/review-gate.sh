#!/usr/bin/env bash
# Stop hook: an uncommitted change under a reviewer's paths gets that reviewer before Claude finishes the turn
# (ADR 2026-10.zjmx, `.agents/rules/owners.md`, `.agents/rules/review-rounds.md`). Ported from knit-next's gate of the
# same name.
#
# Each reviewer persona (`.agents/personas/<name>.md`) hunts one class of defect from a catalogue of the ones this
# repository already shipped and fixed. review-gate.conf maps each to its stage and the paths it owns, and this script
# asks for the reviewers of the earliest stage with a review pending, in one message, so they run side by side
# (review-rounds.md: the plane reviewers first, a test reviewer once none of those is pending).
#
# no uncommitted change under a reviewer's paths                                     -> not pending.
# same base and files as its last stamp, and within its follow-up lines of that diff -> not pending: the caller is
#                                                                                      applying its findings.
# anything else                                                                      -> pending; owed unless this
#                                                                                      same state was asked for
#                                                                                      already.
# A stamp covers one review round: a commit since that touches the reviewer's paths, or a file the review never saw,
# needs a fresh one, or a small new change would ride an old stamp's slack. With no such commit, the next pass is a
# follow-up: the diff since the stamp goes to `<git dir>/claude-review/<name>.delta` and the message names it, so the
# reviewer reads the delta and closes its previous findings rather than reading the whole change again.
# Nothing owed -> exit 0, and the turn ends. Otherwise exit 2 with the instruction on stderr, which Claude Code feeds
# back.
#
# `--stamp <name>` records what a review approved: each reviewer runs it as its last step, so the few-line edits that
# apply its findings don't ask for a review of the review. The state lives in the git dir, so each worktree keeps its
# own. Honors `stop_hook_active`, so the enforced round can always end. It hashes diffs and builds nothing (ADR
# 2026-09.jgs6); the reviewers it asks for run their own tests.

set -uo pipefail

conf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-gate.conf"
project_dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$project_dir" || exit 0
git rev-parse --verify --quiet HEAD >/dev/null || exit 0
git_dir=$(git rev-parse --absolute-git-dir)
state="$git_dir/claude-review"

reviewers() { grep -v -e '^#' -e '^[[:space:]]*$' "$conf"; }

# What a reviewer reads: the tracked diff plus every untracked file's bytes.
snapshot() {
	git diff HEAD -- "$@"
	git ls-files --others --exclude-standard -- "$@" | sort | while IFS= read -r f; do
		printf '%s\n' "$f"
		cat -- "$f"
	done
}

# The working state of the paths as a git tree, written through a throwaway index so the real one is untouched: the
# stamp keeps it, and a follow-up pass's delta is a plain `git diff` between two of them.
worktree_tree() {
	local dir
	dir=$(mktemp -d)
	cp "$git_dir/index" "$dir/index" 2>/dev/null
	GIT_INDEX_FILE="$dir/index" git add -A -- "$@" >/dev/null 2>&1
	GIT_INDEX_FILE="$dir/index" git write-tree
	rm -rf "$dir"
}

# Whether <name>'s stamp still reads against HEAD: HEAD is the stamped commit, or the commits since touch none of the
# reviewer's paths (a docs or hook commit).
same_base() {
	local name=$1 head
	shift
	head=$(cat "$state/$name.head" 2>/dev/null) || return 1
	[ "$head" = "$(git rev-parse HEAD)" ] && return 0
	git cat-file -e "$head^{commit}" 2>/dev/null && git diff --quiet "$head" HEAD -- "$@"
}

# One path per line, a space in a name included.
changed_files() {
	{
		git diff --name-only HEAD -- "$@"
		git ls-files --others --exclude-standard -- "$@"
	} | sort -u
}

fingerprint() { printf '%s\n' "$1" | sha256sum | cut -d ' ' -f 1; }

# Content lines only: a follow-up edit shifts the line numbers in every later hunk header and the blob ids in each
# `index` line, which would otherwise count as changes of their own.
content() { grep -v -e '^index ' -e '^@@ '; }

if [ "${1:-}" = "--stamp" ]; then
	name="${2:?usage: review-gate.sh --stamp <reviewer>}"
	line=$(reviewers | awk -F '\t' -v n="$name" '$1 == n')
	if [ -z "$line" ]; then
		echo "review-gate: no reviewer named '$name' in $conf" >&2
		exit 1
	fi
	IFS=$'\t' read -r _ _ _ paths _ <<<"$line"
	read -ra specs <<<"$paths"
	current=$(snapshot "${specs[@]}")
	mkdir -p "$state"
	printf '%s\n' "$current" >"$state/$name.snapshot"
	changed_files "${specs[@]}" >"$state/$name.files"
	git rev-parse HEAD >"$state/$name.head"
	worktree_tree "${specs[@]}" >"$state/$name.tree"
	rm -f "$state/$name.delta"
	fingerprint "$current" >"$state/$name.asked"
	echo "$name: review stamped ($(wc -l <"$state/$name.snapshot") lines of diff)"
	exit 0
fi

input=$(cat)
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
	exit 0
fi

# Pass 1: which reviewers have a review pending, and the earliest stage among them.
pending=()
first_stage=""
while IFS=$'\t' read -r name stage follow_up paths relay <&3; do
	read -ra specs <<<"$paths"
	changed=$(changed_files "${specs[@]}")
	[ -n "$changed" ] || continue

	current=$(snapshot "${specs[@]}")
	same_round=""
	if [ -f "$state/$name.snapshot" ] && same_base "$name" "${specs[@]}"; then
		same_round=1
		if [ -z "$(comm -23 <(printf '%s\n' "$changed") "$state/$name.files" 2>/dev/null)" ]; then
			delta=$(diff <(content <"$state/$name.snapshot") <(printf '%s\n' "$current" | content) | grep -c '^[<>]')
			[ "$delta" -le "$follow_up" ] && continue
		fi
	fi
	pending+=("$name"$'\t'"$stage"$'\t'"$paths"$'\t'"$relay"$'\t'"$same_round")
	if [ -z "$first_stage" ] || [ "$stage" -lt "$first_stage" ]; then first_stage=$stage; fi
done 3< <(reviewers)

[ ${#pending[@]} -gt 0 ] || exit 0

# Pass 2: ask for the pending reviewers of that stage, unless this same state was asked for already (they may be
# running now). A later stage waits, owed or not, until the earlier one has stamped.
owed=""
relays=""
followups=""
later=""
for entry in "${pending[@]}"; do
	IFS=$'\t' read -r name stage paths relay same_round <<<"$entry"
	if [ "$stage" != "$first_stage" ]; then
		later+=" $name"
		continue
	fi
	read -ra specs <<<"$paths"
	print=$(fingerprint "$(snapshot "${specs[@]}")")
	[ "$(cat "$state/$name.asked" 2>/dev/null)" = "$print" ] && continue
	mkdir -p "$state"
	printf '%s\n' "$print" >"$state/$name.asked"

	label="$name:"
	if [ -n "$same_round" ] && [ -s "$state/$name.tree" ]; then
		git diff "$(cat "$state/$name.tree")" "$(worktree_tree "${specs[@]}")" -- "${specs[@]}" >"$state/$name.delta"
		label="$name (follow-up pass, its delta: $state/$name.delta, $(wc -l <"$state/$name.delta") lines):"
		followups+=" $name"
	else
		rm -f "$state/$name.delta"
	fi
	owed+="  $label"$'\n'"$(changed_files "${specs[@]}" | sed 's/^/    /')"$'\n'
	relays+="  $name: $relay"$'\n'
done

[ -n "$owed" ] || exit 0
{
	echo "Stop blocked: these changes have no review from the reviewer that owns them:"
	printf '%s' "$owed"
	echo
	echo "Spawn each reviewer named above (Agent tool, subagent_type = its name) on its files, all in one message."
	echo "Each reads the change against its catalogue (.agents/personas/<name>.md), runs its suites (SwiftPM's lock"
	echo "makes their test runs take turns), and stamps what it reviewed (.agents/rules/review-rounds.md sets the pass"
	echo "and the labels)."
	if [ -n "$followups" ]; then
		echo "On a follow-up pass (${followups# }), hand the reviewer its delta file and its previous findings: it checks"
		echo "each finding closed and reviews the delta; a new finding outside it counts only if it is Blocking."
	fi
	if [ -n "$later" ]; then
		echo "Asked for once these have stamped (test reviewers come second):${later}."
	fi
	echo "Every finding comes labelled Blocking or Non-blocking. Fix each blocking one, or say why it does not hold;"
	echo "apply the non-blocking ones in the same batch or list them for the user as follow-ups. Once no blocking"
	echo "finding is left, run the Mac gate yourself if KnitBLE or Knit changed, then give the user the findings and,"
	echo "from each report:"
	printf '%s' "$relays"
	echo "See .agents/rules/owners.md for the paths this hook cannot see."
} >&2
exit 2
