#!/bin/sh
# Runs bluetoothd without its battery plugin, for iPhone runs against the Linux peer (.agents/context/linux-peer.md,
# "What the iPhone showed"). Once a link to an iPhone is up, bluetoothd reads the iPhone's Battery Service, which
# iOS guards with encryption, so bluetoothd asks the iPhone to pair; left unanswered, the kernel drops the link 30 s
# later. Needs root, and restarts bluetoothd, which drops every Bluetooth connection on the machine for a moment:
#
#     sudo scripts/bluetoothd-no-battery.sh          # install the override and restart bluetoothd
#     sudo scripts/bluetoothd-no-battery.sh --undo   # remove it and restart bluetoothd
#
# It is one systemd drop-in for the whole daemon, so hci0's devices lose their battery levels while it is in place.

set -eu

dir=/etc/systemd/system/bluetooth.service.d
file=$dir/knit-no-battery.conf
daemon=/usr/libexec/bluetooth/bluetoothd

if [ "$(id -u)" != 0 ]; then
	echo "run it as root: sudo $0 ${1:-}" >&2
	exit 1
fi

case ${1:-} in
	--undo)
		rm -f "$file"
		rmdir "$dir" 2>/dev/null || true
		;;
	"")
		mkdir -p "$dir"
		cat > "$file" <<EOF
# Installed by knit-ios scripts/bluetoothd-no-battery.sh; remove with --undo.
[Service]
ExecStart=
ExecStart=$daemon --noplugin=battery
EOF
		;;
	*)
		echo "usage: $0 [--undo]" >&2
		exit 2
		;;
esac

systemctl daemon-reload
systemctl restart bluetooth
systemctl show bluetooth -p ExecStart --value | sed -n 's/.*argv\[\]=\([^;]*\);.*/bluetoothd runs: \1/p'
