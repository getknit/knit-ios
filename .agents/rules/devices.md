# Devices and radios

- **The Linux peer uses `hci1`,** an Actions ATS2851 dongle. `hci0` is the maintainer's own adapter, with live
  connections. knit-peer refuses it and exits when `hci1` is absent.
- **`hci0` needs a go-ahead, every session.** The maintainer allows it for tests that need two adapters, such as
  the relay line (`interop.py relay`), and for runs where a phone dials the peer or reads its GATT payload, which
  `hci1` cannot take: it accepts no incoming LE connection. The peer runs there only with `--shared-adapter`,
  which leaves every link it did not make alone, and nothing else on `hci0` changes: no supervision timeout, no
  power or pairing changes, no `sudo`.
- **Root on `hci1` is for `btmon -i hci1`, `btmgmt --index 1` and `hcitool -i hci1`,** which sudoers lets run
  without a password. Drive `btmgmt` interactively, with `select hci1` before anything else: a one-shot
  `btmgmt --index 1 <command>` runs before the index applies, so it lands on `hci0` (`linux-peer.md`, "What the
  ATS2851 showed").
- **Ask before driving a physical phone, every session.** That covers installing, launching, adb broadcasts,
  the iPhone's bridge over USB or Wi-Fi (`interop.py iphone` and `bridge`, pinning included) and UI automation,
  on Android or iPhone. A go-ahead does not carry over to a new task or conversation.
- **An emulator is fair game.** knit-next's `scripts/emulator-ble-mesh.sh` gives an Android emulator a real
  radio by passing the Edimax BT-8500 dongle through, which it finds by USB id. The Edimax was `hci1` until
  2026-09-29 and is unplugged; plug it back in for the emulator, which can then run beside the peer.
- **Driving Android once authorized** goes through knit-next's debug bridge (`.agents/context/debug-bridge.md`
  in knit-next).
