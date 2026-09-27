# Devices and radios

- **The Linux peer uses `hci1`.** `hci0` is the maintainer's own adapter, with live connections. knit-peer
  refuses it and exits when `hci1` is absent.
- **`hci0` needs a go-ahead, every session.** The maintainer allows it for tests that need two adapters, such as
  the relay line (`interop.py relay`), and for iPhone runs, which stall on `hci1`'s 23-byte fragments. The peer runs there only with `--shared-adapter`, which leaves every
  link it did not make alone, and nothing else on `hci0` changes: no supervision timeout, no power or pairing
  changes, no `sudo`.
- **Ask before driving a physical phone, every session.** That covers installing, launching, adb broadcasts
  and UI automation, on Android or iPhone. A go-ahead does not carry over to a new task or conversation.
- **An emulator is fair game.** knit-next's `scripts/emulator-ble-mesh.sh` gives an Android emulator a real
  radio by passing the Edimax BT-8500 dongle through. That is the same dongle `hci1` uses, so the emulator
  and the Linux peer cannot share it: hand it back (`emulator-ble-mesh.sh down`) before starting the peer.
- **Driving Android once authorized** goes through knit-next's debug bridge (`.agents/context/debug-bridge.md`
  in knit-next).
