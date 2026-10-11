#!/usr/bin/env bash
# knit-peer on the Mac, on CoreBluetooth, for checklist M (ADR 2026-09.vcdk). Runs on the Mac, from the Linux machine
# through ssh.
#
#     scripts/mac-peer.sh build           # swift build --product knit-peer, then sign it in the desktop session
#     scripts/mac-peer.sh run [ARGS...]   # the signed peer in the desktop session, JSON lines on stdin and stdout
#     scripts/mac-peer.sh keygen [ARGS...]
#
# macOS asks for Bluetooth only in the desktop session, and keeps the answer for a code signature. An ad-hoc
# signature changes with every build, so the peer is signed with the team's Apple Development certificate and a
# fixed identifier, and one Allow at the Mac lasts. The first run shows the prompt there.

set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
peer=$root/.build/out/Products/Debug/knit-peer

if [ "$(uname -s)" != Darwin ]; then
	echo "mac-peer.sh runs on the Mac: ssh \$KNIT_MAC_HOST 'cd source/knit-ios-mirror && scripts/mac-peer.sh $*'" >&2
	exit 2
fi

case "${1:-}" in
build)
	swift build --product knit-peer -j "${SWIFT_JOBS:-8}" --only-use-versions-from-resolved-file
	scripts/mac-desktop.sh codesign --force --sign "Apple Development" --identifier app.getknit.knit-peer "$peer"
	codesign --verify --strict "$peer"
	;;
run)
	shift
	exec scripts/mac-desktop.sh --stdio "$peer" run "$@"
	;;
keygen)
	shift
	exec "$peer" keygen "$@"
	;;
*)
	sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
	exit 2
	;;
esac
