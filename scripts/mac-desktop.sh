#!/usr/bin/env bash
# Run a command on the Mac inside its desktop session, and return the command's exit status.
#
#     scripts/mac-desktop.sh <command> [args...]            # on the Mac, from ssh or a CI job
#     scripts/mac-desktop.sh --stdio <command> [args...]    # the same, with this shell's stdin fed to the command
#     scripts/mac.sh run scripts/mac-desktop.sh <command>   # from linux-host
#
# An ssh login gets a security session of its own, where the login Keychain stays locked and codesign fails with
# errSecInternalComponent. A launchd job in gui/<uid> runs in the desktop session instead, where the Keychain is
# unlocked and the signing key's "Always Allow" applies (ADR 2026-09.zawh). The job starts in the current directory
# at this shell's niceness, with its PATH, HOME, DEVELOPER_DIR and every SWIFT_* and KNIT_* variable. Its output
# streams back here, and Ctrl-C or a cancelled CI job stops it.
#
# --stdio also hands the job this shell's standard input, through a FIFO, and keeps its standard error apart from its
# output. That is how a peer driven over ssh gets Bluetooth: macOS asks for it only in the desktop session, and a
# process started from ssh is refused it (ADR 2026-09.vcdk).

set -euo pipefail

stdio=
if [ "${1:-}" = --stdio ]; then
	stdio=1
	shift
fi
if [ $# -lt 1 ]; then
	sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
	exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
	echo "mac-desktop.sh runs on the Mac: scripts/mac.sh run scripts/mac-desktop.sh $*" >&2
	exit 2
fi

uid=$(id -u)
work=$(mktemp -d "${TMPDIR:-/tmp}/knit-desktop.XXXXXX")
label="app.getknit.desktop.${work##*.}"
tail_pid=
err_pid=
feed_pid=

# shellcheck disable=SC2317,SC2329 # the EXIT trap calls it
cleanup() {
	launchctl bootout "gui/$uid/$label" 2>/dev/null || sudo -n launchctl bootout "gui/$uid/$label" 2>/dev/null || true
	for pid in "$tail_pid" "$err_pid" "$feed_pid"; do
		if [ -n "$pid" ]; then
			kill "$pid" 2>/dev/null || true
		fi
	done
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# The job's script: this shell's directory and environment, then the command, then its status for us to read.
{
	echo '#!/bin/bash'
	printf 'trap '\''printf "%%s\\n" "$?" >%q.tmp && mv %q.tmp %q'\'' EXIT\n' "$work/status" "$work/status" "$work/status"
	printf 'cd %q || exit 1\n' "$PWD"
	for name in $(compgen -e); do
		case "$name" in
		PATH | HOME | DEVELOPER_DIR | SWIFT_* | KNIT_*) printf 'export %s=%q\n' "$name" "${!name}" ;;
		esac
	done
	printf '%q ' "$@"
	echo
} >"$work/run.sh"
: >"$work/log"
: >"$work/err"
error_path=$work/log
input_keys=
if [ -n "$stdio" ]; then
	error_path=$work/err
	mkfifo "$work/in"
	input_keys="<key>StandardInPath</key><string>$work/in</string>"
fi

cat >"$work/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$work/run.sh</string>
	</array>
	<key>StandardOutPath</key>
	<string>$work/log</string>
	<key>StandardErrorPath</key>
	<string>$error_path</string>
	$input_keys
	<key>Nice</key>
	<integer>$(ps -o nice= -p $$ | tr -d ' ')</integer>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF

tail -n +1 -f "$work/log" &
tail_pid=$!
if [ -n "$stdio" ]; then
	tail -n +1 -f "$work/err" >&2 &
	err_pid=$!
	# launchd opens the FIFO for the job as it starts it; until then this blocks, and the command sees end of file
	# once this shell's input ends.
	# A background job's input would be /dev/null, so it reads this shell's through descriptor 3.
	exec 3<&0
	cat <&3 >"$work/in" &
	feed_pid=$!
fi
launchctl bootstrap "gui/$uid" "$work/job.plist" 2>/dev/null || sudo -n launchctl bootstrap "gui/$uid" "$work/job.plist"

# The job writes its status as it exits. If launchd loses it first (killed outright), stop waiting.
while [ ! -f "$work/status" ]; do
	if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
		sleep 1
		[ -f "$work/status" ] || {
			echo "mac-desktop.sh: the job ended without a status" >&2
			exit 1
		}
	fi
	sleep 0.5
done
sleep 0.5 # let tail print the last lines
exit "$(cat "$work/status")"
