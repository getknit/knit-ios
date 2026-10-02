# Devices and radios

- **Adapters go by address, never by index.** The Linux peer's adapter is the Actions ATS2851 dongle at
  `F0:0D:00:00:00:02`. The maintainer's own adapter, with live connections, is the Intel at `A0:00:00:00:00:01`. The
  kernel numbers them in the order `btusb` binds them, which follows USB ports and replugs: the ATS2851 was `hci1`
  until a reboot on 2026-10-01 made it `hci0`. These rules and the notes still call the ATS2851 `hci1` and the
  maintainer's adapter `hci0`, as names for the two. knit-peer, `interop.py` and `scripts/knit-hci.sh` find each by
  its address, and knit-peer exits when no adapter has the address it was given. Before typing an index by hand, ask
  `scripts/knit-hci.sh name`.
- **`hci0` needs a go-ahead, every session.** The maintainer allows it for tests that need two adapters, such as
  the relay line (`interop.py relay`), and for runs where a phone dials the peer or reads its GATT payload, which
  `hci1` cannot take: it accepts no incoming LE connection. The peer runs there only with `--shared-adapter`,
  which leaves every link it did not make alone, and nothing else on `hci0` changes: no supervision timeout, no
  power or pairing changes, no `sudo`.
- **Root on `hci1` goes through `scripts/knit-hci.sh`,** installed as `/usr/local/sbin/knit-hci`, which sudoers lets
  run without a password: `sudo knit-hci btmon …`, `sudo knit-hci hcitool …`, and `sudo knit-hci btmgmt` with its
  commands on standard input, after a `select` the script writes. A one-shot `btmgmt --index N <command>` runs before
  the index applies and lands on `hci0` (`linux-peer.md`, "What the ATS2851 showed"). Never run those tools as root
  with an index of your own.
- **Ask before driving a physical phone, every session.** That covers installing, launching, adb broadcasts,
  the iPhone's bridge over USB or Wi-Fi (`interop.py iphone` and `bridge`, pinning included) and UI automation,
  on Android or iPhone. A go-ahead does not carry over to a new task or conversation.
- **An emulator is fair game.** knit-next's `scripts/emulator-ble-mesh.sh` gives an Android emulator a real
  radio by passing the Edimax BT-8500 dongle through, which it finds by USB id. The Edimax was `hci1` until
  2026-09-29 and is unplugged; plug it back in for the emulator, which can then run beside the peer.
- **Driving Android once authorized** goes through knit-next's debug bridge (`.agents/context/debug-bridge.md`
  in knit-next).
