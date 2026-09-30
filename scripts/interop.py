#!/usr/bin/env python3
"""Checklist L against an Android phone running a debug build of Knit: knit-peer on hci1 on one side, the phone
driven through knit-next's debug bridge on the other (.agents/specs/mvp.md, .agents/context/linux-peer.md).

    scripts/interop.py check   --device SERIAL [--order phone-dials|peer-dials] [--radio-profile android|ios]
                                [--blank-name] [--expect-avatar] [--mac]
    scripts/interop.py refusal --device SERIAL [--seconds 120]
    scripts/interop.py replace --device SERIAL
    scripts/interop.py soak    --device SERIAL [--minutes 60] [--per-minute 20] [--extras] [--mac]
    scripts/interop.py relay   --device SERIAL [--radio-profile ios|android]
    scripts/interop.py iphone  --device SERIAL [--udid UDID] [--skip-offline]
    scripts/interop.py iphone-relay --device SERIAL [--udid UDID]
    scripts/interop.py iphone-peer [--order iphone-below|iphone-above] [--skip-offline] [--udid UDID]
    scripts/interop.py iphone-forgets [--stages dialed,quiet,accepted] [--udid UDID]
    scripts/interop.py iphone-soak --device SERIAL [--peer] [--extras] [--udid UDID] [--minutes 60] [--per-minute 20]
    scripts/interop.py iphone-wake [--sender phone|peer] [--device SERIAL] [--expect-wakes] [--udid UDID] [--minutes 10]
    scripts/interop.py iphone-reboot [--restart] [--locked 120] [--closed 60] [--skip-relaunch] [--udid UDID]
    scripts/interop.py iphone-rings [--udid UDID]
    scripts/interop.py android-reads --device SERIAL [--order peer-below|peer-above] [--link-timeout 180]
    scripts/interop.py android-forgets --device SERIAL [--link-timeout 180] [--quiet-timeout 600]
    scripts/interop.py android-rings --device SERIAL [--link dialed|accepted] [--converge-timeout 600] [--arrival-timeout 600]
    scripts/interop.py iphone-scan [--udid UDID] [--window 30] [--away-window 60] [--first android|ios]
    scripts/interop.py bridge  [--udid UDID] [--watch SECONDS] [COMMAND_JSON ...]

`iphone` runs MVP items 2 to 6 between an iPhone and the Android phone, driving the iPhone through a debug build's
bridge over USB (ADR 2026-09.kwa8), and the phone's Requests screen for a pair that has never talked; `iphone-peer`
runs the same items between the iPhone and the peer; `iphone-relay` runs MVP item 7's line through the iPhone; `iphone-soak` is item
11's hour on the iPhone, with the peer as a third author when asked; `iphone-wake` is item 9's wake test, with someone
to lock the iPhone and unlock it again; `iphone-reboot` is item 1's relaunch and reboot, with someone to close Knit and
unlock the iPhone; `iphone-scan` is P8's scan-filter check, with someone to do the same; `bridge`
sends that bridge commands by hand and prints what comes back. `iphone-rings` checks the doorbell rings an iPhone
sends, and `android-rings` those an Android phone sends, with companion change A4. `android-reads` is companion change
A3's device gate: an Android phone reads the peer's GATT payload and dials it, or is dialed, by the id order.

`--mac` runs the peer on the Mac Mini instead of hci1, on CoreBluetooth, the iPhone's own radio: checklist M (ADR
2026-09.vcdk). It always runs the `ios` profile, in the Mac's desktop session through `scripts/mac-peer.sh`, and the
scan that finds the nodes to refuse still runs here.

Driving a physical phone needs the maintainer's go-ahead for the session (.agents/rules/devices.md). Nothing here
installs or launches anything: it wakes the phone, asks its bridge to scan, send and report, and reads the answers.
`iphone` also brings Knit forward at the phone's Requests screen and taps Accept there, through uiautomator.
`relay` also runs a second peer on hci0, the maintainer's own adapter, and `iphone-relay`, `iphone-peer` and
`iphone-soak --peer` run their one peer there; hci0 needs its own go-ahead. The peer runs there with --shared-adapter, so it never drops a link it
did not make.

Each step prints one JSON line, {"step": ..., "ok": ..., ...}, and the run ends with a summary line. The exit code
is the number of failed steps.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# KNIT_PEER runs another build of the peer, such as one from a commit whose checks passed.
PEER = Path(os.environ.get("KNIT_PEER") or ROOT / ".build" / "out" / "Products" / "Debug-linux-x86_64" / "knit-peer")
PACKAGE = "app.getknit.knit"
INSTANCE = "interop"
# The maintainer's own adapter, for `relay` only, shared with the devices already on it (.agents/rules/devices.md).
HCI0 = ["--adapter", "hci0", "--adapter-address", "A0:00:00:00:00:01", "--shared-adapter"]
# The Mac that runs the peer with --mac, and its mirror of this tree (scripts/mac.sh).
MAC_HOST = "mac.example"
MAC_MIRROR = "source/knit-ios-mirror"
# Set by --mac: the peer runs on the Mac, on CoreBluetooth.
ON_MAC = False
# Diagnostic knobs for the L2CAP receive MTU and the largest SDU written, set with --receive-mtu and --send-mtu.
RECEIVE_MTU = ""
SEND_MTU = ""
# Android's caps: the SeenSet's entries, and custody's frames overall.
SEEN_CAP = 4096
CUSTODY_CAP = 1000


class Phone:
    """The Android side, through `adb shell am broadcast` to the debug bridge."""

    def __init__(self, serial: str) -> None:
        self.serial = serial

    def shell(self, command: str, timeout: float = 30) -> str:
        """Runs `command` on the phone. A network adb link can go stale while the phone sleeps; one stalled command
        reconnects it and tries again."""
        for attempt in range(2):
            try:
                result = subprocess.run(
                    ["adb", "-s", self.serial, "shell", command], capture_output=True, text=True, timeout=timeout, check=False
                )
                return result.stdout
            except subprocess.TimeoutExpired:
                if attempt or ":" not in self.serial:
                    raise
                self.reconnect()
        return ""

    def reconnect(self) -> None:
        """Drops and remakes this host's adb connection to the phone; nothing on the phone changes."""
        subprocess.run(["adb", "disconnect", self.serial], capture_output=True, timeout=20, check=False)
        subprocess.run(["adb", "connect", self.serial], capture_output=True, timeout=30, check=False)

    def bridge(self, action: str, **extras: str | int) -> dict:
        parts = [f"am broadcast -a {PACKAGE}.debug.{action} -p {PACKAGE}"]
        for key, value in extras.items():
            kind = "--ei" if isinstance(value, int) else "--es"
            parts.append(f"{kind} {key} {shlex.quote(str(value))}")
        command = " ".join(parts)
        output = self.shell(command)
        match = re.search(r'data="(.*)"\s*$', output.strip(), re.S)
        if not match and ":" in self.serial:
            # A network adb link sometimes answers with nothing at all; reconnect and ask once more.
            self.reconnect()
            output = self.shell(command)
            match = re.search(r'data="(.*)"\s*$', output.strip(), re.S)
        if not match:
            raise RuntimeError(f"no bridge reply to {action}: {output.strip()[:200]}")
        # The bridge writes its JSON between the quotes as it is, unescaped.
        return json.loads(match.group(1))

    def wake(self) -> None:
        """Keeps the phone interactive so its scanner runs at its balanced cadence, and nudges a scan."""
        self.shell("input keyevent KEYCODE_WAKEUP")
        self.bridge("HEAL")

    def state(self, conversation: str | None = None, limit: int = 20) -> dict:
        return self.bridge("STATE", conv=conversation, limit=limit) if conversation else self.bridge("STATE")

    def send(self, text: str, conversation: str = "nearby") -> dict:
        return self.bridge("SEND", text=text, conv=conversation)

    def open_route(self, route: str) -> None:
        """Brings Knit to the front at `route`, the deep link a notification's tap takes (`MainActivity.EXTRA_ROUTE`)."""
        self.shell(f"am start -n {PACKAGE}/.MainActivity --es {PACKAGE}.NOTIF_ROUTE {route}")

    def tagged(self, tag: str) -> tuple[int, int] | None:
        """The centre of the element on screen that Compose tagged `tag`, or None. Knit's root turns tags into
        resource-ids, which uiautomator reports bare or under the package (knit-next's debug-bridge.md). A dump can fail
        while the screen animates, so a failed one is tried again."""
        for _ in range(3):
            dump = self.shell("uiautomator dump /sdcard/knit-ui.xml >/dev/null && cat /sdcard/knit-ui.xml", timeout=40)
            try:
                root = ET.fromstring(dump[dump.find("<hierarchy") : dump.rfind(">") + 1])
            except ET.ParseError:
                time.sleep(1)
                continue
            for node in root.iter("node"):
                if node.get("resource-id") in (tag, f"{PACKAGE}:id/{tag}"):
                    left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds", "")))
                    return (left + right) // 2, (top + bottom) // 2
            return None
        raise RuntimeError("uiautomator dumped no screen")

    def tap(self, point: tuple[int, int]) -> None:
        self.shell(f"input tap {point[0]} {point[1]}")


class Node:
    """What knit-peer and the iPhone's bridge share: JSON lines in, replies and events out (ADR 2026-09.kwa8). Every
    line is kept, so a wait finds one that came before it, and two threads can wait at once."""

    label = "the node"

    def __init__(self) -> None:
        self.seen: list[dict] = []
        self.arrived = threading.Condition()
        self.writing = threading.Lock()
        self.node_id = ""

    def _arrive(self, raw: str) -> None:
        try:
            line = json.loads(raw)
        except json.JSONDecodeError:
            return
        line["_at"] = time.monotonic()
        with self.arrived:
            self.seen.append(line)
            self.arrived.notify_all()

    def _write(self, line: str) -> None:
        raise NotImplementedError

    def wait(self, match, timeout: float) -> dict:
        """The first line, already seen or still to come, that matches; raises TimeoutError otherwise."""
        deadline = time.monotonic() + timeout
        checked = 0
        with self.arrived:
            while True:
                for line in self.seen[checked:]:
                    if match(line):
                        return line
                checked = len(self.seen)
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(f"no matching line from {self.label}")
                self.arrived.wait(min(left, 1))

    def lines(self, match) -> list[dict]:
        """Every line so far that matches."""
        with self.arrived:
            return [line for line in self.seen if match(line)]

    def command(self, timeout: float = 10, **fields) -> dict:
        tag = secrets.token_hex(4)
        with self.writing:
            self._write(json.dumps({**fields, "tag": tag}) + "\n")
        return self.wait(lambda line: line.get("tag") == tag, timeout)


class Peer(Node):
    """knit-peer as a child process: JSON lines in on stdin, replies and events out on stdout.

    Every Knit node in range other than the phone under test is refused a link as soon as the peer is up, before
    the 12 s promotion dwell lets either side dial: the go-ahead covers one phone, and the rest of the mesh should
    not carry the run's traffic."""

    label = "knit-peer"

    def __init__(
        self,
        profile: str,
        name: str,
        refuse: set[str],
        log_level: str,
        rssi_floor: int | None,
        instance: str = INSTANCE,
        adapter: list[str] | None = None,
        log_path: Path | None = None,
        never_sight: set[str] | None = None,
        gatt_payload: bool = True,
        gatt_reads: bool = True,
    ) -> None:
        super().__init__()
        # knit-peer's test switches: nodes it never takes as sighted, so it never dials them and admits their dials
        # unsighted; and, in the `ios` profile, a doorbell served without the payload, so an A3 phone never sights it.
        self.never_sight = never_sight or set()
        self.gatt_payload = gatt_payload
        self.gatt_reads = gatt_reads
        self.instance = instance
        self.profile = profile
        self.name = name
        self.refuse = refuse
        self.log_level = log_level
        self.rssi_floor = rssi_floor
        self.adapter = adapter or []
        self.log_path = log_path or ROOT / ".build" / ("interop-peer.log" if instance == INSTANCE else f"interop-{instance}.log")
        self.process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        arguments = ["--instance", self.instance, "--radio-profile", self.profile, "--name", self.name, "--log", self.log_level]
        if self.rssi_floor is not None:
            arguments += ["--rssi-floor", str(self.rssi_floor)]
        if self.never_sight:
            arguments += ["--never-sight", ",".join(sorted(self.never_sight))]
        if not self.gatt_payload:
            arguments.append("--no-gatt-payload")
        if not self.gatt_reads:
            arguments.append("--no-gatt-reads")
        if ON_MAC:
            # The adapter and the MTU knobs are BlueZ's; CoreBluetooth has one radio and picks its own MTU.
            command = on_mac("run", arguments)
        else:
            command = [str(PEER), "run", *arguments, *self.adapter]
            if RECEIVE_MTU:
                command += ["--receive-mtu", RECEIVE_MTU]
            if SEND_MTU:
                command += ["--send-mtu", SEND_MTU]
        log = open(self.log_path, "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        ready = self.wait(lambda line: line.get("event") == "ready", 20)
        self.node_id = ready["nodeId"]
        for node in sorted(self.refuse):
            self.command(cmd="deny-link", peer=node)

    def log_mark(self) -> int:
        """Where the peer's log file ends now, for `log_since`."""
        return self.log_path.stat().st_size if self.log_path.exists() else 0

    def log_since(self, mark: int) -> list[str]:
        """The messages the peer logged after `mark`."""
        with open(self.log_path, encoding="utf-8") as log:
            log.seek(mark)
            lines = log.read().splitlines()
        messages = []
        for line in lines:
            try:
                messages.append(json.loads(line).get("message", ""))
            except json.JSONDecodeError:
                continue
        return messages

    def _read(self) -> None:
        assert self.process and self.process.stdout
        for raw in self.process.stdout:
            self._arrive(raw)

    def _write(self, line: str) -> None:
        assert self.process and self.process.stdin
        self.process.stdin.write(line)
        self.process.stdin.flush()

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            try:
                self.command(cmd="quit")
            except (TimeoutError, BrokenPipeError):
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
        self.process = None
        with self.arrived:
            self.seen.clear()


class IPhone(Node):
    """Knit on an iPhone over USB: a debug build's bridge (ADR 2026-09.kwa8), reached through `iproxy`. It speaks
    knit-peer's protocol, so a run drives it as it drives the peer. Knit has to be open on the phone, since nothing
    here can launch it, and `stop` closes the connection and leaves Knit and its mesh running."""

    label = "the iPhone's bridge"
    DEVICE_PORT = 5648

    def __init__(self, udid: str | None = None) -> None:
        super().__init__()
        self.udid = udid or first_usb_iphone()
        self.proxy: subprocess.Popen[bytes] | None = None
        self.socket: socket.socket | None = None
        self.name = ""
        # When the bridge closed without `stop` asking: Knit crashed, or iOS suspended it and shut its sockets.
        self.lost: float | None = None
        self.stopping = False

    def start(self) -> None:
        self.lost = None
        self.stopping = False
        port = free_port()
        self.proxy = subprocess.Popen(
            ["iproxy", f"{port}:{self.DEVICE_PORT}", "-u", self.udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        deadline = time.monotonic() + 10
        while self.socket is None:
            try:
                self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.2)
        self.socket.settimeout(None)
        threading.Thread(target=self._read, daemon=True).start()
        try:
            ready = self.wait(lambda line: line.get("event") == "ready", 15)
        except TimeoutError as error:
            self.stop()
            raise TimeoutError("the iPhone's bridge did not answer: open Knit, a debug build, on the phone") from error
        self.node_id = ready["nodeId"]
        self.name = self.command(cmd="status")["name"]

    def _read(self) -> None:
        assert self.socket
        with self.socket.makefile("r", encoding="utf-8") as stream:
            try:
                for raw in stream:
                    self._arrive(raw)
            except OSError:
                pass
        if not self.stopping:
            self.lost = time.monotonic()

    def _write(self, line: str) -> None:
        assert self.socket
        self.socket.sendall(line.encode())

    def stop(self) -> None:
        self.stopping = True
        if self.socket:
            try:
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.socket.close()
            self.socket = None
        if self.proxy:
            self.proxy.terminate()
            self.proxy.wait(timeout=10)
            self.proxy = None
        with self.arrived:
            self.seen.clear()


def first_usb_iphone() -> str:
    """The first iPhone usbmuxd lists over USB."""
    result = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, check=False)
    udids = result.stdout.split()
    if not udids:
        raise RuntimeError("no iPhone on USB (idevice_id -l lists none)")
    return udids[0]


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Run:
    def __init__(self) -> None:
        self.failed = 0
        self.steps = 0
        self.results: list[dict] = []

    def step(self, name: str, check, **context) -> object:
        self.steps += 1
        started = time.monotonic()
        try:
            detail = check()
            result = {"step": name, "ok": True, "seconds": round(time.monotonic() - started, 1), **context, **(detail or {})}
            self.results.append(result)
            print(json.dumps(result))
            return detail
        except Exception as error:  # noqa: BLE001 - every failure is reported, then the run goes on
            self.failed += 1
            result = {"step": name, "ok": False, "seconds": round(time.monotonic() - started, 1), "error": str(error), **context}
            self.results.append(result)
            print(json.dumps(result))
            return None
        finally:
            sys.stdout.flush()


def poll(check, timeout: float, every: float = 2):
    deadline = time.monotonic() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise TimeoutError("timed out")
        time.sleep(every)


def in_range(seconds: int = 20) -> dict[str, dict]:
    """Every Knit node a quiet scan hears, by node id, with what it advertised: its flags, and the low byte of its
    capabilities, `ff` from Android and `9` from an iPhone or an `ios` peer."""
    result = subprocess.run([str(PEER), "scan", "--seconds", str(seconds), "--log", "debug"], capture_output=True, text=True, check=True)
    # The scan links any node BlueZ lists with the UUID and no service data to read its payload, so what it did is kept:
    # a link it left up keeps hci1 from advertising (`android-reads`' `hci1-idle`).
    with open(ROOT / ".build" / "interop-scan.log", "a", encoding="utf-8") as log:
        log.write(result.stderr)
    summary = json.loads(result.stdout.strip().splitlines()[-1])
    return {node["peer"]: node for node in summary["nodes"]}


def others_in_range(phone_id: str, seconds: int = 20) -> set[str]:
    """Every Knit node a quiet scan hears, bar the phone under test."""
    return set(in_range(seconds)) - {phone_id}


# FLAG_DIALS_GATT_PEERS, bit 1 of the advert's flags byte: the node reads GATT payloads, so it can find a node that
# advertises only the 0xFE30 UUID, and such a node waits for it to dial (ADR 2026-09.xzpt).
DIALS_GATT_PEERS = 0x02
# The low byte of the capabilities this port advertises (0x9), as the scan spells it; Android's builds send 0xFF.
IOS_ADVERT_CAPABILITIES = "9"


def androids(heard: dict[str, dict]) -> set[str]:
    """The nodes a scan heard that advertise as Android does. The scan does not say where a payload came from, so
    this goes by the capabilities' low byte, which only this port's nodes send as 0x9."""
    return {node for node, entry in heard.items() if entry.get("capabilities") != IOS_ADVERT_CAPABILITIES}


def on_mac(verb: str, arguments: list[str]) -> list[str]:
    """The Mac's knit-peer `verb` over ssh (scripts/mac-peer.sh): `run` goes to its desktop session, where macOS lets
    it use Bluetooth, with stdin and stdout still attached here."""
    return ["ssh", MAC_HOST, f"cd {MAC_MIRROR} && scripts/mac-peer.sh {verb} {shlex.join(arguments)}"]


def keygen(phone_id: str, order: str, others: set[str]) -> str:
    """An identity the phone dials, or that dials the phone, and that no other phone in range dials: this adapter
    cannot advertise while a peer is connected to it, so a refused phone dialing in would hide the peer from the
    phone under test. The larger id dials, so the peer sorts above every other phone, and below the phone when the
    phone should dial it."""
    above = max((node for node in others if node < phone_id or order == "peer-dials"), default=None)
    bounds = ["--below", phone_id] if order == "phone-dials" else ["--above", max(phone_id, above or phone_id)]
    if order == "phone-dials" and above:
        bounds += ["--above", above]
    arguments = [*bounds, "--instance", INSTANCE]
    command = on_mac("keygen", arguments) if ON_MAC else [str(PEER), "keygen", *arguments]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return json.loads(result.stdout.strip().splitlines()[-1])["nodeId"]


def link_up(peer: Peer, phone: Phone, phone_id: str, timeout: float = 180) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        phone.wake()
        try:
            return peer.wait(lambda line: line.get("event") == "link" and line.get("peer") == phone_id and line.get("up"), 20)
        except TimeoutError:
            if time.monotonic() > deadline:
                raise


def check(arguments: argparse.Namespace) -> int:
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    state = phone.state()
    phone_id = state["self"]["nodeId"]
    phone_name = state["self"]["name"]
    others = others_in_range(phone_id)
    peer_id = keygen(phone_id, arguments.order, others)
    print(
        json.dumps(
            {"run": "check", "phone": phone_id, "phoneName": phone_name, "peer": peer_id, "order": arguments.order, "refused": sorted(others)}
        )
    )
    # A blank name makes both sides fall back to the alias, which is how alias parity is seen over the air.
    name = "" if arguments.blank_name else f"knit-peer {nonce}"
    peer = Peer(arguments.radio_profile, name, others, arguments.peer_log, arguments.rssi_floor)
    peer.start()
    try:
        run.step("link", lambda: link_up(peer, phone, phone_id) and {})
        run.step(
            "profile-on-peer",
            lambda: {"name": peer.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 30)["displayName"]},
            expected=phone_name,
        )
        run.step(
            "profile-on-phone",
            lambda: poll(
                lambda: next((p for p in phone.state()["reachable"] if p["nodeId"] == peer_id and p["name"] == peer.name), None), 30
            ),
        )
        # A new link starts with the phone back-filling every frame our digest lacks, one record per write, and
        # anything the phone sends meanwhile queues behind it. MVP item 4 times a post over a live link, so the
        # timed steps wait for that sync to finish.
        run.step("custody-converges", lambda: _converges(peer, phone, 180))
        # The aliases as this port computes them, to hold against what the phone's own screens show.
        run.step("aliases", lambda: _aliases(peer, phone_id))
        # A phone with a photo pushes it as FILE records at link-up; the peer discards them and keeps the link.
        if arguments.expect_avatar:
            run.step("file-records-discarded", lambda: poll(lambda: _file_records(peer), 60))
        body = f"interop room from peer {nonce}"
        peer.command(cmd="room", text=body)
        run.step("room-peer-to-phone", lambda: poll(lambda: _has(phone.state("nearby"), body), 15) and {})
        body = f"interop room from phone {nonce}"
        phone.send(body)
        run.step("room-phone-to-peer", lambda: _latency(peer.wait(lambda line: line.get("event") == "message" and line.get("body") == body, 15)))
        body = f"interop dm from phone {nonce}"
        phone.send(body, conversation=peer_id)
        run.step("dm-phone-to-peer-is-a-request", lambda: _request(peer.wait(lambda line: line.get("event") == "message" and line.get("body") == body, 20)))
        peer.command(cmd="accept", conv=phone_id)
        body = f"interop dm from peer {nonce}"
        sent = peer.command(cmd="dm", to=phone_id, text=body)
        run.step(
            "dm-peer-to-phone-delivered",
            lambda: peer.wait(lambda line: line.get("event") == "delivered" and line.get("id") == sent.get("id"), 30) and {},
        )
        run.step("dm-peer-to-phone-shown", lambda: poll(lambda: _has(phone.state(peer_id), body), 15) and {})
        run.step(
            "dm-phone-to-peer-ticked",
            lambda: poll(lambda: _received(phone.state(peer_id), f"interop dm from phone {nonce}"), 30) and {},
        )
        run.step("custody-converges-again", lambda: _converges(peer, phone, 90))
        # Back-fill: a post made while the peer is away arrives once it links again (MVP item 6).
        peer.stop()
        body = f"interop backfill {nonce}"
        phone.send(body)
        peer.start()

        def backfilled() -> dict:
            link_up(peer, phone, phone_id)
            peer.wait(lambda line: line.get("event") == "message" and line.get("body") == body, 60)
            return {}

        run.step("backfill", backfilled)
    finally:
        peer.stop()
    print(json.dumps({"summary": "check", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone(arguments: argparse.Namespace) -> int:
    """MVP items 2 to 6 between the iPhone and an Android phone, both driven through their bridges, with Knit open on
    both. Item 2 wants both node id orders, so the run names the one this pair has. The iPhone dials a phone above it.
    A phone below it with companion change A3 sets FLAG_DIALS_GATT_PEERS, reads the iPhone's GATT payload and dials
    the iPhone, which waits for it; one without A3 cannot see the iPhone, which dials it and is admitted unsighted (A1).
    The run checks which side dialed each link against the phone's flag, from the phone's log, and the relink after
    item 6's stop and start is the first-link time for the order.

    The first DM between two phones is a message request only once. For a pair that has never talked, the run reads
    the request off the phone's Requests screen, which the bridge does not report, and taps Accept there, so it drives
    the phone's screen too. A pair that has talked before checks the replies alone. Item 6 stops the iPhone's mesh,
    which closes every link it has, not only the phone's."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    state = phone.state()
    phone_id = state["self"]["nodeId"]
    phone_name = state["self"]["name"]
    # Android's thread for the iPhone holds nothing yet, so no Accept, verified key or reply of the phone's makes it
    # accepted (`Conversations.isAccepted`), and the iPhone's first DM is a request.
    fresh = not phone.state(ios.node_id).get("messages")
    order = "iphone-above" if ios.node_id > phone_id else "iphone-below"
    print(
        json.dumps(
            {
                "run": "iphone",
                "iphone": ios.node_id,
                "iphoneName": ios.name,
                "phone": phone_id,
                "phoneName": phone_name,
                "order": order,
                "fresh": fresh,
            }
        )
    )
    phone.shell("logcat -c")
    try:
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
        run.step("dialer", lambda: _dialed_by(phone, ios, phone_id, order))
        run.step("profile-on-iphone", lambda: _ios_pinned(ios, phone_id, phone_name))
        run.step("profile-on-phone", lambda: _phone_pinned(phone, ios))
        body = f"interop room from iphone {nonce}"
        sent = ios.command(cmd="room", text=body)
        run.step("room-iphone-to-phone", lambda: _timed(lambda: _has(phone.state("nearby"), body), 15))
        run.step("room-iphone-ticked", lambda: _delivered(ios, sent, 30))
        body = f"interop room from phone {nonce}"
        phone.send(body)
        run.step("room-phone-to-iphone", lambda: _latency(ios.wait(lambda line: _message(line, body), 15)))
        run.step("room-phone-ticked", lambda: _timed(lambda: _received(phone.state("nearby"), body), 30))
        body = f"interop dm from iphone {nonce}"
        sent = ios.command(cmd="dm", to=phone_id, text=body)
        # Only the phone signs a receipt for a DM to it, so this is Android taking the iPhone's DM and receipting it.
        run.step("dm-iphone-to-phone-delivered", lambda: _delivered(ios, sent, 30))
        run.step("dm-iphone-to-phone-shown", lambda: _timed(lambda: _has(phone.state(ios.node_id), body), 15))
        if fresh:
            run.step("dm-iphone-to-phone-is-a-request", lambda: _phone_request(phone, ios.node_id))
            run.step("phone-accepts", lambda: _phone_accepts(phone, ios.node_id))
        body = f"interop dm from phone {nonce}"
        phone.send(body, conversation=ios.node_id)
        run.step("dm-phone-to-iphone", lambda: _latency(ios.wait(lambda line: _message(line, body), 20)))
        run.step("dm-phone-to-iphone-ticked", lambda: _timed(lambda: _received(phone.state(ios.node_id), body), 30))
        if fresh:
            # Item 5's replies flow both ways after Accept; the iPhone's first DM came before it.
            body = f"interop dm reply from iphone {nonce}"
            sent = ios.command(cmd="dm", to=phone_id, text=body)
            run.step("dm-iphone-reply-delivered", lambda: _delivered(ios, sent, 30))
        if not arguments.skip_offline:
            phone.shell("logcat -c")
            _offline(run, ios, phone, phone_id, nonce)
            run.step("relink-dialer", lambda: _dialed_by(phone, ios, phone_id, order))
        run.step("custody-converges", lambda: _converges(ios, phone, 180))
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _dialed_by(phone: Phone, ios: IPhone, phone_id: str, order: str) -> dict:
    """Which side dialed the last link between the phone and the iPhone, from the phone's log since it was last cleared:
    `bt connect ok` is a dial of the phone's own, and `bt accepted client` one it took. The phone dials only when the
    iPhone sorts below it and the phone's advert, as the iPhone sights it, sets FLAG_DIALS_GATT_PEERS."""
    flags = next((s["flags"] for s in ios.command(cmd="links")["sightings"] if s["peer"] == phone_id), None)
    expected = "phone" if order == "iphone-below" and flags is not None and flags & DIALS_GATT_PEERS else "iphone"
    lines = _phone_log(phone, ios.node_id)
    ends = [line for line in lines if line.startswith((f"bt connect ok {ios.node_id}", f"bt accepted client {ios.node_id} "))]
    if not ends:
        # A link already up when the run began left nothing in the cleared log.
        return {"dialer": None, "expected": expected, "phoneFlags": flags}
    dialer = "phone" if ends[-1].startswith("bt connect ok") else "iphone"
    if dialer != expected:
        raise RuntimeError(f"the {dialer} dialed; with the phone's flags at {flags} the {expected} should have: {ends[-2:]}")
    return {"dialer": dialer, "phoneFlags": flags}


def _offline(run: Run, ios: IPhone, other: Phone | Peer, other_id: str, nonce: str) -> None:
    """MVP item 6 both ways: while the iPhone's mesh is stopped, as if the two were apart, the other side writes the
    iPhone a room post and a DM, and the iPhone writes the same into its own store. All four arrive within 60 s of
    the next link."""
    ios.command(cmd="stop")
    room = f"interop offline room {nonce}"
    direct = f"interop offline dm {nonce}"
    if isinstance(other, Phone):
        other.send(room)
        other.send(direct, conversation=ios.node_id)
    else:
        other.command(cmd="room", text=room)
        other.command(cmd="dm", to=ios.node_id, text=direct)
    own_room = f"interop offline room from iphone {nonce}"
    own_direct = f"interop offline dm from iphone {nonce}"
    ios.command(cmd="room", text=own_room)
    ios.command(cmd="dm", to=other_id, text=own_direct)
    time.sleep(5)
    started = time.monotonic()
    ios.command(cmd="start")
    link = run.step("offline-relinks", lambda: _relinked(ios, other, other_id, started))
    if link is None:
        return
    linked_at = started + link["seconds"]
    for name, body in (("offline-room-arrives", room), ("offline-dm-arrives", direct)):
        run.step(name, lambda body=body: _arrives_after(ios, body, linked_at))
    for name, body, conversation in (
        ("offline-room-from-iphone-arrives", own_room, "nearby"),
        ("offline-dm-from-iphone-arrives", own_direct, ios.node_id),
    ):
        run.step(name, lambda body=body, conversation=conversation: _arrives_at(other, body, conversation, linked_at))


def iphone_wake(arguments: argparse.Namespace) -> int:
    """MVP item 9, and P8's first task: whether a DM wakes Knit while the iPhone is locked. With Knit open and linked
    to the sender, someone locks the iPhone. Once iOS suspends Knit, which the run sees as its bridge going quiet, the
    sender DMs it every minute. Knit sends a DM's receipt only once it has opened the DM, so a DM the sender sees
    delivered within its minute woke Knit. Then someone unlocks the iPhone and opens Knit, and the run reads when each
    DM arrived there. The link must hold throughout.

    Data on an open link does not wake a suspended Knit; a write to its doorbell does (.agents/context/linux-peer.md).
    `--sender peer` has knit-peer on hci0 send the DMs, ringing after each as its link manager does, and every DM
    must wake Knit. `--sender phone` has the Android phone send them. A build with companion change A4 (knit-next
    `feat/ble-doorbell`) rings the iPhone's doorbell too, and with `--expect-wakes` every DM must wake Knit, as with
    the peer, and the phone must have logged its rings. Without it the phone's DMs are only counted, for a build that
    predates A4, and the check is item 9's fallback: each arrives within 60 s of Knit opening."""
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    try:
        ios.start()
    except TimeoutError:
        print(json.dumps({"action": "open Knit"}), flush=True)
        _reopened(ios, arguments.lock_wait)
    sender: _PhoneSender | _PeerSender
    if arguments.sender == "peer":
        sender = _PeerSender(ios, arguments, nonce)
    else:
        sender = _PhoneSender(Phone(arguments.device), ios)
    expect_wakes = arguments.sender == "peer" or arguments.expect_wakes
    print(
        json.dumps(
            {
                "run": "iphone-wake",
                "sender": arguments.sender,
                "from": sender.node_id,
                "iphone": ios.node_id,
                "minutes": arguments.minutes,
                "expectWakes": expect_wakes,
            }
        )
    )
    try:
        if isinstance(sender, _PhoneSender) and arguments.expect_wakes:
            run.step("phone-build-rings", lambda: _rings_doorbells(sender.phone))
        try:
            run.step("link", lambda: sender.link(ios))
            print(json.dumps({"action": "lock the iPhone"}), flush=True)
            run.step("iphone-suspended", lambda: _suspended(ios, arguments.lock_wait))
        finally:
            ios.stop()
        sender.begin()
        sent = _wake_window(sender, nonce, arguments.minutes)
        ticks = [dm["tickedAfter"] for dm in sent]
        woke = [tick for tick in ticks if tick is not None and tick <= 60]
        if expect_wakes:
            run.step("dms-woke-knit", lambda: _all_woke(len(woke), ticks))
            run.step(f"{arguments.sender}-rang", sender.rang)
        else:
            run.step("dms-that-woke-knit", lambda: {"count": len(woke), "of": len(sent), "tickedAfter": ticks})
        run.step("link-held", lambda: sender.held(sum(dm["linkGone"] for dm in sent)))
        print(json.dumps({"action": "unlock the iPhone and open Knit"}), flush=True)
        opened = run.step("knit-opened", lambda: _reopened(ios, arguments.unlock_wait))
        if opened is not None:
            try:
                run.step("dms-arrived", lambda: _arrivals(ios, sender.node_id, sent, opened["wall"]))
                run.step("dms-ticked-after-opening", lambda: _timed(lambda: _all_ticked(sender, sent), 60))
                run.step("link-held-on-iphone", lambda: _ios_still_linked(ios, sender.node_id))
            finally:
                ios.stop()
    finally:
        sender.stop()
    print(json.dumps({"summary": "iphone-wake", "steps": run.steps, "failed": run.failed}))
    return run.failed


class _PhoneSender:
    """The Android phone sends the wake test's DMs, through knit-next's debug bridge."""

    def __init__(self, phone: Phone, ios: IPhone) -> None:
        self.phone = phone
        self.ios_id = ios.node_id
        self.node_id = phone.state()["self"]["nodeId"]

    def link(self, ios: IPhone) -> dict:
        return _ios_linked(ios, self.phone, self.node_id)

    def begin(self) -> None:
        self.phone.shell("logcat -c")

    def send(self, body: str) -> None:
        self.phone.shell("input keyevent KEYCODE_WAKEUP")
        self.phone.send(body, conversation=self.ios_id)

    def look(self) -> tuple[set[str], bool] | None:
        """The DMs the phone shows delivered, and whether the iPhone is among its links; None if it did not answer."""
        try:
            state = self.phone.state(self.ios_id, limit=50)
        except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError):
            return None
        ticked = {message["body"] for message in state.get("messages", []) if message.get("received")}
        return ticked, any(peer["nodeId"] == self.ios_id for peer in state.get("reachable", []))

    def held(self, gone: int) -> dict:
        """The phone listed the iPhone among its links at every look, and logged no link down for it."""
        downs = _phone_log(self.phone, f"link down: {self.ios_id}")
        if downs or gone:
            raise RuntimeError(f"the link went down: {gone} looks without it, {downs[:3]}")
        return {}

    def rang(self) -> dict:
        """The phone rang the iPhone's doorbell while it was locked: the rings it logged since ``begin`` cleared its log."""
        return _phone_rang(self.phone, self.ios_id)

    def stop(self) -> None:
        pass


class _PeerSender:
    """knit-peer on hci0 sends the wake test's DMs, and refuses every node but the iPhone. Its link manager rings the
    iPhone's doorbell after each frame it writes (`LinkManager+Doorbell.swift`)."""

    def __init__(self, ios: IPhone, arguments: argparse.Namespace, nonce: str) -> None:
        if not PEER.exists():
            sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
        others = others_in_range(ios.node_id) - {ios.node_id}
        self.node_id = _keygen("iphone-wake", "--above", max(others | {ios.node_id}))
        self.ios_id = ios.node_id
        self.ids: dict[str, str] = {}
        self.stopping = threading.Event()
        self.peer = Peer("android", f"knit-peer wake {nonce}", others, arguments.peer_log, arguments.rssi_floor, "iphone-wake", HCI0)
        self.peer.start()
        keep = (self.peer, {ios.node_id}, set(self.peer.refuse), self.stopping, self.peer.instance)
        threading.Thread(target=_keep_to, args=keep, daemon=True).start()

    def link(self, _ios: IPhone) -> dict:
        return _timed(lambda: self.peer.lines(lambda line: _link(line, self.ios_id)), 180)

    def begin(self) -> None:
        pass

    def send(self, body: str) -> None:
        self.ids[self.peer.command(cmd="dm", to=self.ios_id, text=body)["id"]] = body

    def look(self) -> tuple[set[str], bool]:
        delivered = self.peer.lines(lambda line: line.get("event") == "delivered" and line.get("id") in self.ids)
        down = self.peer.lines(lambda line: line.get("event") == "link" and line.get("peer") == self.ios_id and not line.get("up"))
        return {self.ids[line["id"]] for line in delivered}, not down

    def held(self, _gone: int) -> dict:
        return _no_link_dropped(self.peer, {self.ios_id})

    def rang(self) -> dict:
        rings = self.peer.command(cmd="status").get("rings", 0)
        if not rings:
            raise RuntimeError("the peer rang no doorbell")
        return {"rings": rings}

    def stop(self) -> None:
        self.stopping.set()
        self.peer.stop()


def _all_woke(woke: int, ticks: list) -> dict:
    if woke < len(ticks):
        raise RuntimeError(f"{woke} of {len(ticks)} DMs were delivered within their minute: {ticks}")
    return {"count": woke, "tickedAfter": ticks}


def _all_ticked(sender: _PhoneSender | _PeerSender, sent: list[dict]) -> bool:
    look = sender.look()
    return look is not None and {dm["body"] for dm in sent} <= look[0]


def iphone_rings(arguments: argparse.Namespace) -> int:
    """The iPhone rings the peers it dialed (ADR 2026-09.khjj). knit-peer runs on hci1 in the `ios` profile, whose
    GATT application serves a doorbell and counts its rings, with an id below the iPhone's, so the iPhone reads its
    payload and dials it. The iPhone's frames on that link stall after the HELLO (hci1's 23-byte fragments,
    .agents/context/linux-peer.md), but a ring is a GATT write, which is not a frame on the link and still arrives.
    The peer rings the iPhone back, once BlueZ has read the iPhone's services."""
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    try:
        ios.start()
    except TimeoutError:
        print(json.dumps({"action": "open Knit"}), flush=True)
        _reopened(ios, 900)
    others = others_in_range(ios.node_id) - {ios.node_id}
    peer_id = keygen(ios.node_id, "phone-dials", others)
    print(json.dumps({"run": "iphone-rings", "iphone": ios.node_id, "peer": peer_id, "refused": sorted(others)}))
    peer = Peer("ios", f"knit-peer doorbell {nonce}", others, arguments.peer_log, arguments.rssi_floor)
    stop = threading.Event()
    try:
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("iphone-dials-the-peer", lambda: _timed(lambda: peer.lines(lambda line: _link(line, ios.node_id)), 180))
        run.step("iphone-rang", lambda: _rung(peer, 1, 60))
        rang = peer.command(cmd="status")["rung"]
        time.sleep(6)
        ios.command(cmd="room", text=f"interop rings from iphone {nonce}")
        run.step("a-post-rings-again", lambda: _rung(peer, rang + 1, 20))
        run.step("iphone-counted-its-rings", lambda: {"rings": _positive(ios.command(cmd="status"), "rings")})
        run.step("peer-rang-back", lambda: _rung(ios, 1, 120))
        run.step("no-link-dropped", lambda: _no_link_dropped(peer, {ios.node_id}))
    finally:
        stop.set()
        peer.stop()
        ios.stop()
    print(json.dumps({"summary": "iphone-rings", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _rung(node: Node, at_least: int, timeout: float) -> dict:
    """Waits for `node` to count `at_least` rings of its own doorbell."""
    started = time.monotonic()
    rung = poll(lambda: (count := node.command(cmd="status").get("rung", 0)) >= at_least and count, timeout, every=1)
    return {"rung": rung, "seconds": round(time.monotonic() - started, 1)}


def _positive(status: dict, key: str) -> int:
    if not status.get(key):
        raise RuntimeError(f"{key} is {status.get(key)}")
    return status[key]


def android_rings(arguments: argparse.Namespace) -> int:
    """Companion change A4, the mirror of `iphone-rings`: Android rings the doorbell of a peer whose HELLO asks for it
    (`CAP_DOORBELL`, knit-next ADR 2026-09.dqvb). knit-peer runs on hci1 in the `ios` profile, which serves a doorbell
    and says so in its HELLO. The phone looks the doorbell up over the link and rings it after its link-up frames. Then
    it posts and DMs through its debug bridge, each after a spell with no ring, and each must ring the peer within
    seconds. Android rings as it queues a frame, so the ring comes even while the frame waits in the link's queue; each
    frame must then arrive within `--arrival-timeout` of its send. Before the rings, the back-fill must drain: custody
    converges, but for frames from senders the phone pinned before it kept their signed profiles (knit-next ADR
    2026-09.g64k, database v16). The phone must run a debug build with A4 (knit-next `c3191717` or later); the first
    step checks, before the peer starts.

    `--link` picks whose link it is. `dialed`, the default, needs companion change A3: the peer's id sorts below the
    phone's, the phone reads its GATT payload and dials it, and takes its capabilities from the peer's HELLO reply, so
    this is a link Android dialed. Once the phone sets FLAG_DIALS_GATT_PEERS the peer waits for that dial of its own
    accord. A phone that reads payloads with the flag still clear would be dialed by the peer too, and the peer would
    refuse the phone's dial as one it makes itself, so then the peer never sights the phone (`--never-sight`).
    `accepted` is the link Android rang before A3: the peer serves its doorbell without the payload
    (`--no-gatt-payload`), so the phone never sights it, and its id sorts above the phone's, so it dials the phone
    whatever the phone's flag."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    state = phone.state()
    phone_id = state["self"]["nodeId"]
    served_before = state.get("metrics", {}).get("keysServed", 0)
    checked = run.step("phone-build-rings", lambda: _rings_doorbells(phone))
    dialed = arguments.link == "dialed"
    if checked is not None and dialed:
        checked = run.step("phone-build-reads-gatt", lambda: _reads_gatt_payloads(phone))
    if checked is None:
        print(json.dumps({"summary": "android-rings", "steps": run.steps, "failed": run.failed}))
        return run.failed
    heard = in_range()
    others = set(heard) - {phone_id}
    flagged = bool(heard.get(phone_id, {}).get("flags", 0) & DIALS_GATT_PEERS)
    # Below the phone, it is the phone's to dial; above it, the peer's.
    peer_id = keygen(phone_id, "phone-dials" if dialed else "peer-dials", others)
    held = {phone_id} if dialed and not flagged else set()
    print(
        json.dumps(
            {
                "run": "android-rings",
                "link": arguments.link,
                "phone": phone_id,
                "phoneFlagged": flagged,
                "peer": peer_id,
                "neverSighted": sorted(held),
                "refused": sorted(others),
            }
        )
    )
    phone.shell("logcat -c")
    peer = Peer("ios", f"knit-peer rings {nonce}", others, arguments.peer_log, arguments.rssi_floor, never_sight=held, gatt_payload=dialed)
    mark = peer.log_mark()
    stop = threading.Event()
    try:
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {phone_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        linked = "phone-dials-the-peer" if dialed else "peer-dials-the-phone"
        up = run.step(linked, lambda: link_up(peer, phone, phone_id) and _who_dialed(phone, peer, peer_id, phone_id, mark, dialed))
        if up is not None:
            run.step("phone-found-the-doorbell", lambda: _doorbell_found(phone, peer_id, 60))
            run.step("link-up-rang", lambda: _rung(peer, 1, 60))
            # The back-fill drains now that the phone sends each sender's key ahead of their backlog (knit-next ADR
            # 2026-09.g64k), and the rings below then come on a quiet link.
            converge = arguments.converge_timeout
            run.step("custody-converged", lambda: _custody_converges_with_keys(peer, phone, converge, served_before))
            # Android rings as it queues a frame, not as it writes it, so a ring shows up at once even while the frame
            # waits behind any back-fill, which on `hci1` runs at under 1 KB/s. A ring that comes within seconds of a
            # post, after a spell with none, is the post's.
            bodies = {name: f"interop {name} rings from phone {nonce}" for name in ("post", "dm")}
            sent_at: dict[str, float] = {}
            for name, conversation in (("post", "nearby"), ("dm", peer_id)):
                run.step(
                    f"a-{name}-rings",
                    lambda name=name, conversation=conversation: _rings_for(peer, phone, bodies[name], conversation, sent_at),
                )
            run.step("phone-logged-its-rings", lambda: _phone_rang(phone, peer_id))
            run.step("link-held", lambda: {**_phone_held(phone, peer_id), **_no_link_dropped(peer, {phone_id})})
            run.step("arrivals", lambda: _frames_arrived(peer, bodies, sent_at, arguments.arrival_timeout))
    finally:
        stop.set()
        peer.stop()
    print(json.dumps({"summary": "android-rings", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _who_dialed(phone: Phone, peer: Peer, peer_id: str, phone_id: str, mark: int, phone_dials: bool) -> dict:
    """The link up is the one the right side dialed: the phone logs `bt connect ok` for a dial of its own and `bt accepted
    client` for one it took, and the peer logs `link dialing` for each dial it makes. Android dials only a peer whose id
    sorts below its own, and accepts a sighted dialer only from above."""
    dials = [m for m in peer.log_since(mark) if m.startswith(f"link dialing {phone_id} ")]
    connected = _phone_log(phone, f"bt connect ok {peer_id}")
    accepted = _phone_log(phone, f"bt accepted client {peer_id} ")
    detail = {"peerDials": len(dials), "phoneConnected": len(connected), "phoneAccepted": accepted[-1:]}
    if phone_dials and (dials or not connected):
        raise RuntimeError(f"not the phone's dial: {detail}")
    if not phone_dials and not accepted:
        raise RuntimeError(f"the phone never accepted the peer: {detail}")
    return detail


def android_reads(arguments: argparse.Namespace) -> int:
    """Companion change A3's device gate: Android finds a node that advertises only the `0xFE30` UUID, as an iPhone
    does, by reading its GATT payload, and dials it when its own id sorts higher (knit-next `feat/gatt-peers`).
    knit-peer runs on hci1 in the `ios` profile, which serves the payload and the doorbell, against one phone.

    `--order peer-below`: the phone reads the payload, dials the peer and finds its doorbell on that link, which rings
    for the link-up frames, so the dialed link took `CAP_DOORBELL` from the peer's HELLO reply. The peer must not dial
    the phone. Once the phone sets FLAG_DIALS_GATT_PEERS it waits of its own accord, and the run checks it did. Before
    then it would dial the phone, and refuse the phone's dial as one it makes itself, so the peer never sights the
    phone (`--never-sight`): it holds its dials, and admits the phone's as it admits an iPhone's.

    `--order peer-above`: the phone reads the payload and never dials; the peer dials, and the phone accepts it as a
    dialer it sighted, which only the read can have given it. The peer refuses the phone until the phone has logged
    the read, or its dial could land first and be admitted unsighted under A1.

    In both orders every payload the phone read belongs to a node that advertises no service data: the peer, or an
    iPhone or Mac in range, never an Android phone. The run reports the first link's time from the peer's start, MVP
    item 2's measure, and the link must then hold for `--hold` seconds (60). The phone runs a debug build with A3; the
    first step checks, before the peer starts.

    Every peer here has hci1's address, so a phone that read an earlier run's peer holds that payload until one of the
    payload lifetime's rules forgets it: a failed dial, a HELLO naming another node, or a minute of scanning with the
    address quiet (ADR 2026-09.xzpt). A build without those rules sights each later peer as the old one, until Knit
    restarts ("What A3's gate showed", `.agents/context/linux-peer.md`). `android-forgets` stages each rule."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    if run.step("phone-build-reads-gatt", lambda: _reads_gatt_payloads(phone)) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    heard = in_range()
    others = set(heard) - {phone_id}
    flagged = bool(heard.get(phone_id, {}).get("flags", 0) & DIALS_GATT_PEERS)
    below = arguments.order == "peer-below"
    # Every peer this adapter runs has its address, so the phone must have let the last one go first, and the payload
    # it read there too: one above the phone lasts until the address goes quiet (the open case, ADR 2026-09.xzpt).
    if run.step("phone-forgot-old-peers", lambda: _phone_forgets_all_but(phone, set(heard))) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    if run.step("phone-forgot-old-payload", lambda: _address_released(phone, HCI1_ADDRESS, arguments.quiet_timeout)) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    peer_id = keygen(phone_id, "phone-dials" if below else "peer-dials", others)
    held = {phone_id} if below and not flagged else set()
    print(
        json.dumps(
            {
                "run": "android-reads",
                "order": arguments.order,
                "phone": phone_id,
                "phoneFlagged": flagged,
                "peer": peer_id,
                "neverSighted": sorted(held),
                "refused": sorted(others),
            }
        )
    )
    phone.shell("logcat -c")
    # Above the phone, the peer holds its dial until the phone has read it (`allow-link` below).
    refused = others if below else others | {phone_id}
    # This dongle cannot advertise while anything holds a link to it. On 2026-09-29 the Pixel 3 never heard a peer
    # started while one was up, left by the scan's read or a phone's stray connect: it must be gone first.
    if run.step("hci1-idle", lambda: _hci1_idle_after(3)) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    peer = Peer("ios", f"knit-peer reads {nonce}", refused, arguments.peer_log, arguments.rssi_floor, never_sight=held)
    mark = peer.log_mark()
    stop = threading.Event()
    try:
        started = time.monotonic()
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {phone_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("phone-read-the-peer", lambda: _phone_read(phone, peer_id, started, arguments.link_timeout))
        if not below:
            peer.command(cmd="allow-link", peer=phone_id)
        link = run.step("link", lambda: _first_link(peer, phone, phone_id, started, arguments.link_timeout))
        if link is not None:
            if below:
                run.step("phone-dialed-the-peer", lambda: _who_dialed(phone, peer, peer_id, phone_id, mark, phone_dials=True))
                run.step("phone-found-the-doorbell", lambda: _doorbell_found(phone, peer_id, 60))
                run.step("link-up-rang", lambda: _rung(peer, 1, 60))
                name = "peer-waited-of-its-own-accord" if flagged else "peer-held-its-dials"
                run.step(name, lambda: _peer_never_dialed(peer, phone_id, mark))
            else:
                run.step("peer-dialed-the-phone", lambda: _who_dialed(phone, peer, peer_id, phone_id, mark, phone_dials=False))
                run.step("phone-sighted-the-dialer", lambda: _accepted_sighted(phone, peer_id))
                run.step("phone-never-dialed", lambda: _phone_never_dialed(phone, peer_id))
            time.sleep(max(0.0, link["at"] + arguments.hold - time.monotonic()))
            run.step("link-held", lambda: {**_phone_held(phone, peer_id), **_no_link_dropped(peer, {phone_id}), "heldSeconds": arguments.hold})
        run.step("reads-only-uuid-nodes", lambda: _reads_only_uuid_nodes(phone, peer_id, androids(heard)))
        run.step("phone-gatt-counts", lambda: _reads_gatt_payloads(phone))
    finally:
        stop.set()
        peer.stop()
    print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
    return run.failed


def android_forgets(arguments: argparse.Namespace) -> int:
    """The payload lifetime's three forget rules on an Android phone (ADR 2026-09.xzpt, amended 2026-09-29; knit-next
    ADR 2026-09.kwq2), each seen once through the phone's `bt gatt forget <address> (dial|hello <node>|quiet)` line.
    Every knit-peer on hci1 has the adapter's one public address, so each restart under a new identity is a node taking
    a reused address. The stages run in order on one phone, each from a fresh identity:

    1. **quiet:** a peer above the phone is read, then stops, and nothing advertises there for over a minute of the
        phone's scanning. The payload goes, `quiet`.
    2. **hello, accepted:** a peer above the phone is read, then stops, and a new identity above the phone starts at
        once and dials in. The phone still sights the old payload at the address, and the dialer's HELLO names another
        node, so the payload goes, `hello <new id>`. Its own payload is then left to go quiet.
    3. **dial:** a peer below the phone is read and dialed, then stops. The phone dials the address again, the dial
        fails before a channel opens, and the payload goes.
    4. **hello, dialed:** a peer below the phone is read and dialed, then stops, and a new identity below the phone starts
        at once on the same PSM. The phone dials the old payload's node there, the reply names another node, and the
        payload goes, `hello <new id>`.

    A peer below a phone whose flag is clear never sights it (`--never-sight`), as in `android-reads`."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    if run.step("phone-build-reads-gatt", lambda: _reads_gatt_payloads(phone)) is None:
        print(json.dumps({"summary": "android-forgets", "steps": run.steps, "failed": run.failed}))
        return run.failed
    heard = in_range()
    others = set(heard) - {phone_id}
    flagged = bool(heard.get(phone_id, {}).get("flags", 0) & DIALS_GATT_PEERS)
    print(json.dumps({"run": "android-forgets", "phone": phone_id, "phoneFlagged": flagged, "refused": sorted(others)}))
    if run.step("phone-forgot-old-peers", lambda: _phone_forgets_all_but(phone, set(heard))) is None:
        print(json.dumps({"summary": "android-forgets", "steps": run.steps, "failed": run.failed}))
        return run.failed
    phone.shell("logcat -c")

    def peer(order: str, tag: str) -> Peer:
        below = order == "phone-dials"
        keygen(phone_id, order, others)
        held = {phone_id} if below and not flagged else set()
        started = Peer("ios", f"knit-peer forgets {tag} {nonce}", others, arguments.peer_log, arguments.rssi_floor, never_sight=held)
        started.start()
        return started

    current: Peer | None = None
    stages = arguments.stages.split(",")
    try:
        # The stages run so that a peer below the phone never follows a payload of one above it without a quiet forget
        # between: nothing forgets that one while the address stays busy (the open case, ADR 2026-09.xzpt).
        if "quiet" in stages:
            current = peer("peer-dials", "quiet")
            current.command(cmd="deny-link", peer=phone_id)
            run.step("quiet-read", lambda: _phone_read(phone, current.node_id, time.monotonic(), arguments.link_timeout))
            mark = len(_phone_log(phone, "bt gatt forget "))
            current.stop()
            run.step("quiet-forgets", lambda: _phone_forgot(phone, "(quiet)", arguments.quiet_timeout, mark))
        if "hello-accepted" in stages:
            current = peer("peer-dials", "hello-accepted-old")
            current.command(cmd="deny-link", peer=phone_id)
            run.step("hello-accepted-read", lambda: _phone_read(phone, current.node_id, time.monotonic(), arguments.link_timeout))
            current.stop()
            mark = len(_phone_log(phone, "bt gatt forget "))
            current = peer("peer-dials", "hello-accepted-new")
            newcomer = current.node_id
            run.step("hello-accepted-forgets", lambda: _phone_forgot(phone, f"(hello {newcomer})", arguments.link_timeout, mark))
            # The newcomer's payload is read once its link ends; let it go quiet before a peer below the phone.
            mark = len(_phone_log(phone, "bt gatt forget "))
            current.stop()
            if "dial" in stages or "hello-dialed" in stages:
                run.step("hello-accepted-clears", lambda: _phone_forgot(phone, "", arguments.quiet_timeout, mark))
        if "dial" in stages:
            current = peer("phone-dials", "dial")
            run.step("dial-read-and-linked", lambda: _read_and_linked(phone, current, phone_id, arguments.link_timeout))
            mark = len(_phone_log(phone, "bt gatt forget "))
            current.stop()
            run.step("dial-forgets", lambda: _phone_forgot(phone, "(dial)", arguments.link_timeout, mark))
            # The watchdog gave the dial up, but the stack's own connect may run on, and on 2026-09-29 one caught the
            # next peer's advert and held hci1 with no channel for minutes: let it lapse before another peer advertises.
            run.step("dial-lapsed", lambda: _hci1_idle_after(30))
        if "hello-dialed" in stages:
            current = peer("phone-dials", "hello-dialed-old")
            run.step("hello-dialed-read-and-linked", lambda: _read_and_linked(phone, current, phone_id, arguments.link_timeout))
            current.stop()
            mark = len(_phone_log(phone, "bt gatt forget "))
            current = peer("phone-dials", "hello-dialed-new")
            newcomer = current.node_id
            run.step("hello-dialed-forgets", lambda: _phone_forgot(phone, f"(hello {newcomer})", arguments.link_timeout, mark))
    finally:
        if current:
            current.stop()
    run.step("forgets-logged", lambda: {"lines": _phone_log(phone, "bt gatt forget ")})
    print(json.dumps({"summary": "android-forgets", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone_forgets(arguments: argparse.Namespace) -> int:
    """The payload lifetime's forget rules on the iPhone's own radio, KnitBLE (ADR 2026-09.xzpt, amended 2026-09-29),
    each seen through Knit's log: `ble forgetting the GATT payload of <identifier>: its HELLO named <node>` or `: quiet
    for a minute of scanning`. knit-peer runs on hci1 in the `ios` profile, so the iPhone finds it by reading its GATT
    payload, and every peer there has the adapter's address: each new identity is a node taking a reused address. The
    iPhone's writes to hci1 stall after the HELLO, which is all these rules need. In order, so that no stage meets the
    open case (a payload above the iPhone at an address a peer below it keeps busy):

    1. **dialed:** a peer below the iPhone is read and dialed, then stops, and a new identity below it starts at once
        on the same PSM. The iPhone dials the old node there, the reply names the new one, and the payload goes.
    2. **quiet:** a peer above the iPhone is read, then stops, and nothing advertises there for a minute of the
        iPhone's scanning.
    3. **accepted:** a peer above the iPhone is read, then stops, and a new identity above it dials in. The iPhone keys
        an accepted link by its central's identifier and the payload by the peripheral's, so the payload goes only if
        CoreBluetooth gives hci1 the same identifier in both roles, which nothing had checked on hardware.

    Knit must be open on the iPhone, a debug build with the rules, and it stays open throughout. `--hci0` runs the peer
    on the maintainer's adapter, shared, which needs its own go-ahead: on 2026-09-29 the iPhone's reads of hci1 timed
    out, where its reads on hci0 had always worked (`.agents/context/linux-peer.md`)."""
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    others = others_in_range(ios.node_id)
    folder = ROOT / ".build" / "interop-iphone-forgets"
    folder.mkdir(parents=True, exist_ok=True)
    log_path = folder / f"{time.strftime('%Y%m%d-%H%M%S')}-iphone.log"
    log = IPhoneLog(ios.udid, log_path)
    stages = arguments.stages.split(",")
    print(json.dumps({"run": "iphone-forgets", "iphone": ios.node_id, "stages": stages, "log": str(log_path), "refused": sorted(others)}))
    current: Peer | None = None

    def peer(side: str, tag: str, reads: bool = True) -> Peer:
        # A peer the iPhone only has to read reads nothing itself: its connection to read the iPhone, made as the
        # iPhone read it, made the iPhone file it as a stranger for ten minutes (2026-09-29).
        _keygen("iphone-forgets", *_peer_window(ios.node_id, others, side))
        adapter = HCI0 if arguments.hci0 else None
        started = Peer(
            "ios", f"knit-peer forgets {tag} {nonce}", others, arguments.peer_log, arguments.rssi_floor, "iphone-forgets", adapter, gatt_reads=reads
        )
        began[started] = time.monotonic()
        started.start()
        return started

    began: dict[Peer, float] = {}

    def lapse() -> dict:
        # hci0 holds the maintainer's own links, so only hci1 can be checked for a stray one.
        return _hci1_idle_after(30) if not arguments.hci0 else (time.sleep(30) or {})

    try:
        if not arguments.hci0:
            run.step("hci1-idle", lambda: _hci1_idle_after(3))
        if "dialed" in stages:
            current = peer("iphone-above", "dialed-old")
            read = run.step("dialed-read", lambda: _ios_read(log_path, current.node_id, arguments.link_timeout))
            run.step("dialed-linked", lambda: _linked_since(current, ios.node_id, began[current], arguments.link_timeout))
            current.stop()
            current = peer("iphone-above", "dialed-new")
            newcomer = current.node_id
            if read:
                run.step("dialed-forgets", lambda: _ios_forgot(log_path, read["identifier"], f"its HELLO named {newcomer}", arguments.link_timeout))
            current.stop()
            run.step("dialed-lapsed", lapse)
        if "quiet" in stages:
            current = peer("iphone-below", "quiet", reads=False)
            current.command(cmd="deny-link", peer=ios.node_id)
            read = run.step("quiet-read", lambda: _ios_read(log_path, current.node_id, arguments.link_timeout))
            current.stop()
            if read:
                run.step("quiet-forgets", lambda: _ios_forgot(log_path, read["identifier"], "quiet for a minute", arguments.quiet_timeout))
        if "accepted" in stages:
            current = peer("iphone-below", "accepted-old", reads=False)
            current.command(cmd="deny-link", peer=ios.node_id)
            read = run.step("accepted-read", lambda: _ios_read(log_path, current.node_id, arguments.link_timeout))
            current.stop()
            current = peer("iphone-below", "accepted-new")
            newcomer = current.node_id
            run.step("accepted-linked", lambda: _linked_since(current, ios.node_id, began[current], arguments.link_timeout))
            if read:
                run.step("accepted-forgets", lambda: _ios_forgot(log_path, read["identifier"], f"its HELLO named {newcomer}", arguments.link_timeout))
    finally:
        if current:
            current.stop()
        log.stop()
        ios.stop()
    lines = [e["message"] for e in IPhoneLog.entries(log_path) if "GATT payload" in e["message"] or " over GATT" in e["message"]]
    print(json.dumps({"iphoneGattLines": lines[-20:]}))
    print(json.dumps({"summary": "iphone-forgets", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _ios_read(log_path: Path, node: str, timeout: float) -> dict:
    """The iPhone logged `ble read <node> on PSM <psm> from <identifier> over GATT`, and the identifier it keys it by."""
    started = time.monotonic()
    pattern = re.compile(rf"ble read {node} on PSM (\d+) from (\S+) over GATT")

    def read() -> dict | None:
        for entry in IPhoneLog.entries(log_path):
            match = pattern.search(entry["message"])
            if match:
                return {"psm": int(match.group(1)), "identifier": match.group(2)}
        return None

    found = poll(read, timeout, every=2)
    return {**found, "seconds": round(time.monotonic() - started, 1)}


def _ios_forgot(log_path: Path, identifier: str, reason: str, timeout: float) -> dict:
    """The iPhone logged `ble forgetting the GATT payload of <identifier>: <reason…>`."""
    started = time.monotonic()
    needle = f"ble forgetting the GATT payload of {identifier}: {reason}"

    def forgot() -> str | None:
        return next((e["message"] for e in IPhoneLog.entries(log_path) if e["message"].startswith(needle)), None)

    try:
        line = poll(forgot, timeout, every=2)
    except TimeoutError:
        others = [e["message"] for e in IPhoneLog.entries(log_path) if "ble forgetting the GATT payload" in e["message"]]
        raise RuntimeError(f"no forget of {identifier} ({reason}); forgets logged: {others[-4:]}") from None
    return {"line": line, "seconds": round(time.monotonic() - started, 1)}


def _hci1_idle_after(seconds: float) -> dict:
    """Waits `seconds`, then reports any connection hci1 still holds with no peer running, which only a phone's stray
    connect can have made."""
    time.sleep(seconds)
    listing = subprocess.run(["hcitool", "-i", "hci1", "con"], capture_output=True, text=True, check=False).stdout
    held = [line.strip() for line in listing.splitlines()[1:] if line.strip()]
    if held:
        raise RuntimeError(f"hci1 still holds {held}")
    return {}


def _read_and_linked(phone: Phone, peer: Peer, phone_id: str, timeout: float) -> dict:
    """The phone read the peer's payload and the two linked."""
    read = _phone_read(phone, peer.node_id, time.monotonic(), timeout)
    link_up(peer, phone, phone_id, timeout)
    return read


def _phone_forgot(phone: Phone, reason: str, timeout: float, mark: int) -> dict:
    """The phone logged `bt gatt forget <address> <reason>` after the first `mark` forget lines, and how long after the
    call it showed. An empty `reason` takes any forget."""
    started = time.monotonic()

    def forgot() -> list[str] | None:
        phone.wake()
        return [line for line in _phone_log(phone, "bt gatt forget ")[mark:] if line.endswith(reason)] or None

    lines = poll(forgot, timeout, every=3)
    return {"line": lines[-1], "seconds": round(time.monotonic() - started, 1)}


# hci1's public address, which every peer on it advertises from.
HCI1_ADDRESS = "0A:BC:DE:00:00:A1"


def _address_released(phone: Phone, address: str, timeout: float) -> dict:
    """Waits until the phone holds no GATT payload for `address`: its log shows no read there, or a forget after the
    last one. Nothing advertises there meanwhile, so a payload from a peer above the phone goes quiet in a minute of
    the phone's scanning."""
    started = time.monotonic()

    def released() -> bool:
        phone.wake()
        lines = [line for line in _phone_log(phone, "bt gatt ") if f" {address} " in line]
        held = [i for i, line in enumerate(lines) if f"read {address} →" in line]
        gone = [i for i, line in enumerate(lines) if f"forget {address} " in line]
        return not held or (bool(gone) and gone[-1] > held[-1])

    poll(released, timeout, every=5)
    return {"seconds": round(time.monotonic() - started, 1)}


def _phone_forgets_all_but(phone: Phone, heard: set[str], timeout: float = 180) -> dict:
    """Waits until the phone holds no node in reach that the scan did not hear: a peer of an earlier run, whose sighting
    lingers 90 s. Every peer on hci1 has that adapter's address, so the phone dials the next one as the last, and one
    such dial on 2026-09-29 outlived its 12 s watchdog in the Pixel 7's stack, connected when the next peer advertised,
    and held that link for minutes with no channel, which kept hci1 from advertising at all."""
    started = time.monotonic()
    left: set[str] = set()

    def forgot() -> bool:
        left.clear()
        left.update({p["nodeId"] for p in phone.state().get("reachable", [])} - heard)
        return not left

    try:
        poll(forgot, timeout, every=5)
    except TimeoutError as error:
        raise TimeoutError(f"the phone still holds {sorted(left)}") from error
    return {"seconds": round(time.monotonic() - started, 1)}


def _phone_read(phone: Phone, peer_id: str, since: float, timeout: float) -> dict:
    """The phone logged a read of the peer's payload, and how long after the peer started it first showed."""

    def read() -> list | None:
        phone.wake()
        return [address for address, node in _gatt_reads(phone) if node == peer_id] or None

    addresses = poll(read, timeout, every=3)
    return {"secondsAfterStart": round(time.monotonic() - since, 1), "address": addresses[0], "reads": len(addresses)}


def _first_link(peer: Peer, phone: Phone, phone_id: str, since: float, timeout: float) -> dict:
    """MVP item 2: the first link after the peer started, which the item wants within 30 s."""
    line = link_up(peer, phone, phone_id, timeout)
    seconds = round(line["_at"] - since, 1)
    return {"seconds": seconds, "withinThirtySeconds": seconds <= 30, "at": line["_at"]}


def _peer_never_dialed(peer: Peer, phone_id: str, mark: int) -> dict:
    dials = [m for m in peer.log_since(mark) if m.startswith(f"link dialing {phone_id} ")]
    if dials:
        raise RuntimeError(f"the peer dialed the phone {len(dials)} times: {dials[:2]}")
    return {}


def _accepted_sighted(phone: Phone, peer_id: str) -> dict:
    """The phone admitted the peer as a dialer it had sighted: its only sighting of the peer is the read."""
    accepted = _phone_log(phone, f"bt accepted client {peer_id} ")
    if not accepted or "sighted=true" not in accepted[-1]:
        raise RuntimeError(f"the phone did not accept the peer as sighted: {accepted[-2:]}")
    return {"accepted": accepted[-1]}


def _phone_never_dialed(phone: Phone, peer_id: str) -> dict:
    dials = _phone_log(phone, f"bt initiating to {peer_id} ")
    if dials:
        raise RuntimeError(f"the phone dialed the peer: {dials[:2]}")
    return {}


def _reads_only_uuid_nodes(phone: Phone, peer_id: str, service_data: set[str]) -> dict:
    """Every payload the phone read over GATT belongs to a node without service data: never an Android phone, whose
    advert it takes as the sighting."""
    reads = _gatt_reads(phone)
    wrong = sorted({node for _, node in reads if node in service_data})
    if wrong:
        raise RuntimeError(f"the phone read the payload of Android phones {wrong}")
    if not any(node == peer_id for _, node in reads):
        raise RuntimeError("the phone never read the peer")
    unread = _phone_log(phone, "bt gatt read ")
    return {
        "reads": len(reads),
        "nodes": sorted({node for _, node in reads}),
        "failed": sum(" failed (" in line for line in unread),
        "strangers": sum(" stranger (" in line for line in unread),
    }


def _rings_for(
    peer: Peer, phone: Phone, body: str, conversation: str, sent_at: dict[str, float], quiet: float = 6, timeout: float = 8
) -> dict:
    """Sends `body` from the phone once the peer has heard no ring for `quiet` seconds, past the 5 s interval, and
    waits `timeout` seconds for the ring it owes: at once, or at most 5 s later if something else rang first. When it
    sent goes in `sent_at`, keyed by the body."""
    started = time.monotonic()
    last = peer.command(cmd="status")["rung"]
    still = time.monotonic()
    while time.monotonic() - still < quiet:
        if time.monotonic() - started > 120:
            raise RuntimeError(f"the peer was rung at least every {quiet:.0f} s for 120 s")
        time.sleep(1)
        rung = peer.command(cmd="status")["rung"]
        if rung != last:
            last, still = rung, time.monotonic()
    sent = time.monotonic()
    sent_at[body] = sent
    phone.send(body, conversation=conversation)
    try:
        rang = poll(lambda: (count := peer.command(cmd="status")["rung"]) > last and count, timeout, every=0.5)
    except TimeoutError as error:
        raise RuntimeError(f"no ring within {timeout:.0f} s of the send") from error
    return {"rung": rang, "afterSend": round(time.monotonic() - sent, 1), "waitedForQuiet": round(sent - started, 1)}


def _frames_arrived(peer: Peer, bodies: dict[str, str], sent_at: dict[str, float], timeout: float) -> dict:
    """Each frame the phone sent reached the peer within `timeout` of its send, and how long it took. The phone's
    link writer is first in, first out, and it queues a digest of its whole custody every 60 s whatever is already
    queued. So on `hci1`, where a newcomer's back-fill takes about 9 minutes, the digests made meanwhile (about 20 KB
    each for 780 ids) still stand ahead of a frame sent once custody matches, and the frame waits minutes behind
    them. A link that drops meanwhile loses the queue, and custody serves the frame again on the next link."""
    latencies = {}
    for name, body in bodies.items():
        sent = sent_at.get(body)
        if sent is None:
            raise RuntimeError(f"the {name} was never sent")
        try:
            line = peer.wait(lambda line, body=body: _message(line, body), max(0, sent + timeout - time.monotonic()))
        except TimeoutError:
            raise RuntimeError(f"the {name} had not arrived {timeout:.0f} s after it was sent") from None
        latencies[name] = round(line["_at"] - sent, 1)
    return latencies


def _phone_log(phone: Phone, needle: str) -> list[str]:
    """The messages of the phone's Bluetooth transport log lines that contain `needle`, A3's GATT reads among them."""
    log = phone.shell("logcat -d -s BluetoothMeshTransport:*", timeout=60)
    return [line.split(": ", 1)[-1] for line in log.splitlines() if needle in line]


def _reads_gatt_payloads(phone: Phone) -> dict:
    """The phone runs an A3 build: its debug build's `bt state` line counts the GATT payloads it holds and the reads it
    has made. The line of a build that predates A3 has neither."""
    try:
        lines = poll(lambda: _phone_log(phone, "bt state "), 75, every=5)
    except TimeoutError as error:
        raise RuntimeError("the phone logged no bt state line in 75 s: is Knit running, and a debug build?") from error
    counts = _gatt_counts(lines[-1])
    if counts is None:
        raise RuntimeError("the phone's build predates A3: install a debug build of knit-next feat/gatt-peers")
    return counts


def _gatt_counts(line: str) -> dict | None:
    payloads = re.search(r"gattPayloads=(\d+)", line)
    reads = re.search(r"gattReads=(\d+)", line)
    if not payloads or not reads:
        return None
    return {"gattPayloads": int(payloads.group(1)), "gattReads": int(reads.group(1))}


def _gatt_reads(phone: Phone) -> list[tuple[str, str]]:
    """Each GATT payload the phone read, as the address and the node id its `bt gatt read <address> → <node> (psm …)`
    line names, oldest first. A read that failed or found a stranger names no node."""
    reads = []
    for line in _phone_log(phone, "bt gatt read "):
        match = re.search(r"bt gatt read (\S+) → ([a-z2-7]{26})", line)
        if match:
            reads.append((match.group(1), match.group(2)))
    return reads


def _rings_doorbells(phone: Phone) -> dict:
    """The phone runs an A4 build: the state line its Bluetooth transport logs every 60 s in a debug build counts
    doorbells and rings. The line of a build that predates A4 has neither."""
    try:
        lines = poll(lambda: _phone_log(phone, "bt state "), 75, every=5)
    except TimeoutError as error:
        raise RuntimeError("the phone logged no bt state line in 75 s: is Knit running, and a debug build?") from error
    counts = re.search(r"doorbells=(\d+) rings=(\d+)", lines[-1])
    if not counts:
        raise RuntimeError("the phone's build predates A4: install a debug build of knit-next feat/ble-doorbell")
    return {"doorbells": int(counts.group(1)), "rings": int(counts.group(2))}


def _doorbell_found(phone: Phone, node: str, timeout: float) -> dict:
    """The phone looked up `node`'s doorbell over the link, and found it."""

    def looked() -> dict | None:
        lookups = [line for line in _phone_log(phone, "bt doorbell ") if f" {node}" in line]
        if any(line.startswith("bt doorbell absent") for line in lookups):
            raise RuntimeError(f"the phone found no doorbell: {lookups[-3:]}")
        found = [line for line in lookups if line.startswith("bt doorbell found")]
        return {"found": found[-1], "failedLookups": sum("lookup failed" in line for line in lookups)} if found else None

    return poll(looked, timeout, every=3)


def _phone_rang(phone: Phone, node: str) -> dict:
    """The phone logged a ring of `node`'s doorbell (`bt ring`, a debug build's line)."""
    rings = _phone_log(phone, f"bt ring {node}")
    if not rings:
        raise RuntimeError(f"the phone logged no ring of {node}")
    return {"rings": len(rings)}


def _phone_held(phone: Phone, node: str) -> dict:
    """The phone logged no link down for `node`."""
    downs = _phone_log(phone, f"link down: {node}")
    if downs:
        raise RuntimeError(f"the phone dropped the link: {downs[:3]}")
    return {}


def iphone_scan(arguments: argparse.Namespace) -> int:
    """P8's scan-filter check (.agents/specs/mvp.md): what an iPhone matches when it scans for the 0xFE30 UUID alone,
    as a scan in the background must. Android's advert carries 0xFE30 only as service data; an iPhone's, and the `ios`
    profile's, lists it as a UUID. A debug build's scan probe, `scan-filter` over the bridge, turns the filter on and
    records each match, and whether Knit was away from the front when it came.

    Two peers advertise, each on its own adapter so each has an address of its own: the `android` profile on hci0 and
    the `ios` profile on hci1. The iPhone refuses both, so it only watches them. With Knit open, the run checks that the
    unfiltered scan sights both, then turns the filter on and reads what it matched. Then someone locks the iPhone.
    Once Knit is suspended the peers stop and start again one at a time, the `android` peer first unless `--first ios`,
    and someone opens Knit again. A match that came after its peer started and before anyone was asked to unlock is one
    the locked iPhone's scan delivered, waking Knit to take it; one that came as the screen woke does not count. The
    Android phones in range show what real Android adverts match."""
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    try:
        ios.start()
    except TimeoutError:
        print(json.dumps({"action": "open Knit"}), flush=True)
        _reopened(ios, 900)
    others = others_in_range(ios.node_id) - {ios.node_id}
    # The android peer sorts above every phone, so no phone dials it. The ios peer keeps its identity from run to
    # run: the iPhone keeps a GATT payload it read for as long as Knit runs, so a new identity on hci1 would go unseen.
    # Android cannot see the ios peer, and the iPhone refuses both.
    data_id = _keygen("scan-data", "--above", max(others | {ios.node_id}))
    if not (Path.home() / ".local" / "state" / "knit-peer" / "scan-uuid" / "identity").exists():
        _keygen("scan-uuid", "--above", max(others | {ios.node_id}))
    data = Peer("android", f"knit-peer scan data {nonce}", others | {ios.node_id}, arguments.peer_log, None, "scan-data", HCI0)
    uuid = Peer("ios", f"knit-peer scan uuid {nonce}", others | {ios.node_id}, arguments.peer_log, None, "scan-uuid")
    stop = threading.Event()
    starts: dict[str, float] = {}
    try:
        for peer in (data, uuid):
            peer.start()
            ios.command(cmd="deny-link", peer=peer.node_id)
            threading.Thread(target=_keep_to, args=(peer, set(), peer.refuse, stop, peer.instance), daemon=True).start()
        uuid_id = uuid.node_id
        print(json.dumps({"run": "iphone-scan", "iphone": ios.node_id, "androidPeer": data_id, "iosPeer": uuid_id, "androids": sorted(others)}))
        run.step("unfiltered-sights-the-android-peer", lambda: _ios_sights(ios, {data_id}, others, 120))
        ios.command(cmd="scan-filter", on=True)
        time.sleep(arguments.window)
        open_report = ios.command(cmd="scan-filter")
        run.step("open-matches-the-uuid-list", lambda: _matched(open_report))
        run.step("open-finding-service-data", lambda: _service_data_finding(open_report, data_id, others))
        for peer in (data, uuid):
            peer.stop()
        print(json.dumps({"action": "lock the iPhone"}), flush=True)
        run.step("suspended", lambda: _suspended(ios, arguments.lock_wait))
        ios.stop()
        time.sleep(20)
        for peer in (uuid, data) if arguments.first == "ios" else (data, uuid):
            # Taken before the peer starts, since it may advertise before it says it is ready.
            starts[peer.instance] = time.time()
            peer.start()
            print(json.dumps({"started": peer.instance, "profile": peer.profile}), flush=True)
            time.sleep(arguments.away_window)
        # Nobody unlocks before being asked, so a match before this came while the iPhone was locked. One after it
        # may have come as the screen woke, which starts the scan again.
        locked_until = time.time()
        print(json.dumps({"action": "unlock the iPhone and open Knit"}), flush=True)
        run.step("reopened", lambda: _reopened(ios, arguments.unlock_wait))
        away_report = ios.command(cmd="scan-filter", on=False)
        offset = away_report["now"] - time.time() * 1000
        window = {instance: (started * 1000 + offset, locked_until * 1000 + offset) for instance, started in starts.items()}
        run.step("locked-finding-uuid-list", lambda: _uuid_list_finding(away_report, window["scan-uuid"]))
        run.step("locked-finding-service-data", lambda: _service_data_finding(away_report, data_id, others, window["scan-data"]))
    finally:
        stop.set()
        for peer in (data, uuid):
            peer.stop()
        try:
            ios.command(cmd="scan-filter", on=False)
            for node in (data.node_id, uuid.node_id):
                ios.command(cmd="allow-link", peer=node)
        except (TimeoutError, OSError, AssertionError):
            pass
        ios.stop()
    print(json.dumps({"summary": "iphone-scan", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _ios_sights(ios: IPhone, peers: set[str], androids: set[str], timeout: float) -> dict:
    """Waits for the iPhone's unfiltered scan to sight every one of `peers`, and says which Android phones it sights."""

    def sighted() -> set[str] | None:
        near = {sighting["peer"] for sighting in ios.command(cmd="links").get("sightings", [])}
        return near if peers <= near else None

    near = poll(sighted, timeout)
    return {"androids": sorted(near & androids)}


def _listed(match: dict) -> bool:
    """Whether a match is the ios peer's: it lists the UUID and carries no service data, and no other advert in range
    does. Its node id is the iPhone's, from a GATT payload, which can be one the peer's adapter served before."""
    return match["listed"] and not match["serviceData"]


def _matched(report: dict) -> dict:
    """The probe matched the ios peer with Knit open."""
    found = [match for match in report["matches"] if _listed(match)]
    if not found:
        raise RuntimeError(f"the probe matched no advert that lists the UUID: {[_brief_match(match) for match in report['matches']]}")
    return {"match": _brief_match(found[0])}


def _locked(match: dict, window: tuple[float, float]) -> float | None:
    """How long after its peer started a match first came while the iPhone was locked, in seconds, or None."""
    first = match.get("firstAwayAt")
    return round((first - window[0]) / 1000, 1) if first is not None and window[0] <= first < window[1] else None


def _uuid_list_finding(report: dict, window: tuple[float, float]) -> dict:
    """Whether the locked iPhone matched the ios peer, which lists the UUID. A finding, so it never fails."""
    found = [match for match in report["matches"] if _listed(match)]
    return {
        "uuidListMatchedLocked": any(_locked(match, window) is not None for match in found),
        "afterStart": next((_locked(match, window) for match in found if _locked(match, window) is not None), None),
        "iosPeer": _brief_match(found[0]) if found else None,
        "firstAwayAfterStart": round((found[0]["firstAwayAt"] - window[0]) / 1000, 1) if found and found[0].get("firstAwayAt") else None,
        "lockedFor": round((window[1] - window[0]) / 1000, 1),
    }


def _service_data_finding(report: dict, data_id: str, androids: set[str], window: tuple[float, float] | None = None) -> dict:
    """What the probe matched by service data alone: the android peer, and the Android phones in range; with
    `window`, only what first matched while the iPhone was locked. A finding, not a check, so it never fails."""
    by_data = [match for match in report["matches"] if match["serviceData"] and not match["listed"]]
    if window is not None:
        by_data = [match for match in by_data if match.get("firstAwayAt") is not None and match["firstAwayAt"] < window[1]]
    peer = [match for match in by_data if match.get("node") == data_id]
    found = {
        "serviceDataMatched": bool(by_data),
        "androidPeer": _brief_match(peer[0]) if peer else None,
        "androids": sorted({match["node"] for match in by_data if match.get("node") in androids}),
        "matches": len(report["matches"]),
    }
    if window is not None:
        found["androidPeerAfterStart"] = _locked(peer[0], window) if peer else None
    return found


def _brief_match(match: dict) -> dict:
    carried = [name for name in ("serviceData", "listed", "overflow") if match[name]]
    return {"node": match.get("node"), "by": carried, "count": match["count"], "away": match["awayCount"], "rssi": match["rssi"]}


def _suspended(ios: IPhone, timeout: float) -> dict:
    """Waits for Knit to stop answering its bridge, which it does once iOS suspends it: the lock took."""
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        try:
            ios.command(cmd="status", timeout=5)
        except TimeoutError:
            return {"seconds": round(time.monotonic() - started, 1)}
        time.sleep(2)
    raise TimeoutError("Knit kept answering: the iPhone was not locked, or something kept Knit awake")


def _wake_window(sender: _PhoneSender | _PeerSender, nonce: str, minutes: int) -> list[dict]:
    """A DM at the top of each minute. Between them the sender is read every few seconds for which DMs it has seen
    delivered, and whether the iPhone is still linked."""
    sent: list[dict] = []
    started = time.monotonic()
    end = started + 60 * minutes
    while time.monotonic() < end:
        if len(sent) < minutes and time.monotonic() >= started + 60 * len(sent):
            body = f"interop wake {nonce} {len(sent) + 1}"
            sender.send(body)
            sent.append({"body": body, "at": time.monotonic(), "wall": time.time(), "tickedAfter": None, "linkGone": 0})
        look = sender.look()
        if look is None:
            time.sleep(3)
            continue
        ticked, linked = look
        for dm in sent:
            if dm["tickedAfter"] is None and dm["body"] in ticked:
                dm["tickedAfter"] = round(time.monotonic() - dm["at"], 1)
                print(json.dumps({"dm": dm["body"], "tickedAfter": dm["tickedAfter"]}), flush=True)
        if not linked:
            sent[-1]["linkGone"] += 1
            print(json.dumps({"linked": False, "minute": len(sent)}), flush=True)
        time.sleep(3)
    return sent


def _reopened(ios: IPhone, timeout: float) -> dict:
    """Waits for Knit to answer its bridge again, once someone has unlocked the iPhone and opened it."""
    started = time.monotonic()
    while True:
        try:
            ios.start()
            return {"seconds": round(time.monotonic() - started, 1), "wall": time.time()}
        except (TimeoutError, OSError):
            ios.stop()
            if time.monotonic() - started > timeout:
                raise


def _arrivals(ios: IPhone, phone_id: str, sent: list[dict], opened_at: float) -> dict:
    """When each DM reached Knit, by Knit's own clock, which NTP keeps near this one: all of them by 60 s after the
    bridge answered again, which is itself a little after Knit came to the front."""
    messages = {m["body"]: m for m in ios.command(cmd="messages", conv=phone_id, limit=200)["messages"]}
    missing = [dm["body"] for dm in sent if dm["body"] not in messages]
    if missing:
        raise RuntimeError(f"{len(missing)} of {len(sent)} never arrived")
    arrived = [messages[dm["body"]]["arrivedAt"] / 1000 for dm in sent]
    detail = {
        "secondsAfterSending": [round(at - dm["wall"], 1) for at, dm in zip(arrived, sent, strict=True)],
        "latestAfterOpening": round(max(arrived) - opened_at, 1),
    }
    if detail["latestAfterOpening"] > 60:
        raise RuntimeError(f"arrived more than 60 s after Knit opened: {detail}")
    return detail


def _ios_still_linked(ios: IPhone, phone_id: str) -> dict:
    downs = ios.lines(lambda line: line.get("event") == "link" and line.get("peer") == phone_id and not line.get("up"))
    if downs or not any(link["peer"] == phone_id for link in ios.command(cmd="links")["links"]):
        raise RuntimeError("the iPhone is not linked to the phone")
    return {}


def _ios_linked(ios: IPhone, phone: Phone, phone_id: str, timeout: float = 120) -> dict:
    started = time.monotonic()

    def linked() -> bool:
        phone.wake()
        return any(link["peer"] == phone_id for link in ios.command(cmd="links")["links"])

    poll(linked, timeout, every=5)
    return {"seconds": round(time.monotonic() - started, 1)}


def _relinked(ios: IPhone, other: Phone | Peer, other_id: str, since: float, timeout: float = 120) -> dict:
    """The next link to the other side after `since`, from the iPhone's own link event. A start after a stop has both
    sides open, and MVP item 2 wants the link within 30 s of that."""
    deadline = time.monotonic() + timeout
    while True:
        if isinstance(other, Phone):
            other.wake()
        try:
            line = ios.wait(lambda line: _link(line, other_id) and line.get("up") and line["_at"] > since, 15)
            seconds = round(line["_at"] - since, 1)
            return {"seconds": seconds, "withinThirtySeconds": seconds <= 30}
        except TimeoutError:
            if time.monotonic() > deadline:
                raise


def _arrives_after(ios: IPhone, body: str, linked_at: float) -> dict:
    line = ios.wait(lambda line: _message(line, body), 60 + max(0, linked_at - time.monotonic()))
    after = round(line["_at"] - linked_at, 1)
    if after > 60:
        raise RuntimeError(f"arrived {after} s after the link")
    return {"secondsAfterLink": after}


def _arrives_at(other: Phone | Peer, body: str, conversation: str, linked_at: float) -> dict:
    """When `body`, which the iPhone wrote while the two were apart, reached the other side: the peer's own event line,
    or the first look at the phone's thread that shows it, one a second."""
    timeout = 60 + max(0, linked_at - time.monotonic())
    if isinstance(other, Peer):
        arrived = other.wait(lambda line: _message(line, body), timeout)["_at"]
    else:
        poll(lambda: _has(other.state(conversation), body), timeout, every=1)
        arrived = time.monotonic()
    after = round(arrived - linked_at, 1)
    if after > 60:
        raise RuntimeError(f"arrived {after} s after the link")
    return {"secondsAfterLink": after}


def _peer_window(iphone_id: str, others: set[str], order: str) -> list[str]:
    """`keygen` bounds for a peer on the given side of the iPhone that as few phones in range dial as that side allows.
    Phones dial a peer whose id sorts below theirs and are refused, so a peer above the iPhone sorts above every
    phone, and one below it sorts above the phones below it; the phones above the iPhone still dial that one."""
    if order == "iphone-below":
        return ["--above", max(others | {iphone_id})]
    lower = [node for node in others if node < iphone_id]
    return ["--below", iphone_id, *(["--above", max(lower)] if lower else [])]


def _forgets_all_but(ios: IPhone, keep: set[str], timeout: float = 150) -> dict:
    """Waits until the iPhone sights nothing outside `keep` that it is not linked to. Every peer on hci0 has that
    adapter's address, and the iPhone keeps a sighting for 90 s and redials it with backoff, so a peer started sooner
    is reached by a dial meant for the last one, and item 2's link time means nothing (`.agents/context/linux-peer.md`)."""
    started = time.monotonic()
    left: set[str] = set()

    def forgot() -> bool:
        reply = ios.command(cmd="links")
        left.clear()
        left.update({s["peer"] for s in reply["sightings"]} - keep - {link["peer"] for link in reply["links"]})
        return not left

    try:
        poll(forgot, timeout, every=5)
    except TimeoutError as error:
        raise TimeoutError(f"the iPhone still sights {sorted(left)}") from error
    return {"seconds": round(time.monotonic() - started, 1)}


def _linked_since(node: Node, other: str, since: float, timeout: float) -> dict:
    """MVP item 2: the first link to `other` after `since`, when both sides were open, which the item wants within 30 s."""
    line = node.wait(lambda line: _link(line, other) and line["_at"] >= since, timeout)
    seconds = round(line["_at"] - since, 1)
    return {"seconds": seconds, "withinThirtySeconds": seconds <= 30}


def _phone_request(phone: Phone, node: str) -> dict:
    """MVP item 5 on Android: the phone lists `node`'s first DM under Message requests. The bridge reports no request
    state, so this reads the Requests screen."""
    phone.wake()
    phone.open_route("requests")
    poll(lambda: phone.tagged(f"request_row_{node}"), 30, every=2)
    return {"request": True}


def _phone_accepts(phone: Phone, node: str) -> dict:
    """Taps Accept on `node`'s request, as someone at the phone would, then reads the Requests screen again without it."""
    accept = phone.tagged(f"request_accept_{node}")
    if accept is None:
        raise RuntimeError("no Accept for the iPhone on the phone's screen")
    phone.tap(accept)

    def gone() -> bool:
        phone.open_route("requests")
        return phone.tagged(f"request_row_{node}") is None

    poll(gone, 30, every=2)
    return {}


def _peer_pinned(peer: Peer, ios: IPhone) -> dict:
    """MVP item 3 on the peer: it knows the iPhone under the iPhone's own name or, with none, its alias."""
    shown = poll(lambda: next((p for p in peer.command(cmd="peers")["peers"] if p["peer"] == ios.node_id), None), 60)
    own = ios.command(cmd="status")
    if shown["displayName"] != own["displayName"]:
        raise RuntimeError(f"the peer shows {shown['displayName']!r} for the iPhone's {own['displayName']!r}")
    return {"displayName": shown["displayName"]}


def _same_safety_number(ios: IPhone, peer: Peer) -> dict:
    """MVP item 3: each side shows the same safety number for the pair."""
    ours = next(p for p in ios.command(cmd="peers")["peers"] if p["peer"] == peer.node_id)["safetyNumber"]
    theirs = next(p for p in peer.command(cmd="peers")["peers"] if p["peer"] == ios.node_id)["safetyNumber"]
    if ours != theirs:
        raise RuntimeError(f"the iPhone shows {ours!r} and the peer {theirs!r}")
    return {"safetyNumber": ours}


def _ios_pinned(ios: IPhone, phone_id: str, phone_name: str) -> dict:
    peer = poll(lambda: next((p for p in ios.command(cmd="peers")["peers"] if p["peer"] == phone_id), None), 60)
    if phone_name and peer["name"] != phone_name:
        raise RuntimeError(f"the iPhone shows {peer['displayName']!r}")
    return {"displayName": peer["displayName"], "safetyNumber": peer["safetyNumber"]}


def _phone_pinned(phone: Phone, ios: IPhone) -> dict:
    """The phone knows the iPhone, under its name or, with none, under the alias Android renders for it."""
    shown = poll(lambda: next((p for p in phone.state()["reachable"] if p["nodeId"] == ios.node_id), None), 30)
    if shown["name"] != ios.name:
        raise RuntimeError(f"the phone has {shown['name']!r} for the iPhone's {ios.name!r}")
    return {"name": shown["name"]}


def _message(line: dict, body: str) -> bool:
    return line.get("event") == "message" and line.get("body") == body


def _delivered(node: Node, sent: dict, timeout: float) -> dict:
    started = time.monotonic()
    node.wait(lambda line: line.get("event") == "delivered" and line.get("id") == sent.get("id"), timeout)
    return {"seconds": round(time.monotonic() - started, 1)}


def _timed(check, timeout: float) -> dict:
    started = time.monotonic()
    poll(check, timeout, every=0.5)
    return {"seconds": round(time.monotonic() - started, 1)}


PROTECTED_UNTIL_FIRST_UNLOCK = "NSFileProtectionCompleteUntilFirstUserAuthentication"


def iphone_reboot(arguments: argparse.Namespace) -> int:
    """MVP item 1's second half, and the protection class P5 left to the iPhone: the identity survives a relaunch and a
    reboot. The bridge's `storage` reply says where the launch found the identity and the database. First the run
    checks the Keychain item's class, the database's protection class and its backup flag. Then someone swipes Knit
    away and opens it again, and the new process must have the same node id and skip onboarding. Then the iPhone
    restarts, by `idevicediagnostics` with --restart or by hand, and stays locked for --locked seconds from when it
    leaves USB, time for iOS to launch Knit before the first unlock if it will. Then someone unlocks it and leaves Knit
    closed for --closed seconds, time for protected data to start a launch waiting in the background, then opens Knit,
    and the same holds. The run reports whether Knit launched before that unlock, and what started it: a launch before
    the unlock waits for protected data rather than making new keys (ADR 2026-09.tkww)."""
    ios = IPhone(arguments.udid)
    run = Run()
    try:
        ios.start()
    except TimeoutError:
        print(json.dumps({"action": "open Knit"}), flush=True)
        _reopened(ios, arguments.unlock_wait)
    print(json.dumps({"run": "iphone-reboot", "iphone": ios.node_id, "udid": ios.udid, "locked": arguments.locked}), flush=True)
    before: dict = {}
    try:
        before = run.step("storage", lambda: _storage(ios)) or {}
        if before:
            run.step("keychain-after-first-unlock-this-device-only", lambda: _keychain_class(before))
            run.step("database-protected-until-first-unlock", lambda: _database_class(before))
            run.step("database-out-of-backups", lambda: _out_of_backups(before))
            run.step("onboarded", lambda: _onboarded(before))
    finally:
        ios.stop()
    if not before:
        print(json.dumps({"summary": "iphone-reboot", "steps": run.steps, "failed": run.failed}))
        return run.failed
    if not arguments.skip_relaunch:
        print(json.dumps({"action": "swipe Knit away in the app switcher, then open it again"}), flush=True)
        relaunched = run.step("knit-relaunched", lambda: _relaunched(ios, before, arguments.unlock_wait))
        if relaunched is not None:
            run.step("relaunch-keeps-identity", lambda: _kept(before, relaunched["storage"], rebooted=False))
    if arguments.restart:
        run.step("restart-asked", lambda: _restart(ios.udid))
    else:
        print(json.dumps({"action": "restart the iPhone, and leave it locked until asked"}), flush=True)
    restarted = run.step("iphone-restarted", lambda: _usb_restart(ios.udid, arguments.locked, arguments.unlock_wait))
    if restarted is not None:
        time.sleep(arguments.closed)
        print(json.dumps({"action": "open Knit"}), flush=True)
        opened = run.step("knit-opened", lambda: _reopened(ios, arguments.unlock_wait))
        if opened is not None:
            try:
                after = _storage(ios)
                run.step("reboot-keeps-identity", lambda: _kept(before, after, rebooted=True))
                run.step("database-protected-after-reboot", lambda: _database_class(after))
                run.step("launch-after-reboot", lambda: _launch_after_reboot(after, restarted["back"], opened["wall"]))
                run.step("mesh-running", lambda: _timed(lambda: ios.command(cmd="status")["running"], 30))
            finally:
                ios.stop()
    print(json.dumps({"summary": "iphone-reboot", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _storage(ios: IPhone) -> dict:
    reply = ios.command(cmd="storage")
    if not reply.get("ok"):
        raise RuntimeError(f"the bridge refused storage: {reply.get('error')}, or this build predates it")
    return {key: value for key, value in reply.items() if key not in ("_at", "tag", "reply", "ok")}


def _keychain_class(storage: dict) -> dict:
    keychain = storage["keychain"]
    if not keychain.get("readable") or not keychain.get("afterFirstUnlockThisDeviceOnly"):
        raise RuntimeError(f"the identity's Keychain item: {keychain}")
    return {"accessible": keychain["accessible"]}


def _database_class(storage: dict) -> dict:
    protection = storage["database"]["protection"]
    missing = {"directory", "knit.sqlite"} - protection.keys()
    wrong = {name: value for name, value in protection.items() if value != PROTECTED_UNTIL_FIRST_UNLOCK}
    if missing or wrong:
        raise RuntimeError(f"missing {sorted(missing)}, other classes {wrong}")
    return {"files": sorted(protection)}


def _out_of_backups(storage: dict) -> dict:
    if storage["database"]["excludedFromBackup"] is not True:
        raise RuntimeError(f"the database directory's backup flag is {storage['database']['excludedFromBackup']}")
    return {}


def _onboarded(storage: dict) -> dict:
    if storage["onboarded"] is not True:
        raise RuntimeError("the launch does not remember onboarding, so it shows onboarding again")
    return {}


def _relaunched(ios: IPhone, before: dict, timeout: float) -> dict:
    """Asks the bridge afresh every few seconds until a Knit process other than the one `before` came from answers.
    A connection open when Knit closes never hears it: iproxy keeps its end open."""
    started = time.monotonic()
    while True:
        try:
            ios.start()
            storage = _storage(ios)
            if storage["launch"]["startedAt"] != before["launch"]["startedAt"]:
                return {"seconds": round(time.monotonic() - started, 1), "storage": storage}
        except (TimeoutError, OSError):
            pass
        finally:
            ios.stop()
        if time.monotonic() - started > timeout:
            raise TimeoutError("no new Knit process answered: Knit was not closed and opened again")
        time.sleep(2)


def _kept(before: dict, after: dict, rebooted: bool) -> dict:
    """The launch after is a new process, after a reboot when asked, with the identity and onboarding of the one
    before."""
    problems = []
    if after["nodeId"] != before["nodeId"]:
        problems.append(f"node id {before['nodeId']} became {after['nodeId']}")
    if after["launch"]["startedAt"] <= before["launch"]["startedAt"]:
        problems.append("the same process answered: Knit was not closed")
    booted = (after["bootedAt"] or 0) > (before["bootedAt"] or 0) + 1000
    if booted != rebooted:
        problems.append("the iPhone restarted" if booted else "the iPhone did not restart")
    if not after["keychain"].get("readable"):
        problems.append(f"the keys did not read: {after['keychain']}")
    if after["onboarded"] is not True:
        problems.append("onboarding is not remembered, so it shows again")
    if problems:
        raise RuntimeError("; ".join(problems))
    return {"nodeId": after["nodeId"], "readyBy": after["launch"]["readyBy"]}


def _restart(udid: str) -> dict:
    subprocess.run(["idevicediagnostics", "restart", "-u", udid], capture_output=True, text=True, timeout=30, check=True)
    return {}


def _usb_restart(udid: str, locked: float, timeout: float) -> dict:
    """Waits for the iPhone to leave usbmuxd's list, keeps it locked for `locked` seconds from then, asks for the
    unlock, and waits for it to come back. A phone with a passcode stays off USB until its first unlock (USB Restricted
    Mode), so it comes back only at the unlock; one without comes back while still locked."""
    started = time.monotonic()

    def listed() -> bool:
        result = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, timeout=10, check=False)
        return udid in result.stdout.split()

    poll(lambda: not listed(), timeout, every=1)
    gone = time.monotonic()
    print(json.dumps({"action": f"leave the iPhone locked for {locked:.0f} s"}), flush=True)
    time.sleep(locked)
    print(json.dumps({"action": "unlock the iPhone, and leave Knit closed"}), flush=True)
    poll(listed, timeout, every=1)
    return {"goneAfter": round(gone - started, 1), "backAfter": round(time.monotonic() - gone, 1), "back": time.time()}


def _launch_after_reboot(storage: dict, back: float, opened: float) -> dict:
    """How Knit came up after the reboot. A launch made before the first unlock waited for protected data; one that
    needed Retry left someone looking at the waiting screen with the phone unlocked."""
    launch = storage["launch"]
    before_unlock = launch["waited"] is not None
    detail = {
        "launchedBeforeUnlock": before_unlock,
        "waited": launch["waited"],
        "readyBy": launch["readyBy"],
        "launchedAfterBoot": round((launch["startedAt"] - storage["bootedAt"]) / 1000, 1),
        "launchedAfterUsb": round(launch["startedAt"] / 1000 - back, 1),
        "readyBeforeOpened": round(opened - launch["readyAt"] / 1000, 1),
    }
    if launch["readyBy"] == "retry":
        raise RuntimeError(f"Knit started only from Retry: {detail}")
    return detail


def bridge(arguments: argparse.Namespace) -> int:
    """Sends each command to the iPhone's bridge and prints its reply, then prints its events for --watch seconds."""
    ios = IPhone(arguments.udid)
    ios.start()
    try:
        print(json.dumps({"ready": ios.node_id, "name": ios.name}), flush=True)
        for text in arguments.commands:
            reply = ios.command(**json.loads(text))
            print(json.dumps({key: value for key, value in reply.items() if key not in ("_at", "tag")}), flush=True)
        deadline = time.monotonic() + arguments.watch
        printed = 0
        while time.monotonic() < deadline:
            with ios.arrived:
                ios.arrived.wait(min(1, max(0, deadline - time.monotonic())))
                fresh = ios.seen[printed:]
                printed = len(ios.seen)
            for line in fresh:
                if line.get("event") not in (None, "ready"):
                    print(json.dumps({key: value for key, value in line.items() if key != "_at"}), flush=True)
    finally:
        ios.stop()
    return 0


def refusal(arguments: argparse.Namespace) -> int:
    """Checklist L's third group, against Android 2.7 only: with the `ios` profile 2.7 cannot see the peer, so the peer
    dials, and Android's responder closes a dialer whose id sorts below its own (`BluetoothMeshTransport.kt:754`). The
    link never comes up; companion change A1 is what lets it. Every A1 build admits the unsighted dialer this expects
    to be refused, and an A3 build reads the peer's payload and dials it, so against either it fails by design: run it
    only against a 2.7 build."""
    phone = Phone(arguments.device)
    run = Run()
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    peer_id = keygen(phone_id, "phone-dials", others)
    print(json.dumps({"run": "refusal", "phone": phone_id, "peer": peer_id, "refused": sorted(others)}))
    log = ROOT / ".build" / "interop-peer.log"
    before = log.stat().st_size if log.exists() else 0
    peer = Peer("ios", "knit-peer refusal", others, "debug", arguments.rssi_floor)
    peer.start()
    try:
        deadline = time.monotonic() + arguments.seconds
        while time.monotonic() < deadline:
            phone.wake()
            time.sleep(15)
        messages = [json.loads(line).get("message", "") for line in log.read_text(encoding="utf-8")[before:].splitlines() if line]
        dials = [re.search(r" on (ch\d+)$", m).group(1) for m in messages if f"dialing {phone_id}" in m]
        connected = {m.split()[1] for m in messages if m.endswith(" connected")}
        ended = {m.split()[1] for m in messages if m.endswith(" ended")}
        refused = [channel for channel in dials if channel in connected and channel in ended]
        ups = peer.lines(lambda line: line.get("event") == "link" and line.get("peer") == phone_id and line.get("up"))
        run.step("peer-dials-the-phone", lambda: {"dials": len(dials)} if dials else _fail("the peer never dialed"))
        # Android closes a lower dialer right after reading its HELLO, without a reply and without a log line:
        # a dial that opened and then ended, as opposed to one that never connected.
        run.step("phone-closes-the-dial-after-its-hello", lambda: {"refused": len(refused)} if refused else _fail("no dial got as far"))
        run.step("never-linked", lambda: {} if not ups else _fail(f"linked {len(ups)} times"))
    finally:
        peer.stop()
    print(json.dumps({"summary": "refusal", "steps": run.steps, "failed": run.failed}))
    return run.failed


def replace(arguments: argparse.Namespace) -> int:
    """Companion change A1's stale-link rule on hardware, with a peer the phone never sighted (the `ios` profile)
    and a second knit-peer with the same identity. Android 2.7 refuses every second dial as a duplicate.

    1. **The hold.** The first process links, and the second dials at once. An A1 phone refuses it while the held
        link is under 30 s old (`REPLACE_MIN_HOLD_MS`). The refused process then does what the radio always does
        when its last channel on a device closes, and disconnects the phone, which ends the shared ACL and the
        first link with it: a cost of running both on one adapter.
    2. **The replacement.** The first process links again, then freezes: the kernel keeps its channel up, so the
        phone's link stays open but goes quiet, as it does when a peer's end dies first. Once that link is 30 s
        old the second process dials. The phone replaces the old link (logged `Replace, sighted=false`) and keeps
        the new one: the old link's end must not take it down, and nothing else may drop it meanwhile.

    Both processes serve the doorbell without the payload (`--no-gatt-payload`), so a phone with companion change A3
    files the peer as a stranger and never sights it, and A1's unsighted rules are the ones under test. Their id sorts
    above the phone's: below a phone that sets FLAG_DIALS_GATT_PEERS the peer would wait for a dial that never comes.
    A1 replaces an unsighted dialer's stale link whatever the order (`BleAdmissionPolicy.decide`)."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    peer_id = keygen(phone_id, "peer-dials", others)
    print(json.dumps({"run": "replace", "phone": phone_id, "peer": peer_id, "refused": sorted(others)}))
    state = Path.home() / ".local" / "state" / "knit-peer"
    name = f"knit-peer {nonce}"
    # Both processes refuse the phone until both are up, so neither one's start releases the other's link. The
    # second copies the first's state once the first has published its profile, so the two publish the same
    # profile frame; different stamps under one identity would be a clone, and custody would never converge.
    first = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor, gatt_payload=False)
    first.start()
    shutil.copytree(state / INSTANCE, state / f"{INSTANCE}-b", dirs_exist_ok=True)
    second = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor, instance=f"{INSTANCE}-b", gatt_payload=False)
    second.start()
    phone.shell("logcat -c")
    try:
        first.command(cmd="allow-link", peer=phone_id)
        run.step("hold-first-link", lambda: link_up(first, phone, phone_id) and {})
        second.command(cmd="allow-link", peer=phone_id)
        run.step("phone-refused-inside-the-hold", lambda: poll(lambda: _refused_inside_hold(phone, peer_id), 90, every=1))
        second.command(cmd="deny-link", peer=phone_id)
        first.stop()
        time.sleep(5)
        phone.shell("logcat -c")
        first = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor, gatt_payload=False)
        first.start()
        first.command(cmd="allow-link", peer=phone_id)
        run.step("first-link", lambda: link_up(first, phone, phone_id) and {})
        linked_at = time.monotonic()
        assert first.process
        first.process.send_signal(signal.SIGSTOP)
        time.sleep(max(0.0, linked_at + 31 - time.monotonic()))
        second.command(cmd="allow-link", peer=phone_id)
        run.step("second-link", lambda: link_up(second, phone, phone_id) and {})
        run.step("phone-replaced-the-stale-link", lambda: poll(lambda: _replaced(phone, peer_id), 20))
        # The frozen process has done its part. Left frozen, it still holds an advert and a GATT application in
        # bluetoothd that no longer answer, and bluetoothd then ended the whole ACL about a minute later. Killed,
        # it releases them without the clean exit that would disconnect the phone.
        first.process.kill()
        first.process.wait()
        first.process = None
        # A fresh link starts with the phone's back-fill, and a post queues behind it (see `check`).
        run.step("custody-after-replace", lambda: _custody_after_replace(second, phone))
        for turn in range(2):
            body = f"interop replace from phone {nonce} {turn}"
            phone.send(body)
            run.step(
                f"new-link-carries-phone-to-peer-{turn}",
                lambda b=body: _latency(second.wait(lambda line: line.get("event") == "message" and line.get("body") == b, 20)),
            )
            body = f"interop replace from peer {nonce} {turn}"
            second.command(cmd="room", text=body)
            run.step(f"new-link-carries-peer-to-phone-{turn}", lambda b=body: poll(lambda: _has(phone.state("nearby"), b), 15) and {})
            time.sleep(30)
        run.step("new-link-still-up", lambda: _still_linked(phone, peer_id))
    finally:
        if first.process:
            first.process.kill()
            first.process = None
        second.stop()
        shutil.rmtree(state / f"{INSTANCE}-b", ignore_errors=True)
    print(json.dumps({"summary": "replace", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _custody_after_replace(peer: Peer, phone: Phone) -> dict:
    """A replaced link is the same neighbour to the phone, so it does not push its profile again the way a new
    link does; its frames reach this fresh process by back-fill, ahead of the key they verify against. Those are
    dropped, 16 of them parked, and all marked seen, so their re-serves are duplicates for the SeenSet's 10
    minutes (Android's pipeline does the same). Custody converges after that; the run does not wait for it, but
    it does check that the key is the whole story."""
    return _converges_unless_keyless(peer, phone, 120)


def _converges_unless_keyless(peer: Peer, phone: Phone, timeout: float) -> dict:
    """Custody converges within `timeout`, or the difference is only frames the phone holds and the peer dropped for
    want of their sender's key."""
    try:
        return _converges(peer, phone, timeout)
    except TimeoutError:
        dropped = peer.command(cmd="status")["dropped"]
        difference = dict(LAST_CUSTODY_DIFFERENCE)
        if difference.get("onlyPeer") or not dropped.get("noSenderKey"):
            raise RuntimeError(f"custody differs, and not for want of the key: {difference}, dropped {dropped}") from None
        return {
            "converged": False,
            "onlyPhone": difference["counts"]["onlyPhone"],
            "sample": difference["onlyPhone"],
            "noSenderKey": dropped["noSenderKey"],
        }


def _custody_converges_with_keys(peer: Peer, phone: Phone, timeout: float, served_before: int) -> dict:
    """knit-next ADR 2026-09.g64k: a phone that keeps the signed profile each pin came from sends a sender's key
    ahead of their backlog, so a fresh peer keeps all of it and custody converges. The phone kept no such profile
    before database v16, so a sender it pinned before its upgrade still reaches the peer keyless, and those frames
    stay behind until they expire: that difference is allowed, and counted. `keysServed` counts every key the phone
    handed any neighbour during the step, this peer's among them."""
    started = time.monotonic()
    result = _converges_unless_keyless(peer, phone, timeout)
    served = phone.state()["metrics"].get("keysServed", 0) - served_before
    return {**result, "seconds": round(time.monotonic() - started), "keysServed": served}


def _refused_inside_hold(phone: Phone, peer_id: str) -> dict | None:
    log = phone.shell("logcat -d -s BluetoothMeshTransport:*")
    ages = [int(age) for age in re.findall(rf"bt refused client {peer_id} \(sighted=false heldAgeMs=(\d+)\)", log)]
    young = [age for age in ages if age < 30_000]
    return {"refusedAtHeldAgeMs": young} if young else None


def _replaced(phone: Phone, peer_id: str) -> dict | None:
    log = phone.shell("logcat -d -s BluetoothMeshTransport:*")
    lines = [line.split(": ", 1)[-1] for line in log.splitlines() if f"client {peer_id}" in line or f"link down: {peer_id}" in line]
    return {"phoneLog": lines} if any("Replace" in line for line in lines) else None


def _still_linked(phone: Phone, peer_id: str) -> dict:
    log = phone.shell("logcat -d -s BluetoothMeshTransport:*")
    downs = [line.split(": ", 1)[-1] for line in log.splitlines() if f"link down: {peer_id}" in line]
    if downs:
        raise RuntimeError(f"the phone dropped the link: {downs}")
    if not any(p["nodeId"] == peer_id for p in phone.state()["reachable"]):
        raise RuntimeError("the phone no longer holds the peer")
    return {}


def _fail(reason: str) -> dict:
    raise RuntimeError(reason)


def soak(arguments: argparse.Namespace) -> int:
    """MVP item 11 against one phone: an hour of room traffic both ways at `--per-minute` posts a minute, both sides
    together (Android refuses more than 30 a minute on a link). With `--extras`, the phone also reacts to the peer's
    posts, sends typing cues, DMs and photos, and the peer DMs back, so the peer meets reactions, typing, FILE records
    and the phone's requests while the room runs.

    It passes with no link drop the peer caused, no crash, every post of each side arriving and the peer's ticked,
    custody and the SeenSet under their caps, memory flat through the second half, and custody converged at the end.
    Everything lands in `.build/interop-soak/<start>/`: the peer's log, `samples.jsonl` and `summary.json`."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    peer_id = keygen(phone_id, "peer-dials", others)
    out = ROOT / ".build" / "interop-soak" / time.strftime("%Y%m%d-%H%M")
    out.mkdir(parents=True, exist_ok=True)
    header = {"run": "soak", "phone": phone_id, "peer": peer_id, "refused": sorted(others), "out": str(out), **vars(arguments)}
    print(json.dumps(header))
    image = _stage_image(phone) if arguments.extras else None
    peer = Peer(arguments.radio_profile, f"knit-peer soak {nonce}", others, arguments.peer_log, arguments.rssi_floor, log_path=out / "peer.log")
    peer.start()
    stop = threading.Event()
    threading.Thread(target=_keep_to, args=(peer, {phone_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
    traffic = SoakTraffic(peer, phone, peer_id, phone_id, image)
    samples: list[dict] = []
    try:
        run.step("link", lambda: link_up(peer, phone, phone_id) and {})
        # The phone back-fills every frame the peer lacks first, one record per write; timing starts after it.
        run.step("custody-converges-first", lambda: _converges(peer, phone, 420))
        interval = 60 / arguments.per_minute
        started = time.monotonic()
        end = started + arguments.minutes * 60
        next_sample = started
        while time.monotonic() < end:
            beat = time.monotonic()
            traffic.post()
            if arguments.extras and traffic.turn % SoakTraffic.EXTRA_EVERY == 0:
                traffic.extra()
            if beat >= next_sample:
                samples.append(_sample(peer, round(beat - started)))
                print(json.dumps({"sample": samples[-1]}))
                sys.stdout.flush()
                next_sample += 120
            time.sleep(max(0.0, interval - (time.monotonic() - beat)))
        time.sleep(20)
        samples.append(_sample(peer, round(time.monotonic() - started)))
        run.step("peer-alive", lambda: _alive(peer))
        run.step("no-link-dropped-by-us", lambda: _endings(out / "peer.log"))
        run.step("phone-posts-arrived", lambda: _all(traffic.phone_bodies, traffic.heard()))
        run.step("peer-posts-ticked", lambda: traffic.ticks())
        shown = {message["body"] for message in phone.state("nearby", limit=200).get("messages", [])}
        run.step("peer-posts-on-phone", lambda: _all(set(list(traffic.peer_posts.values())[-60:]), shown))
        run.step("phone-latency", lambda: traffic.latency())
        if arguments.extras:
            run.step("extras", lambda: traffic.extras_report())
        run.step("footprint-bounded", lambda: _footprint(samples))
        run.step("memory-flat", lambda: _memory(samples))
        run.step("custody-converges-at-end", lambda: _converges(peer, phone, 300))
    finally:
        stop.set()
        peer.stop()
    summary = {"summary": "soak", "turns": traffic.turn, "steps": run.steps, "failed": run.failed, "failures": traffic.failures}
    (out / "samples.jsonl").write_text("".join(json.dumps(sample) + "\n" for sample in samples), encoding="utf-8")
    (out / "summary.json").write_text(json.dumps({**summary, "run": header, "results": run.results}, indent=1), encoding="utf-8")
    print(json.dumps(summary))
    return run.failed


class SoakTraffic:
    """What the soak sends, and what it made of the answers. Bodies start with "soak " so knit-next's
    `.private/scripts/soak/cleanup.sh` purges them from the phones afterwards."""

    # One extra every so many posts, round-robin through EXTRAS.
    EXTRA_EVERY = 15
    EXTRAS = ("react", "typing", "dm-from-phone", "dm-from-peer", "photo")

    def __init__(self, peer: Peer, phone: Phone, peer_id: str, phone_id: str, image: str | None) -> None:
        self.peer = peer
        self.phone = phone
        self.peer_id = peer_id
        self.phone_id = phone_id
        self.image = image
        self.turn = 0
        self.extra_turn = 0
        self.peer_posts: dict[str, str] = {}  # id -> body
        self.posted_at: dict[str, float] = {}  # id -> monotonic
        self.phone_bodies: set[str] = set()
        self.photo_bodies: set[str] = set()
        self.phone_dms: set[str] = set()
        self.peer_dms: dict[str, str] = {}
        self.extras: dict[str, int] = dict.fromkeys(self.EXTRAS, 0)
        self.failures: dict[str, int] = {}

    def _try(self, what: str, action) -> object:
        try:
            return action()
        except (RuntimeError, TimeoutError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            self.failures[what] = self.failures.get(what, 0) + 1
            print(json.dumps({"failed": what, "error": str(error)[:200]}))
            sys.stdout.flush()
            return None

    def post(self) -> None:
        stamp = time.strftime("%H%M%S")
        if self.turn % 2 == 0:
            body = f"soak mvp11 #{self.turn} peer {stamp}"
            reply = self._try("peer-post", lambda: self.peer.command(cmd="room", text=body))
            if reply and reply.get("id"):
                self.peer_posts[reply["id"]] = body
                self.posted_at[reply["id"]] = time.monotonic()
        else:
            body = f"soak mvp11 #{self.turn} phone {stamp}"
            if self._try("phone-post", lambda: self.phone.send(body)) is not None:
                self.phone_bodies.add(body)
        self.turn += 1

    def extra(self) -> None:
        kind = self.EXTRAS[self.extra_turn % len(self.EXTRAS)]
        self.extra_turn += 1
        stamp = time.strftime("%H%M%S")
        n = self.extras[kind]
        if kind == "react" and self.peer_posts:
            latest = next(reversed(self.peer_posts))
            done = self._try(kind, lambda: self.phone.bridge("REACT", id=latest, emoji="\U0001f44d"))
        elif kind == "typing":
            done = self._try(kind, lambda: self.phone.bridge("TYPING", conv=self.peer_id))
        elif kind == "dm-from-phone":
            body = f"soak mvp11 dm #{n} phone {stamp}"
            done = self._try(kind, lambda: self.phone.send(body, conversation=self.peer_id))
            if done is not None:
                self.phone_dms.add(body)
                if n == 0:
                    # The first is a message request; accepting it lets the peer's own DMs through as replies.
                    self._try("accept", lambda: self.peer.wait(lambda line: line.get("body") == body, 60))
                    self._try("accept", lambda: self.peer.command(cmd="accept", conv=self.phone_id))
        elif kind == "dm-from-peer":
            body = f"soak mvp11 dm #{n} peer {stamp}"
            done = self._try(kind, lambda: self.peer.command(cmd="dm", to=self.phone_id, text=body))
            if done and done.get("id"):
                self.peer_dms[done["id"]] = body
        elif kind == "photo" and self.image:
            body = f"soak mvp11 photo #{n} {stamp}"
            done = self._try(kind, lambda: self.phone.bridge("SENDIMG", path=self.image, text=body, conv="nearby"))
            if done is not None:
                self.photo_bodies.add(body)
        else:
            done = None
        if done is not None:
            self.extras[kind] += 1

    def heard(self) -> set[str]:
        return {line.get("body") for line in self.peer.lines(lambda line: line.get("event") == "message")}

    def _delivered(self) -> dict[str, float]:
        return {line["id"]: line["_at"] for line in self.peer.lines(lambda line: line.get("event") == "delivered")}

    def ticks(self) -> dict:
        delivered = self._delivered()
        waits = sorted(delivered[i] - self.posted_at[i] for i in self.peer_posts if i in delivered)
        missing = [body for i, body in self.peer_posts.items() if i not in delivered]
        detail = {"ticked": len(waits), "of": len(self.peer_posts), "medianS": _at(waits, 0.5), "p90S": _at(waits, 0.9), "maxS": _at(waits, 1)}
        if missing:
            raise RuntimeError(f"{len(missing)} unticked, first {missing[:3]}: {detail}")
        return detail

    def latency(self) -> dict:
        """The phone's posts, from its clock to ours: MVP item 4 wants 5 s over a live link."""
        waits = sorted(
            (line["arrivedAt"] - line["sentAt"]) / 1000
            for line in self.peer.lines(lambda line: line.get("event") == "message" and line.get("body") in self.phone_bodies)
            if line.get("arrivedAt") and line.get("sentAt")
        )
        detail = {"posts": len(waits), "medianS": _at(waits, 0.5), "p90S": _at(waits, 0.9), "maxS": _at(waits, 1)}
        detail["withinFiveSeconds"] = len([w for w in waits if w <= 5])
        return detail

    def extras_report(self) -> dict:
        heard = self.heard()
        delivered = self._delivered()
        status = self.peer.command(cmd="status")
        detail = {
            "sent": self.extras,
            "photosHeard": len(self.photo_bodies & heard),
            "phoneDmsHeard": len(self.phone_dms & heard),
            "peerDmsDelivered": len([i for i in self.peer_dms if i in delivered]),
            "fileRecords": status.get("fileRecords"),
            "router": status.get("router"),
        }
        problems = []
        if self.photo_bodies - heard:
            problems.append(f"{len(self.photo_bodies - heard)} photo captions never arrived")
        if self.phone_dms - heard:
            problems.append(f"{len(self.phone_dms - heard)} of the phone's DMs never arrived")
        if detail["peerDmsDelivered"] < len(self.peer_dms):
            problems.append(f"{len(self.peer_dms) - detail['peerDmsDelivered']} of the peer's DMs never ticked")
        if problems:
            raise RuntimeError(f"{'; '.join(problems)}: {detail}")
        return detail


def _stage_image(phone: Phone) -> str:
    """A small JPEG copied into the app's own storage, where SENDIMG can read it (scoped storage keeps the app off
    /sdcard). Only the debug build's files directory changes."""
    local = ROOT / ".build" / "interop-soak" / "soak-photo.jpg"
    if not local.exists():
        from PIL import Image  # noqa: PLC0415 - only the photo extra needs it

        Image.effect_noise((320, 240), 64).convert("RGB").save(local, quality=70)
    subprocess.run(["adb", "-s", phone.serial, "push", str(local), "/data/local/tmp/knit-soak.jpg"], capture_output=True, check=True, timeout=60)
    phone.shell(f"cat /data/local/tmp/knit-soak.jpg | run-as {PACKAGE} sh -c 'cat > files/knit-soak.jpg'")
    return f"/data/data/{PACKAGE}/files/knit-soak.jpg"


def _sample(peer: Peer, elapsed: int) -> dict:
    status = peer.command(cmd="status")
    sample = {"t": elapsed, **{key: status.get(key) for key in ("links", "custody", "dropped", "fileRecords", "footprint", "router")}}
    if peer.process:
        for line in Path(f"/proc/{peer.process.pid}/status").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition(":")
            if key == "VmRSS":
                sample["rssKb"] = int(value.split()[0])
    return sample


def _endings(log: Path) -> dict:
    sys.path.insert(0, str(ROOT / "scripts"))
    from soak import link_endings  # noqa: PLC0415 - the one classifier, shared with the night soak

    endings, reasons = link_endings(log)
    ours = [ending for ending in endings if ending["reason"].startswith("ours")]
    if ours:
        raise RuntimeError(f"{len(ours)} of {len(endings)} links ended by us: {dict(reasons)}")
    return {"endings": len(endings), "reasons": dict(reasons)}


def _footprint(samples: list[dict]) -> dict:
    footprints = [sample["footprint"] for sample in samples if sample.get("footprint")]
    if not footprints:
        raise RuntimeError("no footprint sampled")
    peaks = {key: max(f[key] for f in footprints) for key in footprints[0]}
    custody = max(sample.get("custody") or 0 for sample in samples)
    if peaks.get("seen", 0) > SEEN_CAP or custody > CUSTODY_CAP:
        raise RuntimeError(f"over a cap: seen {peaks.get('seen')}, custody {custody}")
    return {"peaks": peaks, "custodyPeak": custody, "last": footprints[-1]}


def _memory(samples: list[dict]) -> dict:
    """Flat means the second half's resident size grew less than 8 MB: the first minutes fill caches and tables."""
    sizes = [(sample["t"], sample["rssKb"]) for sample in samples if sample.get("rssKb")]
    half = [kb for t, kb in sizes if t >= sizes[-1][0] / 2]
    if not half:
        raise RuntimeError("no memory sampled")
    growth = half[-1] - half[0]
    detail = {"firstKb": sizes[0][1], "halfKb": half[0], "lastKb": half[-1], "peakKb": max(kb for _, kb in sizes)}
    if growth > 8 * 1024:
        raise RuntimeError(f"grew {growth} kB in the second half: {detail}")
    return detail


def _at(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    return round(values[min(len(values) - 1, int(fraction * len(values)))], 1)


def relay(arguments: argparse.Namespace) -> int:
    """MVP item 7's line, rehearsed with two peers: the phone, then peer A on hci1 standing in for the iPhone, then
    peer B on hci0, which refuses the phone. B links to A alone, so whatever B hears from the phone, and the phone
    from B, crossed A. Both peers sort above every phone in range, so no phone dials either; A sorts above B and dials
    both the phone and B."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    b_id = _keygen("relay-b", "--above", max(others | {phone_id}))
    a_id = _keygen("relay-a", "--above", b_id)
    print(json.dumps({"run": "relay", "phone": phone_id, "a": a_id, "b": b_id, "refused": sorted(others)}))
    b = Peer("android", f"knit-peer B {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "relay-b", HCI0)
    a = Peer(arguments.radio_profile, f"knit-peer A {nonce}", others, arguments.peer_log, arguments.rssi_floor, "relay-a")
    b.start()
    a.start()
    stop = threading.Event()
    threading.Thread(target=_keep_to, args=(b, {a_id}, set(b.refuse), stop, b.instance), daemon=True).start()
    threading.Thread(target=_keep_to, args=(a, {phone_id, b_id}, set(a.refuse), stop, a.instance), daemon=True).start()
    try:
        run.step("link-a-b", lambda: a.wait(lambda line: _link(line, b_id), 180) and b.wait(lambda line: _link(line, a_id), 10) and {})
        run.step("link-a-phone", lambda: link_up(a, phone, phone_id) and {})
        run.step("phone-profile-reaches-b", lambda: {"name": b.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 240)["displayName"]})
        # The phone back-fills a newcomer at under a frame a second while it serves its other links, and its own new
        # frames queue behind that, so the room and DM steps wait for it.
        run.step("custody-a-phone", lambda: _converges(a, phone, 900))
        run.step("custody-b-a", lambda: _peers_converge(b, a, 180))
        body = f"interop relay room from phone {nonce}"
        phone.send(body)
        run.step("room-phone-to-b", lambda: _latency(b.wait(lambda line: line.get("event") == "message" and line.get("body") == body, 30)))
        body = f"interop relay room from b {nonce}"
        b.command(cmd="room", text=body)
        run.step("room-b-to-phone", lambda: poll(lambda: _has(phone.state("nearby"), body), 30) and {})
        first = f"interop relay dm from phone {nonce}"
        phone.send(first, conversation=b_id)
        run.step("dm-phone-to-b-is-a-request", lambda: _request(b.wait(lambda line: line.get("event") == "message" and line.get("body") == first, 60)))
        b.command(cmd="accept", conv=phone_id)
        body = f"interop relay dm from b {nonce}"
        sent = b.command(cmd="dm", to=phone_id, text=body)
        run.step("dm-b-to-phone-delivered", lambda: b.wait(lambda line: line.get("event") == "delivered" and line.get("id") == sent.get("id"), 60) and {})
        run.step("dm-b-to-phone-shown", lambda: poll(lambda: _has(phone.state(b_id), body), 30) and {})
        run.step("dm-phone-to-b-ticked", lambda: poll(lambda: _received(phone.state(b_id), first), 60) and {})
        run.step("custody-b-phone", lambda: _converges(b, phone, 420))
        run.step("a-relayed", lambda: _relayed(a))
        run.step("b-never-linked-phone", lambda: _never_linked(b, phone_id))
        run.step("no-link-dropped-a", lambda: _no_link_dropped(a))
        run.step("no-link-dropped-b", lambda: _no_link_dropped(b))
    finally:
        stop.set()
        a.stop()
        b.stop()
    print(json.dumps({"summary": "relay", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone_relay(arguments: argparse.Namespace) -> int:
    """MVP item 7: the phone, then the iPhone, then knit-peer on hci0, which refuses the phone. The peer links to the
    iPhone alone, so whatever the peer hears from the phone, and the phone from the peer, crossed the iPhone. The
    iPhone refuses every node but the phone and the peer, which makes the line the one `relay` rehearses, and it
    lets those nodes link again at the end.

    The peer runs in the `android` profile, which leaves FLAG_DIALS_GATT_PEERS clear, so the iPhone dials it, and it
    sorts above every phone in range, so no phone dials it. It runs on hci0 because the iPhone's writes to hci1
    stall after the HELLO (.agents/context/linux-peer.md)."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id) - {ios.node_id}
    peer_id = _keygen("iphone-relay", "--above", max(others | {phone_id}))
    print(json.dumps({"run": "iphone-relay", "phone": phone_id, "iphone": ios.node_id, "peer": peer_id, "refused": sorted(others)}))
    before = ios.command(cmd="status")["router"]
    stop = threading.Event()
    kept_off: set[str] = set()
    threading.Thread(target=_keep_to, args=(ios, {phone_id, peer_id}, kept_off, stop, "iphone"), daemon=True).start()
    peer = Peer(
        arguments.radio_profile, f"knit-peer relay {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "iphone-relay", HCI0
    )
    try:
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("link-iphone-phone", lambda: _ios_linked(ios, phone, phone_id))
        run.step("link-iphone-peer", lambda: _timed(lambda: peer.lines(lambda line: _link(line, ios.node_id)), 180))
        run.step(
            "phone-profile-reaches-peer",
            lambda: {"name": peer.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 240)["displayName"]},
        )
        # The phone and the iPhone back-fill the newcomer, and new frames queue behind that, as in `relay`.
        run.step("custody-iphone-phone", lambda: _converges(ios, phone, 900))
        run.step("custody-peer-iphone", lambda: _peers_converge(peer, ios, 300))
        body = f"interop iphone relay room from phone {nonce}"
        phone.send(body)
        run.step("room-phone-to-peer", lambda: _latency(peer.wait(lambda line: _message(line, body), 30)))
        body = f"interop iphone relay room from peer {nonce}"
        peer.command(cmd="room", text=body)
        run.step("room-peer-to-phone", lambda: _timed(lambda: _has(phone.state("nearby"), body), 30))
        first = f"interop iphone relay dm from phone {nonce}"
        phone.send(first, conversation=peer_id)
        run.step("dm-phone-to-peer-is-a-request", lambda: _request(peer.wait(lambda line: _message(line, first), 60)))
        peer.command(cmd="accept", conv=phone_id)
        body = f"interop iphone relay dm from peer {nonce}"
        sent = peer.command(cmd="dm", to=phone_id, text=body)
        run.step("dm-peer-to-phone-delivered", lambda: _delivered(peer, sent, 60))
        run.step("dm-peer-to-phone-shown", lambda: _timed(lambda: _has(phone.state(peer_id), body), 30))
        run.step("dm-phone-to-peer-ticked", lambda: _timed(lambda: _received(phone.state(peer_id), first), 60))
        run.step("custody-peer-phone", lambda: _converges(peer, phone, 420))
        run.step("custody-iphone-phone-again", lambda: _converges(ios, phone, 180))
        run.step("iphone-relayed", lambda: _relayed(ios, before))
        run.step("peer-linked-only-the-iphone", lambda: _linked_only(peer, {ios.node_id}))
        run.step("no-link-dropped-peer", lambda: _no_link_dropped(peer))
        run.step("no-link-dropped-iphone", lambda: _no_link_dropped(ios, {phone_id, peer_id}))
    finally:
        stop.set()
        peer.stop()
        for node in sorted(kept_off):
            try:
                ios.command(cmd="allow-link", peer=node)
            except (TimeoutError, OSError):
                pass
        ios.stop()
    print(json.dumps({"summary": "iphone-relay", "steps": run.steps, "failed": run.failed, "keptOff": len(kept_off)}))
    return run.failed


def iphone_peer(arguments: argparse.Namespace) -> int:
    """MVP items 2 to 6 between the iPhone and knit-peer on a shared hci0, which the spec asks of the peer as well as of
    an Android phone. `--order` puts the iPhone's node id above or below a fresh peer identity, so the iPhone's first DM
    is a message request on the peer every run.

    The peer runs the `android` profile, which leaves FLAG_DIALS_GATT_PEERS clear, so the iPhone dials it in both
    orders and the peer admits it unsighted, as an A1 phone does (ADR 2026-09.6es2). The peer refuses every node but
    the iPhone, so whatever crosses between the two crossed their own link. It runs on hci0 because the iPhone's writes
    to hci1 stall after the HELLO (.agents/context/linux-peer.md)."""
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    others = others_in_range(ios.node_id)
    peer_id = _keygen("iphone-peer", *_peer_window(ios.node_id, others, arguments.order))
    print(json.dumps({"run": "iphone-peer", "iphone": ios.node_id, "peer": peer_id, "order": arguments.order, "refused": sorted(others)}))
    run.step("iphone-forgot-old-peers", lambda: _forgets_all_but(ios, others))
    stop = threading.Event()
    peer = Peer("android", f"knit-peer {nonce}", others, arguments.peer_log, arguments.rssi_floor, "iphone-peer", HCI0)
    try:
        started = time.monotonic()
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("link", lambda: _linked_since(peer, ios.node_id, started, 180))
        run.step("profile-on-iphone", lambda: _ios_pinned(ios, peer_id, peer.name))
        run.step("profile-on-peer", lambda: _peer_pinned(peer, ios))
        run.step("safety-numbers-match", lambda: _same_safety_number(ios, peer))
        # The iPhone back-fills the newcomer first, and new frames queue behind that, so posts are timed after it.
        run.step("custody-converges", lambda: _peers_converge(peer, ios, 300))
        body = f"interop room from iphone {nonce}"
        sent = ios.command(cmd="room", text=body)
        run.step("room-iphone-to-peer", lambda: _latency(peer.wait(lambda line: _message(line, body), 15)))
        run.step("room-iphone-ticked", lambda: _delivered(ios, sent, 30))
        body = f"interop room from peer {nonce}"
        sent = peer.command(cmd="room", text=body)
        run.step("room-peer-to-iphone", lambda: _latency(ios.wait(lambda line: _message(line, body), 15)))
        run.step("room-peer-ticked", lambda: _delivered(peer, sent, 30))
        first = f"interop dm from iphone {nonce}"
        sent = ios.command(cmd="dm", to=peer_id, text=first)
        run.step("dm-iphone-to-peer-is-a-request", lambda: _request(peer.wait(lambda line: _message(line, first), 20)))
        run.step("dm-iphone-to-peer-delivered", lambda: _delivered(ios, sent, 30))
        peer.command(cmd="accept", conv=ios.node_id)
        body = f"interop dm from peer {nonce}"
        sent = peer.command(cmd="dm", to=ios.node_id, text=body)
        run.step("dm-peer-to-iphone", lambda: _latency(ios.wait(lambda line: _message(line, body), 20)))
        run.step("dm-peer-to-iphone-delivered", lambda: _delivered(peer, sent, 30))
        body = f"interop dm reply from iphone {nonce}"
        sent = ios.command(cmd="dm", to=peer_id, text=body)
        run.step("dm-iphone-reply-delivered", lambda: _delivered(ios, sent, 30))
        if not arguments.skip_offline:
            _offline(run, ios, peer, peer_id, nonce)
        run.step("custody-converges-again", lambda: _peers_converge(peer, ios, 300))
    finally:
        stop.set()
        peer.stop()
        ios.stop()
    print(json.dumps({"summary": "iphone-peer", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone_soak(arguments: argparse.Namespace) -> int:
    """MVP item 11 on the iPhone: an hour of room traffic both ways between the iPhone and the Android phone, at
    `--per-minute` posts a minute in all, with Knit open on both. The iPhone refuses every other node, and lets them
    link again at the end.

    With `--peer`, knit-peer on a shared hci0 joins as a third author, linked to the iPhone alone, which makes the
    line `iphone-relay` runs: the phone's posts and the peer's reach each other only through the iPhone, so every post
    crosses both of the iPhone's links and `--per-minute` is each link's rate, relays included (Android refuses more
    than 30 a minute on a link). The peer starts with an empty store, so it asks the iPhone for the keys of the senders
    in its back-fill. With `--extras` the phone also reacts to the iPhone's posts, sends it typing cues, trades DMs
    with it and posts photos, and a peer trades DMs with the iPhone too. A photo's caption always crosses the link,
    but Android sends its FILE records only now and then (three in the peer's whole hour, the same photo each time),
    so `fileRecords` is reported, not required.

    It passes with the bridge open throughout and no crash or jetsam report for Knit, no link the iPhone or the peer
    ended, every post arriving and ticked, custody and the SeenSet under their caps, memory flat through the second
    half, and custody converged at the end. `idevicesyslog` records the iPhone's log, which says why each of its links
    ended. Knit must stay in front for the hour, so the iPhone's Auto-Lock should be Never. Everything lands in
    `.build/interop-iphone-soak/<start>/`: the iPhone's log, the peer's, `samples.jsonl` and `summary.json`."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    started_wall = time.time()
    ios.start()
    phone_id = phone.state()["self"]["nodeId"]
    out = ROOT / ".build" / "interop-iphone-soak" / time.strftime("%Y%m%d-%H%M")
    out.mkdir(parents=True, exist_ok=True)
    others: set[str] = set()
    peer_id = ""
    if arguments.peer:
        others = others_in_range(phone_id) - {ios.node_id}
        peer_id = _keygen("iphone-soak", "--above", max(others | {phone_id}))
    partners = {phone_id} | ({peer_id} if peer_id else set())
    header = {**vars(arguments), "run": "iphone-soak", "iphone": ios.node_id, "phone": phone_id, "peer": peer_id or None, "out": str(out)}
    print(json.dumps(header), flush=True)
    syslog = IPhoneLog(ios.udid, out / "iphone.log")
    image = _stage_image(phone) if arguments.extras else None
    stop = threading.Event()
    kept_off: set[str] = set()
    threading.Thread(target=_keep_to, args=(ios, partners, kept_off, stop, "iphone"), daemon=True).start()
    peer: Peer | None = None
    samples: list[dict] = []
    traffic: IPhoneSoakTraffic | None = None
    try:
        if peer_id:
            peer = Peer(
                "android", f"knit-peer soak {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "iphone-soak", HCI0, out / "peer.log"
            )
            peer.start()
            threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        traffic = IPhoneSoakTraffic(ios, phone, peer, phone_id, image)
        run.step("link-iphone-phone", lambda: _ios_linked(ios, phone, phone_id))
        if peer:
            run.step("link-iphone-peer", lambda: _timed(lambda: peer.lines(lambda line: _link(line, ios.node_id)), 180))
        # The back-fill comes first, as in `soak`: a newcomer takes the other side's whole custody, one record per write.
        run.step("custody-converges-first", lambda: _converges(ios, phone, 900))
        if peer:
            run.step("custody-peer-converges-first", lambda: _peers_converge(peer, ios, 420))
            # Android trims its room to 2,000 rows every 10 minutes, a stranger's posts first, so a lab phone full of
            # earlier runs kept only the peer's last few minutes. A DM from the phone makes the peer someone it
            # talks to, whose posts it keeps; it crosses the iPhone too.
            hello = f"soak mvp11 hello {nonce}"
            phone.send(hello, conversation=peer_id)
            run.step("dm-phone-to-peer", lambda: _latency(peer.wait(lambda line: _message(line, hello), 60)))
        interval = 60 / arguments.per_minute
        started = time.monotonic()
        end = started + arguments.minutes * 60
        next_sample = started
        while time.monotonic() < end:
            beat = time.monotonic()
            traffic.post()
            if arguments.extras and traffic.turn % IPhoneSoakTraffic.EXTRA_EVERY == 0:
                traffic.extra()
            if beat >= next_sample:
                samples.append(_ios_sample(ios, peer, round(beat - started)))
                print(json.dumps({"sample": samples[-1]}), flush=True)
                next_sample += 120
            time.sleep(max(0.0, interval - (time.monotonic() - beat)))
        time.sleep(20)
        samples.append(_ios_sample(ios, peer, round(time.monotonic() - started)))
        run.step("iphone-bridge-held", lambda: _bridge_held(ios))
        run.step("iphone-no-crash", lambda: _knit_crashes(ios.udid, out / "crashes", started_wall))
        run.step("no-link-dropped-by-iphone", lambda: _ios_endings(out / "iphone.log", partners, ios))
        if peer:
            run.step("peer-alive", lambda: _alive(peer))
            run.step("no-link-dropped-by-peer", lambda: _endings(out / "peer.log"))
        for step, check in traffic.checks():
            run.step(step, check)
        if arguments.extras:
            run.step("extras", traffic.extras_report)
        iphone_samples = [sample["iphone"] for sample in samples if sample.get("iphone")]
        run.step("iphone-footprint-bounded", lambda: _footprint(iphone_samples))
        run.step("iphone-memory-flat", lambda: _headroom(samples))
        if peer:
            peer_samples = [sample["peer"] for sample in samples if sample.get("peer")]
            run.step("peer-footprint-bounded", lambda: _footprint(peer_samples))
            run.step("peer-memory-flat", lambda: _memory(peer_samples))
        run.step("custody-converges-at-end", lambda: _converges(ios, phone, 300))
        if peer:
            run.step("custody-peer-converges-at-end", lambda: _peers_converge(peer, ios, 300))
    finally:
        stop.set()
        if peer:
            peer.stop()
        for node in sorted(kept_off):
            try:
                ios.command(cmd="allow-link", peer=node)
            except (TimeoutError, OSError):
                pass
        syslog.stop()
        ios.stop()
    turns = traffic.turn if traffic else 0
    failures = traffic.failures if traffic else {}
    summary = {"summary": "iphone-soak", "turns": turns, "steps": run.steps, "failed": run.failed, "failures": failures, "keptOff": len(kept_off)}
    (out / "samples.jsonl").write_text("".join(json.dumps(sample) + "\n" for sample in samples), encoding="utf-8")
    (out / "summary.json").write_text(json.dumps({**summary, "run": header, "results": run.results}, indent=1), encoding="utf-8")
    print(json.dumps(summary))
    return run.failed


class IPhoneLog:
    """Knit's unified log over USB through `idevicesyslog`, kept as it comes. A debug build writes every level as one
    JSON line (`UnifiedLog`), so the file reads like the peer's log once each line's syslog prefix is cut."""

    def __init__(self, udid: str, path: Path) -> None:
        self.path = path
        self.file = open(path, "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(
            ["idevicesyslog", "-u", udid, "-p", "Knit", "--no-colors"], stdout=self.file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL
        )

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.file.close()

    @staticmethod
    def entries(path: Path) -> list[dict]:
        """Each of Knit's JSON lines in the file, with its syslog prefix cut."""
        entries = []
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            start = line.find('{"')
            if start < 0:
                continue
            try:
                entry = json.loads(line[start:])
            except json.JSONDecodeError:
                continue
            if isinstance(entry, dict) and "message" in entry:
                entries.append(entry)
        return entries


class IPhoneSoakTraffic:
    """What `iphone-soak` sends, and what it made of the answers. The authors take turns: the iPhone, the phone, and the
    peer when there is one. Bodies start with "soak " so knit-next's `.private/scripts/soak/cleanup.sh` purges them
    from the phones afterwards."""

    # One extra every so many posts, round-robin through the extras that apply.
    EXTRA_EVERY = 15
    # How many of each author's latest posts the phone is checked for: its bridge lists the room's newest 200.
    ON_PHONE = 50

    def __init__(self, ios: IPhone, phone: Phone, peer: Peer | None, phone_id: str, image: str | None) -> None:
        self.ios = ios
        self.phone = phone
        self.peer = peer
        self.phone_id = phone_id
        self.image = image
        self.authors = ["iphone", "phone"] + (["peer"] if peer else [])
        self.extras_order = ["react", "typing", "dm-from-phone", "dm-from-iphone", "photo"]
        if peer:
            self.extras_order += ["dm-from-peer", "dm-to-peer"]
        self.turn = 0
        self.extra_turn = 0
        self.posts: dict[str, dict[str, str]] = {author: {} for author in self.authors}  # author -> body -> id, "" if none
        self.posted_at: dict[str, float] = {}  # id -> monotonic
        self.extras: dict[str, int] = dict.fromkeys(self.extras_order, 0)
        self.photo_bodies: set[str] = set()
        self.phone_dms: set[str] = set()
        self.sent_dms: dict[str, dict[str, str]] = {"iphone": {}, "peer": {}, "to-peer": {}}  # id -> body
        self.failures: dict[str, int] = {}

    def _try(self, what: str, action) -> object:
        try:
            return action()
        except (RuntimeError, TimeoutError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            self.failures[what] = self.failures.get(what, 0) + 1
            print(json.dumps({"failed": what, "error": str(error)[:200]}), flush=True)
            return None

    def post(self) -> None:
        author = self.authors[self.turn % len(self.authors)]
        body = f"soak mvp11 #{self.turn} {author} {time.strftime('%H%M%S')}"
        self.turn += 1
        if author == "phone":
            if self._try("phone-post", lambda: self.phone.send(body)) is not None:
                self.posts["phone"][body] = ""
            return
        node = self.ios if author == "iphone" else self.peer
        assert node
        reply = self._try(f"{author}-post", lambda: node.command(cmd="room", text=body))
        if reply and reply.get("id"):
            self.posts[author][body] = reply["id"]
            self.posted_at[reply["id"]] = time.monotonic()

    def extra(self) -> None:
        kind = self.extras_order[self.extra_turn % len(self.extras_order)]
        self.extra_turn += 1
        n = self.extras[kind]
        body = f"soak mvp11 {kind} #{n} {time.strftime('%H%M%S')}"
        done: object = None
        if kind == "react" and self.posts["iphone"]:
            latest = list(self.posts["iphone"].values())[-1]
            done = self._try(kind, lambda: self.phone.bridge("REACT", id=latest, emoji="\U0001f44d"))
        elif kind == "typing":
            done = self._try(kind, lambda: self.phone.bridge("TYPING", conv=self.ios.node_id))
        elif kind == "dm-from-phone":
            done = self._try(kind, lambda: self.phone.send(body, conversation=self.ios.node_id))
            if done is not None:
                self.phone_dms.add(body)
                if n == 0:
                    # A first DM may be a message request; accepting it again is harmless.
                    self._try("accept", lambda: self.ios.wait(lambda line: _message(line, body), 60))
                    self._try("accept", lambda: self.ios.command(cmd="accept", conv=self.phone_id))
        elif kind == "dm-from-iphone":
            done = self._try(kind, lambda: self.ios.command(cmd="dm", to=self.phone_id, text=body))
            if isinstance(done, dict) and done.get("id"):
                self.sent_dms["iphone"][done["id"]] = body
        elif kind == "photo" and self.image:
            done = self._try(kind, lambda: self.phone.bridge("SENDIMG", path=self.image, text=body, conv="nearby"))
            if done is not None:
                self.photo_bodies.add(body)
        elif kind == "dm-from-peer" and self.peer:
            peer = self.peer
            done = self._try(kind, lambda: peer.command(cmd="dm", to=self.ios.node_id, text=body))
            if isinstance(done, dict) and done.get("id"):
                self.sent_dms["peer"][done["id"]] = body
                if n == 0:
                    self._try("accept", lambda: self.ios.wait(lambda line: _message(line, body), 60))
                    self._try("accept", lambda: self.ios.command(cmd="accept", conv=peer.node_id))
        elif kind == "dm-to-peer" and self.peer:
            peer = self.peer
            done = self._try(kind, lambda: self.ios.command(cmd="dm", to=peer.node_id, text=body))
            if isinstance(done, dict) and done.get("id"):
                self.sent_dms["to-peer"][done["id"]] = body
                if n == 0:
                    self._try("accept", lambda: peer.wait(lambda line: _message(line, body), 60))
                    self._try("accept", lambda: peer.command(cmd="accept", conv=self.ios.node_id))
        if done is not None:
            self.extras[kind] += 1

    def checks(self) -> list[tuple[str, object]]:
        """Each author's posts at every other node, and their ticks. The phone is read once, for its newest posts."""
        shown = {message["body"]: message for message in self.phone.state("nearby", limit=200).get("messages", [])}
        checks: list[tuple[str, object]] = [
            ("phone-posts-on-iphone", lambda: _all(set(self.posts["phone"]), _heard(self.ios))),
            ("iphone-posts-on-phone", lambda: _all(self._latest("iphone"), set(shown))),
            ("iphone-posts-ticked", lambda: self._ticks(self.ios, "iphone")),
            ("phone-posts-ticked", lambda: _all(self._latest("phone"), {body for body, m in shown.items() if m.get("received")})),
            ("phone-latency", lambda: _post_latency(self.ios, set(self.posts["phone"]))),
        ]
        if self.peer:
            peer = self.peer
            checks += [
                ("peer-posts-on-iphone", lambda: _all(set(self.posts["peer"]), _heard(self.ios))),
                ("iphone-posts-on-peer", lambda: _all(set(self.posts["iphone"]), _heard(peer))),
                ("phone-posts-on-peer", lambda: _all(set(self.posts["phone"]), _heard(peer))),
                ("peer-posts-on-phone", lambda: _all(self._latest("peer"), set(shown))),
                ("peer-posts-ticked", lambda: self._ticks(peer, "peer")),
                ("phone-latency-to-peer", lambda: _post_latency(peer, set(self.posts["phone"]))),
            ]
        return checks

    def _latest(self, author: str) -> set[str]:
        return set(list(self.posts[author])[-self.ON_PHONE :])

    def _ticks(self, node: Node, author: str) -> dict:
        delivered = _delivered_at(node)
        ids = self.posts[author]
        waits = sorted(delivered[i] - self.posted_at[i] for i in ids.values() if i in delivered)
        missing = [body for body, i in ids.items() if i not in delivered]
        detail = {"ticked": len(waits), "of": len(ids), "medianS": _at(waits, 0.5), "p90S": _at(waits, 0.9), "maxS": _at(waits, 1)}
        if missing:
            raise RuntimeError(f"{len(missing)} unticked, first {missing[:3]}: {detail}")
        return detail

    def extras_report(self) -> dict:
        heard = _heard(self.ios)
        ios_delivered = _delivered_at(self.ios)
        status = self.ios.command(cmd="status")
        detail: dict[str, object] = {
            "sent": self.extras,
            "photosHeard": len(self.photo_bodies & heard),
            "phoneDmsHeard": len(self.phone_dms & heard),
            "iphoneDmsDelivered": len([i for i in self.sent_dms["iphone"] if i in ios_delivered]),
            "fileRecords": status.get("fileRecords"),
            "dropped": status.get("dropped"),
        }
        problems = []
        if self.photo_bodies - heard:
            problems.append(f"{len(self.photo_bodies - heard)} photo captions never arrived")
        if self.phone_dms - heard:
            problems.append(f"{len(self.phone_dms - heard)} of the phone's DMs never arrived")
        if detail["iphoneDmsDelivered"] != len(self.sent_dms["iphone"]):
            problems.append(f"{len(self.sent_dms['iphone']) - detail['iphoneDmsDelivered']} of the iPhone's DMs never ticked")
        if self.peer:
            peer_delivered = _delivered_at(self.peer)
            detail["peerDmsDelivered"] = len([i for i in self.sent_dms["peer"] if i in peer_delivered])
            detail["dmsToPeerDelivered"] = len([i for i in self.sent_dms["to-peer"] if i in ios_delivered])
            if detail["peerDmsDelivered"] != len(self.sent_dms["peer"]):
                problems.append(f"{len(self.sent_dms['peer']) - detail['peerDmsDelivered']} of the peer's DMs never ticked")
            if detail["dmsToPeerDelivered"] != len(self.sent_dms["to-peer"]):
                problems.append(f"{len(self.sent_dms['to-peer']) - detail['dmsToPeerDelivered']} of the iPhone's DMs to the peer never ticked")
        if problems:
            raise RuntimeError(f"{'; '.join(problems)}: {detail}")
        return detail


def _heard(node: Node) -> set[str]:
    return {line.get("body") for line in node.lines(lambda line: line.get("event") == "message")}


def _delivered_at(node: Node) -> dict[str, float]:
    return {line["id"]: line["_at"] for line in node.lines(lambda line: line.get("event") == "delivered")}


def _post_latency(node: Node, bodies: set[str]) -> dict:
    """Posts from `bodies`, from their author's clock to the node's: MVP item 4 wants 5 s over a live link."""
    waits = sorted(
        (line["arrivedAt"] - line["sentAt"]) / 1000
        for line in node.lines(lambda line: line.get("event") == "message" and line.get("body") in bodies)
        if line.get("arrivedAt") and line.get("sentAt")
    )
    detail = {"posts": len(waits), "medianS": _at(waits, 0.5), "p90S": _at(waits, 0.9), "maxS": _at(waits, 1)}
    detail["withinFiveSeconds"] = len([wait for wait in waits if wait <= 5])
    return detail


def _ios_sample(ios: IPhone, peer: Peer | None, elapsed: int) -> dict:
    """The iPhone's tables and memory headroom, and the peer's `_sample`. An iPhone that does not answer is recorded as
    None: iOS suspends a Knit that leaves the screen, and a locked iPhone stops the soak's traffic with it."""
    sample: dict = {"t": elapsed}
    try:
        status = ios.command(cmd="status", timeout=20)
        keys = ("links", "custody", "dropped", "fileRecords", "footprint", "router", "memoryAvailableKb")
        sample["iphone"] = {"t": elapsed, **{key: status.get(key) for key in keys}}
    except (TimeoutError, OSError) as error:
        sample["iphone"] = None
        print(json.dumps({"warning": f"the iPhone did not answer its status ({error}): is it locked?"}), flush=True)
    if peer:
        sample["peer"] = _sample(peer, elapsed)
    return sample


def _bridge_held(ios: IPhone) -> dict:
    """The bridge stayed open for the whole run and still answers. It closes when Knit ends, and when iOS suspends it."""
    if ios.lost is not None:
        raise RuntimeError("the bridge closed during the run: Knit crashed, or left the screen")
    status = ios.command(cmd="status")
    return {"links": status.get("links"), "custody": status.get("custody")}


# A crash is `Knit-<date>.ips`; `Knit.cpu_resource-<date>.ips` and the like are iOS saying Knit used too much of something.
KNIT_REPORT = re.compile(r"^(Knit|JetsamEvent)(\.[a-z_]+)?-(\d{4}-\d{2}-\d{2}-\d{6})")


def _knit_crashes(udid: str, folder: Path, since: float) -> dict:
    """No crash report from Knit, and no jetsam report of iOS ending it, dated after `since`; a resource report, such
    as too many wakeups, is listed and passes. `idevicecrashreport -k` copies every report the phone holds and leaves
    them there. A report's name carries the phone's local time, which is this machine's: both keep the maintainer's
    time zone."""
    folder.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(["idevicecrashreport", "-u", udid, "-k", str(folder)], capture_output=True, text=True, timeout=600, check=False)
    if result.returncode:
        raise RuntimeError(f"idevicecrashreport failed: {(result.stderr or result.stdout).strip()[:200]}")
    after = time.strftime("%Y-%m-%d-%H%M%S", time.localtime(since - 60))
    crashes: list[str] = []
    ended: list[str] = []
    resources: list[str] = []
    for path in sorted(folder.rglob("*.ips")):
        match = KNIT_REPORT.match(path.name)
        if not match or match[3] < after:
            continue
        if match[1] == "Knit":
            (resources if match[2] else crashes).append(path.name)
        elif _jetsam_ended_knit(path):
            ended.append(path.name)
    if crashes or ended:
        raise RuntimeError(f"crash reports {crashes}, jetsam reports naming Knit {ended}, in {folder}")
    return {"reports": len(list(folder.rglob("*.ips"))), "resourceReports": resources}


def _jetsam_ended_knit(path: Path) -> bool:
    """Whether a jetsam report gives a reason for Knit, which it does only for a process it ended. The report is a
    JSON header line, then JSON; one that does not parse counts when it names Knit at all, so a human reads it."""
    text = path.read_text(encoding="utf-8", errors="replace")
    _, _, body = text.partition("\n")
    try:
        processes = json.loads(body).get("processes", [])
    except (json.JSONDecodeError, AttributeError):
        return '"Knit"' in text
    return any(process.get("name") == "Knit" and process.get("reason") for process in processes if isinstance(process, dict))


IOS_CHANNEL_ENDINGS = [
    (re.compile(r"^ble (ch\d+) ended$"), lambda _: "the far end closed it"),
    (re.compile(r"^ble (ch\d+) failed: (.*)"), lambda m: f"stream failed: {m[2][:80]}"),
    (re.compile(r"^ble (ch\d+) lost its connection: (.*)"), lambda m: f"connection lost: {m[2][:80]}"),
    (re.compile(r"^link (ch\d+) sent a bad record: (.*)"), lambda m: f"ours: bad record ({m[2][:60]})"),
    (re.compile(r"^link (ch\d+) timed out"), lambda _: "ours: HELLO timed out"),
    (re.compile(r"^link \S+ replaced its stale link (ch\d+) with ch\d+$"), lambda _: "replaced: the far end dialed again"),
]


def _ios_endings(log: Path, partners: set[str], ios: IPhone) -> dict:
    """Why each of the iPhone's links to `partners` ended, from its log: the first thing said of the channel before
    `link down`, as `soak.py`'s `link_endings` reads the peer's. Our side caused it when the link manager closed the
    channel (a bad record, a missed HELLO, an eviction), or closed it with no reason given, since the run neither
    stops the iPhone's mesh nor refuses a partner. A lost connection or a stream the far end ended is the radio's or
    the far end's. The bridge's own link events count the drops, so a log that missed some is caught."""
    entries = IPhoneLog.entries(log)
    if not entries:
        raise RuntimeError(f"the iPhone's log is empty: idevicesyslog recorded nothing to {log}")
    down = re.compile(r"^link down (\S+) on (ch\d+)$")
    evicting = re.compile(r"^link evicting (\S+)$")
    first: dict[str, str] = {}
    evicted: set[str] = set()
    endings: list[dict] = []
    for entry in entries:
        message = entry["message"]
        if match := evicting.match(message):
            evicted.add(match[1])
            continue
        if match := down.match(message):
            node, channel = match[1], match[2]
            reason = "ours: evicted" if node in evicted else first.pop(channel, "ours: closed here, no reason logged")
            evicted.discard(node)
            if node in partners:
                endings.append({"ms": entry.get("ms"), "peer": node[:6], "channel": channel, "reason": reason})
            continue
        for pattern, describe in IOS_CHANNEL_ENDINGS:
            if match := pattern.match(message):
                first.setdefault(match[1], describe(match))
                break
    reasons = Counter(ending["reason"] for ending in endings)
    downs = len(ios.lines(lambda line: line.get("event") == "link" and not line.get("up") and line.get("peer") in partners))
    detail = {"endings": len(endings), "bridgeDowns": downs, "reasons": dict(reasons), "logLines": len(entries)}
    ours = [ending for ending in endings if ending["reason"].startswith("ours")]
    if ours:
        raise RuntimeError(f"{len(ours)} of {len(endings)} links ended by the iPhone: {detail}, first {ours[:3]}")
    if downs > len(endings):
        raise RuntimeError(f"the bridge saw {downs} links drop and the log explains {len(endings)}: {detail}")
    return detail


def _headroom(samples: list[dict]) -> dict:
    """Flat means Knit's memory headroom (`memoryAvailableKb`, what iOS lets it take before ending it) fell less than
    8 MB through the second half: the first minutes fill caches and tables."""
    points = [(sample["t"], sample["iphone"]["memoryAvailableKb"]) for sample in samples if (sample.get("iphone") or {}).get("memoryAvailableKb")]
    if not points:
        raise RuntimeError("no memory sampled: the iPhone's build predates memoryAvailableKb")
    half = [kb for t, kb in points if t >= points[-1][0] / 2]
    fell = half[0] - half[-1]
    detail = {"firstKb": points[0][1], "halfKb": half[0], "lastKb": half[-1], "leastKb": min(kb for _, kb in points)}
    if fell > 8 * 1024:
        raise RuntimeError(f"headroom fell {fell} kB in the second half: {detail}")
    return detail


def _keygen(instance: str, *bounds: str) -> str:
    result = subprocess.run([str(PEER), "keygen", *bounds, "--instance", instance], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)["nodeId"]


def _keep_to(node: Node, allowed: set[str], refused: set[str], stop: threading.Event, by: str) -> None:
    """Refuses every node that `node` sights or links outside `allowed`, well inside the 12 s promotion dwell, so a
    phone the first scan missed never joins the line. `refused` starts with what is already refused, and gains each
    node refused here."""
    while not stop.wait(3):
        try:
            reply = node.command(cmd="links")
        except (TimeoutError, BrokenPipeError, ValueError, AssertionError, OSError):
            continue
        near = {sighting["peer"] for sighting in reply.get("sightings", [])} | {link["peer"] for link in reply.get("links", [])}
        for other in near - allowed - refused:
            node.command(cmd="deny-link", peer=other)
            refused.add(other)
            print(json.dumps({"refused-late": other, "by": by}))
            sys.stdout.flush()


def _link(line: dict, node: str) -> bool:
    return line.get("event") == "link" and line.get("peer") == node and bool(line.get("up"))


def _peers_converge(first: Node, second: Node, timeout: float) -> dict:
    def same() -> dict | None:
        ours = {frame["id"]: frame for frame in first.command(cmd="custody")["frames"]}
        theirs = {frame["id"]: frame for frame in second.command(cmd="custody")["frames"]}
        LAST_CUSTODY_DIFFERENCE.clear()
        LAST_CUSTODY_DIFFERENCE.update(
            onlyFirst=[_brief(ours[i]) for i in sorted(ours.keys() - theirs.keys())[:5]],
            onlySecond=[_brief(theirs[i]) for i in sorted(theirs.keys() - ours.keys())[:5]],
        )
        return {"ids": len(ours)} if ours.keys() == theirs.keys() else None

    try:
        return poll(same, timeout, every=10)
    except TimeoutError as error:
        raise TimeoutError(f"custody still differs: {LAST_CUSTODY_DIFFERENCE}") from error


def _relayed(peer: Node, before: dict | None = None) -> dict:
    """What the node's router passed on, since `before` when given: a `status` reply's `router` counters."""
    router = peer.command(cmd="status")["router"]
    if before:
        router = {key: value - before.get(key, 0) for key, value in router.items()}
    if not router.get("relayed"):
        raise RuntimeError(f"relayed nothing: {router}")
    return {"router": router}


def _never_linked(peer: Peer, node: str) -> dict:
    if peer.lines(lambda line: _link(line, node)):
        raise RuntimeError(f"linked to {node}")
    return {}


def _linked_only(node: Node, allowed: set[str]) -> dict:
    others = {line["peer"] for line in node.lines(lambda line: line.get("event") == "link" and line.get("up"))} - allowed
    if others:
        raise RuntimeError(f"linked to {sorted(others)}")
    return {}


def _latency(message: dict) -> dict:
    """How long the message took, from the sender's clock to ours; the two clocks are only as close as NTP keeps them.
    MVP item 4 wants a room post across a live link within 5 s."""
    latency = message["arrivedAt"] - message["sentAt"]
    return {"latencyMs": latency, "withinFiveSeconds": latency <= 5000}


def _request(message: dict) -> dict:
    if not message.get("request"):
        raise RuntimeError("a stranger's first DM should arrive as a message request")
    return {**_latency(message), "request": True}


def _has(state: dict, body: str) -> bool:
    return any(message.get("body") == body for message in state.get("messages", []))


def _received(state: dict, body: str) -> bool:
    return any(message.get("body") == body and message.get("received") for message in state.get("messages", []))


def _aliases(peer: Peer, phone_id: str) -> dict:
    own = peer.command(cmd="status")
    phone = next((p for p in peer.command(cmd="peers")["peers"] if p["peer"] == phone_id), None)
    if phone is None:
        raise RuntimeError("the peer has not pinned the phone")
    return {"peerDisplayName": own["displayName"], "peerAlias": own["alias"], "phoneAlias": phone["alias"]}


def _file_records(peer: Peer) -> dict | None:
    status = peer.command(cmd="status")
    count = status.get("fileRecords", 0)
    return {"fileRecords": count, "links": status["links"]} if count and status["links"] else None


LAST_CUSTODY_DIFFERENCE: dict = {}


def _converged(peer: Node, phone: Phone) -> dict | None:
    """Whether the peer's live custody ids are the phone's. The phone serves a group frame only to the group's members
    (`ForwardSync.onDigest`), and the peer is in no group, so the phone's group frames are left out."""
    ours = set(peer.command(cmd="digest")["ids"])
    store = phone.bridge("STORE", limit=5000)
    expired = set(store.get("expiredIds", []))
    groups = {row["id"] for row in store.get("rows", []) if row.get("group")}
    theirs = set(store.get("allIds", [])) - expired - groups
    if ours == theirs:
        return {"ids": len(ours), "groupFramesLeftOut": len(groups)}
    # Kept for the report when the poll gives up: what each side holds that the other does not.
    rows = {row["id"]: row for row in store.get("rows", [])}
    frames = {frame["id"]: frame for frame in peer.command(cmd="custody")["frames"]}
    LAST_CUSTODY_DIFFERENCE.clear()
    LAST_CUSTODY_DIFFERENCE.update(
        onlyPeer=[_brief(frames.get(i, {"id": i})) for i in sorted(ours - theirs)[:5]],
        onlyPhone=[_brief(rows.get(i, {"id": i})) for i in sorted(theirs - ours)[:5]],
        counts={"onlyPeer": len(ours - theirs), "onlyPhone": len(theirs - ours)},
    )
    return None


def _brief(frame: dict) -> dict:
    """A frame's addressing, from the peer's `custody` or the phone's STORE row, with node ids cut to six."""
    keep = ("id", "type", "from", "sender", "to", "recipient", "group", "sentAt", "ageSec", "ttlLeftSec", "origin")
    return {key: value[:6] if key in ("from", "sender", "to", "recipient") and value else value for key, value in frame.items() if key in keep}


def _converges(peer: Node, phone: Phone, timeout: float) -> dict:
    try:
        return poll(lambda: _converged(peer, phone), timeout, every=10)
    except TimeoutError as error:
        raise TimeoutError(f"custody still differs: {LAST_CUSTODY_DIFFERENCE}") from error


def _no_link_dropped(peer: Node, among: set[str] | None = None) -> dict:
    """No link went down, or none to a node in `among` when given: a node that refuses the rest drops their links."""
    downs = peer.lines(lambda line: line.get("event") == "link" and not line.get("up") and (among is None or line.get("peer") in among))
    if downs:
        raise RuntimeError(f"{len(downs)} link downs")
    return {}


def _alive(peer: Peer) -> dict:
    if not peer.process or peer.process.poll() is not None:
        raise RuntimeError("knit-peer exited")
    return {}


def _all(expected: set[str], seen: set[str]) -> dict:
    missing = expected - seen
    if missing:
        raise RuntimeError(f"{len(missing)} of {len(expected)} missing")
    return {"count": len(expected)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "refusal", "replace", "soak", "relay", "iphone-relay"):
        sub = commands.add_parser(name)
        sub.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
        sub.add_argument("--radio-profile", default="android", choices=["android", "ios"])
        sub.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
        # Knit advertises at medium power (the Pixel 3's controller picks -11 dBm), so the peer hears a phone near
        # Android's -90 dBm floor and may never dial it. A looser floor is a development aid, not law: nothing in
        # checklist L may pass only because of it.
        sub.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    commands.choices["check"].add_argument("--order", default="phone-dials", choices=["phone-dials", "peer-dials"])
    commands.choices["check"].add_argument("--blank-name", action="store_true", help="run the peer with no name, so each side shows the alias")
    commands.choices["check"].add_argument("--expect-avatar", action="store_true", help="the phone has a photo: check its FILE records")
    commands.choices["refusal"].add_argument("--seconds", type=float, default=120, help="how long to watch the dials fail")
    commands.choices["soak"].add_argument("--minutes", type=float, default=60)
    commands.choices["soak"].add_argument("--per-minute", type=float, default=20, help="posts a minute, both sides together")
    commands.choices["soak"].add_argument("--extras", action="store_true", help="the phone also reacts, types, DMs and posts photos")
    for name in ("check", "soak"):
        commands.choices[name].add_argument("--mac", action="store_true", help="run the peer on the Mac, on CoreBluetooth: checklist M")
    for sub in commands.choices.values():
        sub.add_argument("--receive-mtu", default="", help="the receive MTU each peer channel offers, for diagnosis")
        sub.add_argument("--send-mtu", default="", help="the largest SDU each peer channel writes, for diagnosis")
    ios = commands.add_parser("iphone")
    ios.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    ios.add_argument("--skip-offline", action="store_true", help="leave out MVP item 6, which stops the iPhone's mesh")
    wake = commands.add_parser("iphone-wake")
    wake.add_argument("--sender", default="phone", choices=["phone", "peer"], help="who DMs the locked iPhone: the phone, or knit-peer on hci0")
    wake.add_argument("--device", help="the adb serial of a phone the maintainer approved for this session; needed with --sender phone")
    wake.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    wake.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    wake.add_argument("--minutes", type=int, default=10, help="how long the iPhone stays locked, with a DM each minute")
    wake.add_argument("--lock-wait", type=float, default=900, help="how long to wait for someone to lock the iPhone")
    wake.add_argument("--unlock-wait", type=float, default=1800, help="how long to wait for someone to open Knit again")
    wake.add_argument(
        "--expect-wakes", action="store_true", help="the phone runs A4 (knit-next feat/ble-doorbell): every DM must wake Knit, as with --sender peer"
    )
    ios_peer = commands.add_parser("iphone-peer")
    ios_peer.add_argument(
        "--order", default="iphone-below", choices=["iphone-below", "iphone-above"], help="where the iPhone's id sorts against the peer's"
    )
    ios_peer.add_argument("--skip-offline", action="store_true", help="leave out MVP item 6, which stops the iPhone's mesh")
    ios_peer.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    ios_peer.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    ios_soak = commands.add_parser("iphone-soak")
    ios_soak.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    ios_soak.add_argument("--peer", action="store_true", help="knit-peer on hci0 joins as a third author, linked to the iPhone alone")
    ios_soak.add_argument("--minutes", type=float, default=60)
    ios_soak.add_argument("--per-minute", type=float, default=20, help="posts a minute, every author together: each link's rate")
    ios_soak.add_argument("--extras", action="store_true", help="the phone also reacts, types, DMs and posts photos; a peer DMs")
    ios_soak.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    ios_soak.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    reboot = commands.add_parser("iphone-reboot")
    reboot.add_argument("--restart", action="store_true", help="restart the iPhone with idevicediagnostics rather than by hand")
    reboot.add_argument("--locked", type=float, default=120, help="how long the iPhone stays locked from when it leaves USB, in seconds")
    reboot.add_argument("--closed", type=float, default=60, help="how long Knit stays closed after the unlock, in seconds")
    reboot.add_argument("--skip-relaunch", action="store_true", help="leave out closing Knit and opening it again")
    reboot.add_argument("--unlock-wait", type=float, default=1800, help="how long to wait for each thing someone does")
    by_hand = commands.add_parser("bridge")
    by_hand.add_argument("--watch", type=float, default=0, help="print the bridge's events for this many seconds")
    by_hand.add_argument("commands", nargs="*", help='commands as JSON, such as \'{"cmd":"status"}\'')
    rings = commands.add_parser("iphone-rings")
    rings.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    rings.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    scan = commands.add_parser("iphone-scan")
    scan.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    scan.add_argument("--window", type=float, default=30, help="how long the filtered scan runs with Knit open, in seconds")
    scan.add_argument("--away-window", type=float, default=60, help="how long each peer advertises alone with the iPhone locked")
    scan.add_argument("--first", default="android", choices=["android", "ios"], help="which peer starts first once the iPhone is locked")
    scan.add_argument("--lock-wait", type=float, default=900, help="how long to wait for someone to lock the iPhone")
    scan.add_argument("--unlock-wait", type=float, default=1800, help="how long to wait for someone to open Knit again")
    reads = commands.add_parser("android-reads")
    reads.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    reads.add_argument("--order", default="peer-below", choices=["peer-below", "peer-above"], help="where the peer's id sorts against the phone's")
    reads.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    reads.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    reads.add_argument("--link-timeout", type=float, default=180, help="seconds for the phone's read and for the link")
    reads.add_argument("--hold", type=float, default=60, help="seconds the link must hold after it comes up")
    reads.add_argument("--quiet-timeout", type=float, default=600, help="seconds for the phone to let go of an earlier peer's payload")
    forgets = commands.add_parser("android-forgets")
    forgets.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    forgets.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    forgets.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    forgets.add_argument("--link-timeout", type=float, default=180, help="seconds for each read, link and HELLO forget")
    forgets.add_argument("--quiet-timeout", type=float, default=600, help="seconds for the quiet forget, which counts scan time only")
    forgets.add_argument(
        "--stages", default="quiet,hello-accepted,dial,hello-dialed", help="which forget stages to run, comma-separated, in their fixed order"
    )
    ios_forgets = commands.add_parser("iphone-forgets")
    ios_forgets.add_argument("--stages", default="dialed,quiet,accepted", help="which stages to run, comma-separated, in their fixed order")
    ios_forgets.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    ios_forgets.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    ios_forgets.add_argument("--link-timeout", type=float, default=180, help="seconds for each read, link and HELLO forget")
    ios_forgets.add_argument("--quiet-timeout", type=float, default=300, help="seconds for the quiet forget")
    ios_forgets.add_argument("--hci0", action="store_true", help="run the peer on hci0, shared, which needs its own go-ahead")
    android = commands.add_parser("android-rings")
    android.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    android.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    android.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    android.add_argument("--converge-timeout", type=float, default=600, help="seconds for the back-fill to converge custody")
    android.add_argument("--arrival-timeout", type=float, default=600, help="seconds for the post and the DM to reach the peer")
    android.add_argument(
        "--link",
        default="dialed",
        choices=["dialed", "accepted"],
        help="a link the phone dialed after reading the peer's payload (A3), or one it accepted from a peer it never sights",
    )
    for sub in (ios, wake, reboot, rings, scan, by_hand, ios_peer, ios_soak, ios_forgets, commands.choices["iphone-relay"]):
        sub.add_argument("--udid", help="the iPhone's UDID, when more than one is on USB")
    arguments = parser.parse_args()
    if arguments.command == "iphone-wake" and arguments.sender == "phone" and not arguments.device:
        parser.error("--sender phone needs --device")
    if arguments.command in ("iphone", "iphone-wake", "iphone-reboot", "bridge"):
        return {"iphone": iphone, "iphone-wake": iphone_wake, "iphone-reboot": iphone_reboot, "bridge": bridge}[arguments.command](arguments)
    if not PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
    if arguments.command == "iphone-rings":
        return iphone_rings(arguments)
    if arguments.command == "iphone-peer":
        return iphone_peer(arguments)
    if arguments.command == "iphone-forgets":
        return iphone_forgets(arguments)
    if arguments.command == "iphone-soak":
        return iphone_soak(arguments)
    if arguments.command == "android-rings":
        return android_rings(arguments)
    if arguments.command == "android-reads":
        return android_reads(arguments)
    if arguments.command == "android-forgets":
        return android_forgets(arguments)
    if arguments.command == "iphone-scan":
        return iphone_scan(arguments)
    global RECEIVE_MTU, SEND_MTU  # noqa: PLW0603 - two knobs, read by Peer.start
    RECEIVE_MTU = arguments.receive_mtu
    SEND_MTU = arguments.send_mtu
    if not PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
    if getattr(arguments, "mac", False):
        global ON_MAC  # noqa: PLW0603 - one switch, read by Peer.start and keygen
        ON_MAC = True
        arguments.radio_profile = "ios"
        # Syncs this tree to the Mac and builds and signs the peer there, so the run tests what is here.
        subprocess.run([str(ROOT / "scripts" / "mac.sh"), "run", "scripts/mac-peer.sh", "build"], check=True, stdout=subprocess.DEVNULL)
    if arguments.command == "relay" and "--radio-profile" not in sys.argv:
        # Peer A stands in for the iPhone, which Android finds only by its GATT payload.
        arguments.radio_profile = "ios"
    scenarios = {"check": check, "refusal": refusal, "replace": replace, "soak": soak, "relay": relay, "iphone-relay": iphone_relay}
    return scenarios[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
