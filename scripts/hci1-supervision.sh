#!/bin/sh
# Raises the LE supervision timeout of the connections Knit's adapters dial to 5 s, Android's own, from the kernel's
# 420 ms (.agents/context/linux-peer.md, "What P4 found"): dongles A and B, the nRF52840s, and the ATS2851 they
# replaced. Needs root, and lasts until the adapter is replugged or the machine reboots:
#
#     sudo scripts/hci1-supervision.sh              # set it now, on each of them that is plugged in
#     scripts/hci1-supervision.sh --udev-rule       # print udev rules that set it on every plug-in
#
# It touches only adapters with those addresses, whatever index the kernel gave them, and never the maintainer's.

set -eu

# Dongle A, dongle B and the ATS2851, in debugfs' lower case.
knit_addresses="c0:ff:ee:00:00:0a c0:ff:ee:00:00:0b f0:0d:00:00:00:02"
# Units of 10 ms.
timeout=500

if [ "${1:-}" = "--udev-rule" ]; then
	script=$(readlink -f "$0")
	# The USB ids of firmware/knit-hci (Zephyr's HCI sample id) and of the ATS2851; the script still checks the
	# address before it writes anything.
	for ids in 2fe3:000b 10d7:b012; do
		printf 'ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", ATTRS{idVendor}=="%s", ATTRS{idProduct}=="%s", RUN+="%s %%k"\n' \
			"${ids%%:*}" "${ids#*:}" "$script"
	done
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

is_knit() {
	for known in $knit_addresses; do
		[ "$1" = "$known" ] && return 0
	done
	return 1
}

# Sets one adapter's timeout, once the kernel has added its debugfs files and if its address is Knit's.
raise() {
	adapter=$1
	case $adapter in
		hci[0-9]*) ;;
		*) echo "not an adapter: $adapter" >&2; return 1 ;;
	esac
	# The kernel adds these files once the adapter is set up, which can be a moment after udev hears of it.
	file=/sys/kernel/debug/bluetooth/$adapter/supervision_timeout
	tries=0
	while [ ! -e "$file" ] && [ "$tries" -lt 30 ]; do
		sleep 0.5
		tries=$((tries + 1))
	done
	address=$(address_of "$adapter")
	if ! is_knit "$address"; then
		echo "refusing $adapter: its address $address is not one of Knit's" >&2
		return 1
	fi
	echo "$timeout" > "$file"
	echo "$adapter ($address) supervision_timeout $(cat "$file") (x 10 ms)"
}

# udev names the adapter it saw; by hand, every adapter with one of Knit's addresses.
if [ -n "${1:-}" ]; then
	raise "$1"
	exit
fi
found=0
for dir in /sys/kernel/debug/bluetooth/hci*; do
	name=${dir##*/}
	if is_knit "$(address_of "$name")"; then
		raise "$name"
		found=1
	fi
done
if [ "$found" = 0 ]; then
	echo "no adapter has one of Knit's addresses: $knit_addresses" >&2
	exit 1
fi
