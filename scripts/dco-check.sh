#!/usr/bin/env bash
# Require a DCO sign-off from the author or the committer on every non-merge commit in <base>..<head>.
#
#     scripts/dco-check.sh origin/main HEAD
#
# CI's `lint:dco` job runs this on merge requests. It reports every offender at once, then names the fix.

set -euo pipefail

base="${1:?usage: $0 <base> <head>}"
head="${2:-HEAD}"

missing=0
while read -r commit; do
	author=$(git log -1 --format=%ae "$commit")
	committer=$(git log -1 --format=%ce "$commit")
	if ! git log -1 --format=%B "$commit" | grep -i '^Signed-off-by:' | grep -qF -e "<$author>" -e "<$committer>"; then
		echo "no DCO sign-off: $(git log -1 --format='%h %s' "$commit")"
		missing=1
	fi
done < <(git rev-list --no-merges "$base..$head")

if [ "$missing" -ne 0 ]; then
	echo
	echo "Sign off with: git rebase --signoff $base (CONTRIBUTING.md explains the DCO)."
	exit 1
fi
echo "dco-check: every commit in $base..$head is signed off"
