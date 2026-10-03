#!/bin/sh
# Builds firmware/knit-hci, the Bluetooth LE controller knit-peer runs on, for a Nordic nRF52840 Dongle (PCA10059),
# and flashes it over USB through the dongle's Open DFU Bootloader. No debug probe needed.
#
#   scripts/dongle-firmware.sh build             # build/zephyr/zephyr.hex and knit-hci.zip under .build/knit-hci
#   scripts/dongle-firmware.sh flash [/dev/ttyACMn]
#
# To flash, press the dongle's sideways reset button: the red LED fades in and out, and the bootloader shows up as
# 1915:521f with a ttyACM port. The setup, once (.agents/context/linux-peer.md, "The nRF52840 dongles"):
#
#   python3 -m venv ~/zephyrproject/.venv && ~/zephyrproject/.venv/bin/pip install west==1.5.0
#   cd ~/zephyrproject && .venv/bin/west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.4-branch .
#   git -C zephyr checkout f8523a9c66e0d1a86e16d9037e0284bb36dbdfbb
#   .venv/bin/west config manifest.project-filter -- '-.*,+hal_nordic,+cmsis,+cmsis_6'
#   .venv/bin/west update --narrow -o=--depth=1
#   .venv/bin/pip install -r zephyr/scripts/requirements-base.txt
#   # Zephyr SDK 1.0.1: the minimal bundle in ~/zephyr-sdk-1.0.1, its arm-zephyr-eabi toolchain under gnu/,
#   # then ./setup.sh -c. nrfutil 8 from Nordic in ~/.local/bin, then: nrfutil install nrf5sdk-tools
set -eu

# v4.4-branch, 208 commits past v4.4.2: v4.4.2 copies every packet to the host into a 64-byte USB buffer, which the
# 251-byte ACL and 255-byte events below overflow, and the controller stops answering. ea86c1235c fixed it on the
# branch on 2026-09-04. Move to v4.4.3 once it is tagged.
ZEPHYR_COMMIT=f8523a9c66e0d1a86e16d9037e0284bb36dbdfbb
WORKSPACE=${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
BOARD=nrf52840dongle/nrf52840
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/.build/knit-hci

WEST=$WORKSPACE/.venv/bin/west

build() {
	found=$(git -C "$WORKSPACE/zephyr" rev-parse HEAD 2>/dev/null || echo unknown)
	if [ "$found" != "$ZEPHYR_COMMIT" ]; then
		echo "$WORKSPACE/zephyr is at $found, not $ZEPHYR_COMMIT" >&2
		exit 1
	fi
	(cd "$WORKSPACE" && CMAKE_BUILD_PARALLEL_LEVEL=8 nice "$WEST" build -p -b "$BOARD" -d "$OUT" "$ROOT/firmware/knit-hci")
	# The Open Bootloader takes an nRF5 SDK DFU package, and checks no signature.
	nrfutil nrf5sdk-tools pkg generate --hw-version 52 --sd-req=0x00 \
		--application "$OUT/zephyr/zephyr.hex" --application-version 1 "$OUT/knit-hci.zip"
}

case "${1:-}" in
build) build ;;
flash)
	[ -f "$OUT/knit-hci.zip" ] || build
	nrfutil nrf5sdk-tools dfu usb-serial -pkg "$OUT/knit-hci.zip" -p "${2:-/dev/ttyACM0}"
	;;
*)
	echo "usage: $0 build | flash [/dev/ttyACMn]" >&2
	exit 2
	;;
esac
