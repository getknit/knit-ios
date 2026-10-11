#!/usr/bin/env bash
# Mirror this working tree onto the Mac and run commands there, over one multiplexed ssh connection.
#
#     scripts/mac.sh sync                     # mirror the tree, .git included, into ~/source/knit-ios-mirror
#     scripts/mac.sh run <command> [args...]  # sync, then run the command in the mirror; its exit status is ours
#     scripts/mac.sh run bash -c 'a | b'      # pipes, && and globs need a shell of their own
#     scripts/mac.sh pull <path> [dest]       # copy a file or directory out of the mirror, into .build-mac/ by default
#     scripts/mac.sh shell                    # sync, then an interactive shell in the mirror
#
# The mirror follows every .gitignore, so build products stay on their own side: the Mac keeps its .build/ and
# DerivedData/ across syncs, --delete never touches them, and nothing ignored (.env, .private/, local settings)
# leaves this machine. .git goes too, so git in the mirror sees exactly the commit and the changes here. The
# mirror is disposable: work done in it is overwritten by the next sync. The Mac's own checkout,
# ~/source/knit-ios, is for work at the Mac and is never touched.
#
# The mirror sits beside ~/source/knit-next on the Mac, and the Mac's `macos` CI runner builds there too, one
# job at a time. A command that outlives this script (the ssh client killed without a tty) keeps running on
# the Mac; `scripts/mac.sh run pkill -f <pattern>` stops it.
#
# KNIT_MAC_HOST names the Mac, from the environment or else .private/lab.env, which keeps the lab's hosts out of the
# repository (ADR 2026-10.ab6k). KNIT_MAC_DIR (source/knit-ios-mirror, under the Mac's home) overrides the mirror's
# place. KNIT_MAC_SYNC=0 skips the sync before run and shell, and KNIT_MAC_VERBOSE=1 lists what changed.

set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

if [ -z "${KNIT_MAC_HOST:-}" ] && [ -f .private/lab.env ]; then
	KNIT_MAC_HOST=$(sed -n 's/^KNIT_MAC_HOST=//p' .private/lab.env | tail -n 1)
fi
host=${KNIT_MAC_HOST:?set KNIT_MAC_HOST in .private/lab.env or the environment (ADR 2026-10.ab6k)}
dir=${KNIT_MAC_DIR:-source/knit-ios-mirror}

# Every call shares one master connection, so only the first pays for the handshake. These match the
# `Host` block for the Mac in ~/.ssh/config, whose sockets they share, but work without it.
ssh_opts=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%C" -o ControlPersist=20m -o Compression=no)

# macOS ships openrsync, which speaks protocol 29 and handles neither these filters nor --delete-after well.
# The Mac has Homebrew's rsync 3 for this (`brew install rsync`).
remote_rsync=/opt/homebrew/bin/rsync

usage() {
	sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
	exit 2
}

sync_tree() {
	local changes count
	# Filter order matters: the first match wins. Lock files are git's own in-flight state. .git is included
	# whole before the .gitignore rules are read, so an ignore pattern can never drop a ref or an object.
	# --delete-after lets a .gitignore that changes in this sync protect its paths from this sync's deletions.
	# A worktree's .git is a file naming a Git dir on this machine, which the Mac cannot read. Its tree goes as any
	# other, and the shared Git dir goes after it as the mirror's .git, with the worktree's own HEAD and index.
	local worktree=
	if [ -f .git ]; then
		worktree=$(git rev-parse --path-format=absolute --git-dir)
	fi
	changes=$(rsync -rlpt --mkpath --delete-after --itemize-changes \
		--rsync-path="$remote_rsync" -e "ssh ${ssh_opts[*]}" \
		${worktree:+--filter='- /.git'} \
		--filter='- /.git/*.lock' \
		--filter='+ /.git/***' \
		--filter=':- .gitignore' \
		./ "$host:$dir/")
	if [ -n "$worktree" ]; then
		# shellcheck disable=SC2029 # expanding here is the point
		ssh "${ssh_opts[@]}" "$host" "[ -d $(printf '%q' "$dir/.git") ] || rm -f $(printf '%q' "$dir/.git")"
		rsync -rlpt --mkpath --delete-after --rsync-path="$remote_rsync" -e "ssh ${ssh_opts[*]}" \
			--filter='- *.lock' --filter='- /worktrees/' \
			"$(git rev-parse --path-format=absolute --git-common-dir)/" "$host:$dir/.git/"
		rsync -lpt --rsync-path="$remote_rsync" -e "ssh ${ssh_opts[*]}" \
			"$worktree/HEAD" "$worktree/index" "$host:$dir/.git/"
	fi
	count=0
	if [ -n "$changes" ]; then
		count=$(grep -cv '^\.' <<<"$changes" || true)
	fi
	if [ "${KNIT_MAC_VERBOSE:-0}" != 0 ] && [ -n "$changes" ]; then
		grep -v '^\.' <<<"$changes" >&2 || true
	fi
	echo "mac.sh: $count changes synced to $host:$dir" >&2
}

remote() {
	local tty=()
	if [ -t 0 ] && [ -t 1 ]; then
		tty=(-t)
	fi
	# ssh joins its arguments into one string for the remote shell, so quote each one here: what reaches the
	# Mac is the argument list as given, not a line to re-split.
	# shellcheck disable=SC2029 # expanding here is the point
	ssh "${ssh_opts[@]}" "${tty[@]}" "$host" "cd $(printf '%q' "$dir") && exec $(printf '%q ' "$@")"
}

[ $# -ge 1 ] || usage
command=$1
shift

case "$command" in
sync)
	sync_tree
	;;
run)
	[ $# -ge 1 ] || usage
	if [ "${KNIT_MAC_SYNC:-1}" != 0 ]; then
		sync_tree
	fi
	remote "$@"
	;;
shell)
	if [ "${KNIT_MAC_SYNC:-1}" != 0 ]; then
		sync_tree
	fi
	# shellcheck disable=SC2029 # expanding here is the point
	ssh "${ssh_opts[@]}" -t "$host" "cd $(printf '%q' "$dir") && exec \$SHELL -l"
	;;
pull)
	[ $# -ge 1 ] || usage
	dest=${2:-.build-mac}
	rsync -rlpt --mkpath --rsync-path="$remote_rsync" -e "ssh ${ssh_opts[*]}" \
		"$host:$dir/$1" "$dest/"
	echo "mac.sh: pulled $1 into $dest/" >&2
	;;
*)
	usage
	;;
esac
