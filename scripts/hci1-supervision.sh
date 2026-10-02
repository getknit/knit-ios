#!/bin/sh
# Raises the LE supervision timeout of the connections the ATS2851 dials to 5 s, Android's own, from the kernel's
# 420 ms (.agents/context/linux-peer.md, "What P4 found"). Needs root, and lasts until the dongle is replugged
# or the machine reboots:
#
#     sudo scripts/hci1-supervision.sh              # set it now
#     scripts/hci1-supervision.sh --udev-rule       # print a udev rule that sets it on every plug-in
#
# It touches only the adapter with the ATS2851's address, whatever index the kernel gave it (hci1 until a reboot
# on 2026-10-01 made it hci0), and never the maintainer's adapter.

set -eu

expected=f0:0d:00:00:00:02
# Units of 10 ms.
timeout=500

if [ "${1:-}" = "--udev-rule" ]; then
	script=$(readlink -f "$0")
	# The Actions ATS2851's USB ids; the script still checks the address before it writes anything.
	printf 'ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", ATTRS{idVendor}=="10d7", ATTRS{idProduct}=="b012", RUN+="%s %%k"\n' "$script"
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	echo "run it as root: sudo $0" >&2
	exit 1
fi

# `identity` starts with an adapter's public address.
address_of() {
	cut -d' ' -f1 < "/sys/kernel/debug/bluetooth/$1/identity" 2>/dev/null | tr 'A-F' 'a-f'
}

# udev names the adapter it saw; by hand, the ATS2851 is found by its address.
adapter=${1:-}
if [ -z "$adapter" ]; then
	for dir in /sys/kernel/debug/bluetooth/hci*; do
		name=${dir##*/}
		if [ "$(address_of "$name")" = "$expected" ]; then
			adapter=$name
		fi
	done
	if [ -z "$adapter" ]; then
		echo "no adapter has the ATS2851's address $expected" >&2
		exit 1
	fi
fi
case $adapter in
	hci[0-9]*) ;;
	*) echo "not an adapter: $adapter" >&2; exit 1 ;;
esac

# The kernel adds these files once the adapter is set up, which can be a moment after udev hears of it.
file=/sys/kernel/debug/bluetooth/$adapter/supervision_timeout
tries=0
while [ ! -e "$file" ] && [ "$tries" -lt 30 ]; do
	sleep 0.5
	tries=$((tries + 1))
done

address=$(address_of "$adapter")
if [ "$address" != "$expected" ]; then
	echo "refusing $adapter: its address is $address, not the ATS2851's $expected" >&2
	exit 1
fi
echo "$timeout" > "$file"
echo "$adapter supervision_timeout $(cat "$file") (x 10 ms)"
