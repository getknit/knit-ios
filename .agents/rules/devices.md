# Devices and radios

- **Adapters go by address, never by index.** The Linux peer's adapters are two nRF52840 dongles running
  `firmware/knit-hci`: dongle A at `$KNIT_ADAPTER_A`, knit-peer's default, and dongle B at `$KNIT_ADAPTER_B`,
  a run's second peer. The maintainer's own adapter, with live connections, is an Intel whose address
  `$KNIT_ADAPTER_RESERVED` names, and knit-peer refuses it unless shared. The lab's addresses live in a
  gitignored `.private/lab.env`, which `interop.py` and the scripts read; knit-peer reads them from its
  environment. The kernel numbers adapters in the order `btusb` binds them, which follows USB ports and
  replugs. `interop.py` still calls dongle A `hci1` and dongle B `hci0`, as role names. knit-peer,
  `interop.py` and `scripts/knit-hci.sh` find each by its address, and knit-peer exits when no adapter has the
  address it was given. Before typing an index by hand, ask `scripts/knit-hci.sh [a|b] name`.
- **The maintainer's Intel needs a go-ahead, every session.** No run needs it since dongle B took the second
  peer's place on 2026-10-03. With a go-ahead, the peer runs there only with `--adapter-address
  "$KNIT_ADAPTER_RESERVED" --shared-adapter`, which leaves every link it did not make alone, and nothing else
  on it changes: no supervision timeout, no power or pairing changes, no `sudo`.
- **Root on Knit's adapters goes through `scripts/knit-hci.sh`,** installed as `/usr/local/sbin/knit-hci`,
  which sudoers lets run without a password. It reads the adapters' addresses from the root-owned
  `/etc/knit-hci.conf` (lines of `a ADDRESS`, `b ADDRESS`, `ats2851 ADDRESS`), never from the caller. Its
  first argument picks dongle `a` (the default), `b` or the retired `ats2851`, and it never selects another
  address: `sudo knit-hci btmon …`, `sudo knit-hci b hcitool …`, and `sudo knit-hci btmgmt` with its commands
  on standard input, after a `select` the script writes. A one-shot `btmgmt --index N <command>` runs before
  the index applies and lands on `hci0` (`linux-peer.md`, "What the ATS2851 showed"). Never run those tools as
  root with an index of your own.
- **Flashing a dongle is fair game once it is in its bootloader.** Only the maintainer can put it there, with its
  reset button (`linux-peer.md`, "The nRF52840 dongles"). A dongle in its bootloader is no adapter, so a run on it
  waits until it is flashed and back.
- **Ask before driving a physical phone, every session.** That covers installing, launching, adb broadcasts,
  the iPhone's bridge over USB or Wi-Fi (`interop.py iphone` and `bridge`, pinning included) and UI automation,
  on Android or iPhone. A go-ahead does not carry over to a new task or conversation.
- **An emulator is fair game.** knit-next's `scripts/emulator-ble-mesh.sh` gives an Android emulator a real
  radio by passing the Edimax BT-8500 dongle through, which it finds by USB id. The Edimax was `hci1` until
  2026-09-29 and is unplugged; plug it back in for the emulator, which can then run beside the peer.
- **Driving Android once authorized** goes through knit-next's debug bridge (`.agents/context/debug-bridge.md`
  in knit-next).
