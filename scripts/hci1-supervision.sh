#!/bin/sh
# Raises the LE supervision timeout of the connections hci1 dials to 5 s, Android's own, from the kernel's
# 420 ms (.agents/context/linux-peer.md, "What P4 found"). Needs root, and lasts until the dongle is replugged
# or the machine reboots:
#
#     sudo scripts/hci1-supervision.sh              # set it now
#     scripts/hci1-supervision.sh --udev-rule       # print a udev rule that sets it on every plug-in
#
# It touches only the adapter with the Edimax's address, whatever index the kernel gave it: never hci0.

set -eu

expected=0a:bc:de:00:00:a1
# Units of 10 ms.
timeout=500

if [ "${1:-}" = "--udev-rule" ]; then
	script=$(readlink -f "$0")
	# The Edimax BT-8500's USB ids; the script still checks the address before it writes anything.
	printf 'ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", ATTRS{idVendor}=="7392", ATTRS{idProduct}=="c611", RUN+="%s %%k"\n' "$script"
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	echo "run it as root: sudo $0" >&2
	exit 1
fi

adapter=${1:-hci1}
case $adapter in
	hci0) echo "refusing hci0: it is the maintainer's adapter" >&2; exit 1 ;;
	hci[0-9]*) ;;
	*) echo "not an adapter: $adapter" >&2; exit 1 ;;
esac

# The kernel adds these files once the adapter is set up, which can be a moment after udev hears of it.
dir=/sys/kernel/debug/bluetooth/$adapter
file=$dir/supervision_timeout
tries=0
while [ ! -e "$file" ] && [ "$tries" -lt 30 ]; do
	sleep 0.5
	tries=$((tries + 1))
done

# `identity` starts with the adapter's public address.
address=$(cut -d' ' -f1 < "$dir/identity" | tr 'A-F' 'a-f')
if [ "$address" != "$expected" ]; then
	echo "refusing $adapter: its address is $address, not the Edimax's $expected" >&2
	exit 1
fi
echo "$timeout" > "$file"
echo "$adapter supervision_timeout $(cat "$file") (x 10 ms)"
