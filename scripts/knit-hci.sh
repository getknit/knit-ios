#!/bin/sh
# Runs btmon, hcitool or btmgmt as root on one of Knit's own adapters, whatever hciN the kernel gave it this boot, and
# never on the maintainer's: dongle A or B, the nRF52840s, or the ATS2851 they replaced. sudoers grants this script in
# place of lines that name an index, which a reboot on 2026-10-01 pointed at the maintainer's adapter
# (.agents/rules/devices.md). Install it root-owned, outside the tree, since sudo runs it:
#
#     sudo install -o root -g root -m 0755 scripts/knit-hci.sh /usr/local/sbin/knit-hci
#     sudo install -o root -g root -m 0644 <your adapters> /etc/knit-hci.conf
#     # /etc/sudoers.d/knit-hci:   <user> ALL=(root) NOPASSWD: /usr/local/sbin/knit-hci *
#
# /etc/knit-hci.conf names each adapter's address, one `NAME AA:BB:CC:DD:EE:FF` line each for a, b and ats2851. The
# lab's addresses stay out of the repository (ADR 2026-10.ab6k), and sudo clears the environment, so they live in a
# root-owned file that nobody else can write; this script refuses any other.
#
#     knit-hci name                                 # dongle A's hciN; needs no root
#     sudo knit-hci btmon -w capture.btsnoop        # btmon -i hciN ...
#     sudo knit-hci b hcitool lescan --duplicates   # hcitool -i hciN ..., on dongle B
#     printf 'info\n' | sudo knit-hci btmgmt        # btmgmt, fed `select hciN` before the commands on stdin
#
# The first argument may name the adapter: a (the default), b or ats2851.
#
# A one-shot `btmgmt --index N <command>` acts on hci0 in BlueZ 5.72, so btmgmt takes its commands on stdin only,
# after a `select` this script writes, and any `select` line of the caller's is dropped. Arguments that pick an
# adapter (-i, --index) are refused.

set -eu

# Knit's adapters (.agents/context/linux-peer.md, "The adapter"). Only these addresses are ever selected.
conf=/etc/knit-hci.conf
adapter=a
case ${1:-} in
	a | b | ats2851)
		adapter=$1
		shift
		;;
esac
if [ ! -f "$conf" ] || [ "$(stat -c %u "$conf")" != 0 ] || [ -n "$(find "$conf" -perm /022)" ]; then
	echo "$conf must exist, be root's, and be writable by root alone" >&2
	exit 1
fi
expected=$(awk -v want="$adapter" '$1 == want { print toupper($2); exit }' "$conf")
case $expected in
	[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) ;;
	*) echo "$conf names no address for $adapter" >&2; exit 1 ;;
esac

usage() {
	echo "usage: knit-hci [a|b|ats2851] name | btmon [ARGS...] | hcitool COMMAND [ARGS...] | btmgmt [--timeout SECONDS]" >&2
	exit 2
}

name=$(hcitool dev | awk -v want="$expected" 'toupper($2) == want { print $1 }')
case $name in
	hci[0-9] | hci[0-9][0-9]) ;;
	*) echo "no adapter has $adapter's address $expected" >&2; exit 1 ;;
esac

[ $# -ge 1 ] || usage
tool=$1
shift

if [ "$tool" = name ]; then
	echo "$name"
	exit 0
fi

for argument in "$@"; do
	case $argument in
		-i | -i* | --index | --index=* | --device | --device=*)
			echo "refusing $argument: this script picks the adapter" >&2
			exit 2
			;;
	esac
done

case $tool in
	btmon) exec /usr/bin/btmon -i "$name" "$@" ;;
	hcitool) exec /usr/bin/hcitool -i "$name" "$@" ;;
	btmgmt)
		timeout=10
		if [ $# -eq 2 ] && [ "$1" = --timeout ]; then
			case $2 in
				'' | *[!0-9]*) usage ;;
			esac
			timeout=$2
		elif [ $# -ne 0 ]; then
			usage
		fi
		{
			printf 'select %s\n' "$name"
			grep --line-buffered -v -i -E '^[[:space:]]*select([[:space:]]|$)' || true
		} | /usr/bin/btmgmt --timeout "$timeout"
		;;
	*) usage ;;
esac
