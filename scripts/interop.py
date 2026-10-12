#!/usr/bin/env python3
"""Checklist L against an Android phone running a debug build of Knit: knit-peer on hci1 on one side, the phone
driven through knit-next's debug bridge on the other (.agents/specs/mvp.md, .agents/context/linux-peer.md).

    scripts/interop.py check   --device SERIAL [--order phone-dials|peer-dials] [--radio-profile android|ios]
                                [--blank-name] [--expect-avatar] [--peer-avatar JPEG] [--mac]
    scripts/interop.py refusal --device SERIAL [--seconds 120]
    scripts/interop.py replace --device SERIAL
    scripts/interop.py soak    --device SERIAL [--minutes 60] [--per-minute 20] [--extras] [--mac]
    scripts/interop.py relay   --device SERIAL [--radio-profile ios|android] [--expect-avatar] [--peer-avatar JPEG]
    scripts/interop.py group   --device SERIAL [--radio-profile android|ios]
    scripts/interop.py iphone  --device SERIAL [--udid UDID] [--skip-offline] [--links N] [--hold 60]
    scripts/interop.py iphone-relay --device SERIAL [--udid UDID] [--expect-avatar] [--peer-avatar JPEG]
    scripts/interop.py iphone-group --device SERIAL [--udid UDID]
    scripts/interop.py iphone-peer [--order iphone-below|iphone-above] [--skip-offline] [--udid UDID]
    scripts/interop.py iphone-photos --device SERIAL [--animated] [--udid UDID]
    scripts/interop.py iphone-block --device SERIAL [--udid UDID]
    scripts/interop.py iphone-delete --device SERIAL [--udid UDID]
    scripts/interop.py iphone-react --device SERIAL [--udid UDID]
    scripts/interop.py iphone-forgets [--stages dialed,quiet,accepted] [--udid UDID]
    scripts/interop.py iphone-soak --device SERIAL [--peer] [--extras] [--udid UDID] [--minutes 60] [--per-minute 20]
    scripts/interop.py iphone-wake [--sender phone|peer] [--device SERIAL] [--expect-wakes] [--udid UDID] [--minutes 10]
    scripts/interop.py android-keeps-iphone --device SERIAL [--stages held,redial] [--quiet SERIAL ...]
                                [--mover devicectl|devicetest|prompts] [--minutes 10]
    scripts/interop.py iphone-reboot [--restart] [--locked 120] [--closed 60] [--skip-relaunch] [--udid UDID]
    scripts/interop.py iphone-rings [--udid UDID]
    scripts/interop.py android-reads --device SERIAL [--order peer-below|peer-above] [--link-timeout 180] [--links N] [--hci0]
    scripts/interop.py android-forgets --device SERIAL [--link-timeout 180] [--quiet-timeout 600]
    scripts/interop.py android-strangers --device SERIAL --variant none|forged [--minutes 30] [--rotate 20] [--cycle 180] [--known IDS]
                                [--quiet SERIAL ...]
    scripts/interop.py android-rings --device SERIAL [--link dialed|accepted] [--converge-timeout 600] [--arrival-timeout 600]
    scripts/interop.py iphone-scan [--udid UDID] [--window 30] [--away-window 60] [--first android|ios]
    scripts/interop.py iphone-seek --far hci1|hci0|phone [--device SERIAL] [--mode drop|relink|budget] [--drop kill|radio-off]
    scripts/interop.py bridge  [--udid UDID | --host ADDRESS] [--watch SECONDS] [COMMAND_JSON ...]
    scripts/interop.py record-pull --out FILE [--udid UDID | --host ADDRESS] [--chunk BYTES] [--keep]

`iphone` runs MVP items 2 to 6 between an iPhone and the Android phone, driving the iPhone through a debug build's
bridge (ADR 2026-09.kwa8), and the phone's Requests screen for a pair that has never talked; `iphone-peer`
runs the same items between the iPhone and the peer; `iphone-relay` runs MVP item 7's line through the iPhone, and
`iphone-group` v1 groups along that line, the peer as the third member (`group` runs them with two peers and no
iPhone, ADR 2026-09.n393); `iphone-photos` sends photos both ways between the iPhone and the phone, in Nearby, a DM
and a group (ADR 2026-10.6cas); `iphone-block` checks that a block on the iPhone leaves the phone's ✓✓ on its room post
and its custody converging (ADR 2026-10.5wgg); `iphone-delete` checks that what the iPhone deletes stays deleted across
a restart of its mesh, and that the delete sends nothing (ADR 2026-10.u7cq); `iphone-react` sends reactions both ways in
every thread, and checks a replacement, a retraction, an emoji outside the iPhone's six and a block (ADR 2026-10.ehe6);
`iphone-soak` is item 11's hour on the iPhone, with the peer as a third author when asked;
`iphone-wake` is item 9's wake test, with someone to lock the iPhone and unlock it again; `android-keeps-iphone` checks that
an Android phone keeps a backgrounded iPhone's link and admits its re-dial (knit-next AND-3), moving Knit away from the
front and back through device tests run on the Mac, with nobody at the iPhone; `iphone-reboot` is item 1's
relaunch and reboot, with someone to close Knit and unlock the iPhone; `iphone-scan` is P8's scan-filter check, with
someone to do the same; `iphone-seek` checks that a locked iPhone with no link finds a peer within its wake budget
(ADR 2026-10.mueg), with someone to do the same; `bridge` sends that bridge commands by hand and prints what comes back, and
`record-pull` copies the bridge's last finished screen recording to a file and checks its SHA-256. `iphone-rings` checks
the doorbell rings an iPhone sends, and `android-rings` those an Android phone sends, with companion change A4.
`android-reads` is companion change A3's device gate: an Android phone reads the peer's GATT payload and dials it, or
is dialed, by the id order. `android-strangers` is knit-next #154's: beside a device rotating its address under
`0xFE30`, the phone's GATT reads stay within their budget and its dials never wait behind them (knit-ios #3).

`--mac` runs the peer on the Mac instead of hci1, on CoreBluetooth, the iPhone's own radio: checklist M (ADR
2026-09.vcdk). It always runs the `ios` profile, in the Mac's desktop session through `scripts/mac-peer.sh`, and the
scan that finds the nodes to refuse still runs here.

Every iPhone command reaches the bridge over USB through iproxy, or over Wi-Fi with `--host ADDRESS` (or
KNIT_IPHONE_HOST; `--host ''` forces USB) once the phone's network is pinned over USB with
`bridge '{"cmd":"wifi-pin"}'` (ADR 2026-10.dz8d). Steps that use usbmuxd still need the cable: the iPhone's log, its
crash reports and a restart.

Driving a physical phone needs the maintainer's go-ahead for the session (.agents/rules/devices.md). Nothing here
installs or launches anything: it wakes the phone, asks its bridge to scan, send and report, and reads the answers.
`iphone` also brings Knit forward at the phone's Requests screen and taps Accept there, through uiautomator.
`relay` and `group` also run a second peer on hci0, and `iphone-relay`, `iphone-group`, `iphone-peer` and
`iphone-soak --peer` run their one peer there.

hci1 and hci0 here are roles, not the kernel's indices, and everything finds its adapter by address (ADR 2026-09.5ftc).
Since 2026-10-03 hci1 is dongle A ($KNIT_ADAPTER_A) and hci0 is dongle B ($KNIT_ADAPTER_B): two nRF52840s running
firmware/knit-hci, which take incoming LE connections and advertise while linked (.agents/context/linux-peer.md, "What
the nRF52840 dongles showed"). Until then hci1 was the ATS2851, which took no incoming LE connection, and hci0 the
maintainer's own adapter, shared, which needed a go-ahead. The addresses and the Mac's host come from the environment,
or from .private/lab.env when it is there, which stays out of the repository (ADR 2026-10.ab6k). Some waits below still work around
the ATS2851; they cost time on the dongles, nothing more.

Each step prints one JSON line, {"step": ..., "ok": ..., ...}, and the run ends with a summary line. The exit code
is the number of failed steps.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import random
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


def _load_lab_env(path: Path) -> None:
    """Puts `.private/lab.env`'s KEY=VALUE lines into the environment, under anything already set there, so that every
    knit-peer this starts inherits the lab's adapters (ADR 2026-10.ab6k)."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        key, equals, value = line.strip().partition("=")
        if equals and key and not key.startswith("#"):
            os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def lab(name: str) -> str:
    """A lab setting from the environment, such as an adapter's address; exits saying where to set it when there is
    none."""
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is not set: put it in .private/lab.env or the environment (ADR 2026-10.ab6k)")
    return value


def hci0() -> list[str]:
    """The flags that put a peer on dongle B, the second peer's adapter (.agents/context/linux-peer.md, "The adapter").
    It was the maintainer's own adapter, shared, until 2026-10-03."""
    return ["--adapter-address", lab("KNIT_ADAPTER_B")]


def hci1_address() -> str:
    """Dongle A's public address, which every peer on it advertises from, and knit-peer's default adapter. It was the
    ATS2851's until 2026-10-03."""
    return lab("KNIT_ADAPTER_A")


_load_lab_env(ROOT / ".private" / "lab.env")
# KNIT_PEER runs another build of the peer, such as one from a commit whose checks passed.
PEER = Path(os.environ.get("KNIT_PEER") or ROOT / ".build" / "out" / "Products" / "Debug-linux-x86_64" / "knit-peer")
PACKAGE = "app.getknit.knit"
INSTANCE = "interop"
# The Mac that runs the peer with --mac is $KNIT_MAC_HOST; this is its mirror of this tree (scripts/mac.sh).
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

    def bridge(self, action: str, **extras: str | int | bool) -> dict:
        parts = [f"am broadcast -a {PACKAGE}.debug.{action} -p {PACKAGE}"]
        for key, value in extras.items():
            if isinstance(value, bool):
                parts.append(f"--ez {key} {str(value).lower()}")
                continue
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

    # What `wake` does: "heal" keeps the screen on and nudges a scan, "screen" only keeps the screen on, and "none" does
    # nothing (`--wake`). A run that times the phone's own cadence can't nudge its scans, which would hide the wait: an
    # open phone's run keeps its screen on alone, and a screen-off phone's never wakes it.
    wakes = "heal"

    def wake(self) -> None:
        """Keeps the phone interactive so its scanner runs at its balanced cadence, and nudges a scan, as far as the
        run's `wakes` allows."""
        if self.wakes == "none":
            return
        self.shell("input keyevent KEYCODE_WAKEUP")
        if self.wakes == "heal":
            self.bridge("HEAL")

    def state(self, conversation: str | None = None, limit: int = 20) -> dict:
        return self.bridge("STATE", conv=conversation, limit=limit) if conversation else self.bridge("STATE")

    def send(self, text: str, conversation: str = "nearby") -> dict:
        return self.bridge("SEND", text=text, conv=conversation)

    def make_group(self, members: list[str]) -> str:
        """A group of `members` and the phone, made as Android's picker makes one: nothing is sent until its first
        message (`MKGROUP`, knit-next's debug-bridge.md). Returns its id, which the same people always derive."""
        reply = self.bridge("MKGROUP", members=",".join(members))
        if reply.get("status") != "ok":
            raise RuntimeError(f"MKGROUP refused: {reply}")
        return reply["groupId"]

    def leave_group(self, group: str) -> None:
        """Group details' Leave: the signed `groupleave` goes out, then the local tombstone (`LEAVE`)."""
        reply = self.bridge("LEAVE", conv=group)
        if reply.get("status") != "ok":
            raise RuntimeError(f"LEAVE refused: {reply}")

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
        gatt_reads: bool | None = None,
    ) -> None:
        super().__init__()
        # knit-peer's test switches: nodes it never takes as sighted, so it never dials them and admits their dials
        # unsighted; in the `ios` profile, a doorbell served without the payload, so an A3 phone never sights it; and
        # GATT reads, with FLAG_DIALS_GATT_PEERS, on (`--gatt-reads`, a release Android's advert in the `android`
        # profile), off (`--no-gatt-reads`), or the profile's own (None).
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
        if self.gatt_reads is not None:
            arguments.append("--gatt-reads" if self.gatt_reads else "--no-gatt-reads")
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
    """Knit on an iPhone: a debug build's bridge (ADR 2026-09.kwa8), reached over USB through `iproxy`, or over Wi-Fi
    at `host` on a network pinned over USB (ADR 2026-10.dz8d). It speaks knit-peer's protocol, so a run drives it as it
    drives the peer. Knit has to be open on the phone, since nothing here can launch it, and `stop` closes the
    connection and leaves Knit and its mesh running."""

    label = "the iPhone's bridge"
    DEVICE_PORT = 5648

    def __init__(self, udid: str | None = None, host: str | None = None) -> None:
        super().__init__()
        self._udid = udid
        self.host = host or None
        self.proxy: subprocess.Popen[bytes] | None = None
        self.socket: socket.socket | None = None
        self.name = ""
        # When the bridge closed without `stop` asking: Knit crashed, or iOS suspended it and shut its sockets.
        self.lost: float | None = None
        self.stopping = False

    @property
    def udid(self) -> str:
        """The iPhone's UDID, found on USB when a step first needs it, so a run over Wi-Fi needs the cable only for the
        steps that use usbmuxd."""
        if self._udid is None:
            try:
                self._udid = first_usb_iphone()
            except RuntimeError as error:
                if self.host:
                    raise RuntimeError("this step needs the iPhone on USB too: only the bridge goes over Wi-Fi") from error
                raise
        return self._udid

    def start(self) -> None:
        self.lost = None
        self.stopping = False
        if self.host:
            address = (self.host, self.DEVICE_PORT)
        else:
            port = free_port()
            self.proxy = subprocess.Popen(
                ["iproxy", f"{port}:{self.DEVICE_PORT}", "-u", self.udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            address = ("127.0.0.1", port)
        deadline = time.monotonic() + 10
        while self.socket is None:
            try:
                self.socket = socket.create_connection(address, timeout=5)
            except OSError as error:
                if time.monotonic() > deadline:
                    if self.host:
                        raise ConnectionError(
                            f"nothing answers at {self.host}:{self.DEVICE_PORT}: open Knit, a debug build, on a network "
                            """pinned over USB (bridge '{"cmd":"wifi-pin"}')"""
                        ) from error
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


def in_range(seconds: int = 20, adapter: list[str] | None = None) -> dict[str, dict]:
    """Every Knit node a quiet scan hears, by node id, with what it advertised: its flags, and the low byte of its
    capabilities, `ff` from Android and `f` from an iPhone or an `ios` peer (`b` before reactions, `9` before groups).
    `adapter` scans elsewhere than hci1."""
    command = [str(PEER), "scan", "--seconds", str(seconds), "--log", "debug", *(adapter or [])]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
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
# The low byte of the capabilities this port advertises, as the scan spells it: 0xF since reactions (ADR 2026-10.ehe6),
# 0xB from a build before them (ADR 2026-09.n393), and 0x9 from one before groups, which phones and peers may still run.
# Android's builds send 0xFF.
IOS_ADVERT_CAPABILITIES = "f"
IOS_ADVERT_CAPABILITIES_ALL = frozenset({IOS_ADVERT_CAPABILITIES, "b", "9"})
# knit-next #103 (its ADR 2026-09.hj4a): a phone that has held no BLE link for three minutes may dial a peer it sights
# above it, and logs `bt lonely dial <id> (alone=<ms>ms rssi=<dBm> dwell=<ms>ms)` just before that dial's `bt initiating
# to`. The peer admits it only if it never sighted the phone.
LONELY_DIAL = "bt lonely dial "


def androids(heard: dict[str, dict]) -> set[str]:
    """The nodes a scan heard that advertise as Android does. The scan does not say where a payload came from, so
    this goes by the capabilities' low byte, which only this port's nodes send as 0xF, 0xB before reactions, or 0x9
    before groups."""
    return {node for node, entry in heard.items() if entry.get("capabilities") not in IOS_ADVERT_CAPABILITIES_ALL}


def on_mac(verb: str, arguments: list[str]) -> list[str]:
    """The Mac's knit-peer `verb` over ssh (scripts/mac-peer.sh): `run` goes to its desktop session, where macOS lets
    it use Bluetooth, with stdin and stdout still attached here."""
    return ["ssh", lab("KNIT_MAC_HOST"), f"cd {MAC_MIRROR} && scripts/mac-peer.sh {verb} {shlex.join(arguments)}"]


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
        if arguments.peer_avatar:
            jpeg = base64.b64encode(_unique_jpeg(arguments.peer_avatar, nonce)).decode()
            run.step("photo-set", lambda: {"avatarHash": peer.command(cmd="avatar", jpeg=jpeg)["avatarHash"]})
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
        # A phone with a photo pushes it as FILE records right behind its profile, and the peer shows it once it is the
        # photo that profile names (ADR 2026-10.ym9y).
        if arguments.expect_avatar:
            run.step("photo-adopted", lambda: poll(lambda: _photo(peer, phone_id), 60))
        # Our photo goes to the phone right behind our profile. Android's bridge does not say which photo it shows, so
        # the peer's count of files out whole stands in, and the phone's screen is the rest of the check.
        if arguments.peer_avatar:
            run.step("photo-pushed", lambda: poll(lambda: _files_sent(peer), 60))
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
    which closes every link it has, not only the phone's.

    With the iPhone above the phone, the iPhone is each link's central, so each must end at knit-next #102's 5 s
    supervision timeout, not iOS's 720 ms put back after the doorbell lookup (`link-balanced`, `relink-balanced`). A
    link already up when the run began left its lines before the log was cleared, and passes unseen. `--links N`
    then brings the link down and up again until N links have found the doorbell, each dialed by the iPhone, held
    for `--hold` seconds and checked the same way, and the summary lists every link's last timeout.

    With the iPhone below a flagged phone, the phone dials, unless it has not by the time the iPhone's 12 s head start
    ends; then the iPhone dials it (interop-audit finding AND-2), and is that link's central. Each head-start link
    must find the doorbell and end at 5 s too. `--links N` then counts head-start links: each time it stops the
    iPhone's mesh, waits `--away` seconds so that the phone's sighting of the iPhone lingers out, starts it, and times
    the first link from there, as MVP item 2 does. A link the phone dialed is checked and reported, and not counted.
    The iPhone's own log, over USB, shows each head-start line. `--wake screen` keeps an open phone's screen on
    without nudging its scans, and `--wake none` never wakes the phone, so that a screen-off phone keeps its own
    scan cadence."""
    phone = Phone(arguments.device)
    phone.wakes = arguments.wake
    ios = IPhone(arguments.udid, arguments.host)
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
    above = order == "iphone-above"
    tally: list[dict] = []
    head_starts: list[dict] = []
    knit = None if above else _iphone_log(ios, f"interop-iphone-{nonce}.log")
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
                "wakes": phone.wakes,
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
        head_start = not above
        step = run.step("link-balanced", lambda: _balanced(phone, ios.node_id, tally, fresh=False, head_start=head_start))
        balanced = step is not None
        if not arguments.skip_offline:
            phone.shell("logcat -c")
            _offline(run, ios, phone, phone_id, nonce)
            run.step("relink-dialer", lambda: _dialed_by(phone, ios, phone_id, order))
            if balanced:
                # The doorbell lookup and the put-back come seconds after the link: judge it once it has held.
                ups = ios.lines(lambda line: _link(line, phone_id))
                time.sleep(max(0.0, ups[-1]["_at"] + arguments.hold - time.monotonic()) if ups else 0.0)
                balanced = run.step("relink-balanced", lambda: _balanced(phone, ios.node_id, tally, head_start=head_start)) is not None
        run.step("custody-converges", lambda: _converges(ios, phone, 180))
        if balanced and above:
            _relinks(run, ios, phone, phone_id, arguments.links, arguments.hold, 180, tally)
        elif balanced and arguments.links > 1:
            _head_start_relinks(run, ios, phone, phone_id, arguments, tally, head_starts, knit)
    finally:
        ios.stop()
        if knit:
            knit.stop()
    summary = {"summary": "iphone", "steps": run.steps, "failed": run.failed, "lastTimeouts": _last_timeouts(tally)}
    if head_starts:
        summary["headStarts"] = head_starts
    print(json.dumps(summary))
    return run.failed


def _dialed_by(phone: Phone, ios: IPhone, phone_id: str, order: str) -> dict:
    """Which side dialed the last link between the phone and the iPhone, from the phone's log since it was last cleared:
    `bt connect ok` is a dial of the phone's own, and `bt accepted client` one it took. The phone dials only when the
    iPhone sorts below it and the phone's advert, as the iPhone sights it, sets FLAG_DIALS_GATT_PEERS, or when it has
    held no link for three minutes and the iPhone sorts above it (knit-next #103). Such a lonely dial is reported, as
    is the link it opened, and only a dial the rules don't allow fails the step. The iPhone refuses a lonely phone it
    has sighted, so those dials end `HANDSHAKE` and the iPhone dials. Below a flagged phone, the iPhone dials it once
    its head start ends, and that is reported too."""
    flags = next((s["flags"] for s in ios.command(cmd="links")["sightings"] if s["peer"] == phone_id), None)
    expected = "phone" if order == "iphone-below" and flags is not None and flags & DIALS_GATT_PEERS else "iphone"
    lines = _phone_lines(phone)
    detail: dict = {"phoneFlags": flags}
    if expected == "iphone":
        dials = _phone_dials(lines, ios.node_id)
        stray = [dial for dial in dials if not dial["lonely"]]
        if stray or (dials and order == "iphone-below"):
            raise RuntimeError(f"the phone dialed the iPhone, which the {expected} should have dialed: {(stray or dials)[:2]}")
        if dials:
            detail["lonelyDials"] = dials
    ends = [line for line in lines if line.startswith((f"bt connect ok {ios.node_id}", f"bt accepted client {ios.node_id} "))]
    if not ends:
        # A link already up when the run began left nothing in the cleared log.
        return {"dialer": None, "expected": expected, **detail}
    dialer = "phone" if ends[-1].startswith("bt connect ok") else "iphone"
    if dialer != expected:
        if detail.get("lonelyDials", [{}])[-1].get("outcome") == "linked":
            return {"dialer": dialer, "outcome": "lonely dial", **detail}
        if dialer == "iphone" and order == "iphone-below":
            # The phone had not dialed by the end of the iPhone's head start (interop-audit finding AND-2).
            return {"dialer": dialer, "outcome": "head start", **detail}
        raise RuntimeError(f"the {dialer} dialed; with the phone's flags at {flags} the {expected} should have: {ends[-2:]}")
    return {"dialer": dialer, **detail}


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
    ios = IPhone(arguments.udid, arguments.host)
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
        self.peer = Peer("android", f"knit-peer wake {nonce}", others, arguments.peer_log, arguments.rssi_floor, "iphone-wake", hci0())
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


def android_keeps_iphone(arguments: argparse.Namespace) -> int:
    """knit-next's AND-3 fix (`gatt-only-link-score`): an Android phone keeps the link of an iPhone it can no longer
    hear, and admits the iPhone's own dial back. Android sights a foreground iPhone only by its GATT payload; once Knit
    leaves the front, iOS moves its UUID to the overflow area, Android stops hearing it, and 90 s later the iPhone
    leaves its presence. Before the fix that link scored -127 dBm, the first shed at the cap, and the iPhone's re-dial
    was refused as a sighted dialer below the phone for those 90 s. Nobody touches the iPhone: `KnitFront` moves Knit
    away from the front and back from the Mac, unless `--prompts` asks a person.

    - **held:** the phone sits at its cap (`BLECAP` max = the links it holds), Knit leaves the front, and after more
        than 90 s the phone's eviction-score line must show the iPhone's link at the floor, -90, never -127. Then the link
        must hold for `--minutes`, a DM from the phone each minute, `link-held` as `iphone-wake` reads it.
    - **redial:** with Knit back in front and the phone hearing it again, Knit leaves the front, and once the phone has
        not heard it for 12 s the phone sheds the link (`BLECAP` max 0). The cap stays at 0 until the iPhone's seek dial
        comes, so the phone cannot dial the iPhone back first from its presence. That dial is refused at the cap, but its
        line must say `sighted=false`, with `inPresence=true` and a `heardAgoMs` of 12 to 90 s: Rule 2's verdict, where
        the old rule said `sighted=true` and refused it for being below the phone. Then the cap clears, and a link the
        iPhone dials back must end at BALANCED's 5 s timeout (#102). `--baseline` expects `sighted=true` instead.

    The phone's id must sort above the iPhone's, which is the order the old rule refused. Other Android phones in range
    can take the cap's slots or be the candidate that sheds the iPhone, so `--quiet` pauses their meshes for the run."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    front = KnitFront("prompts" if arguments.prompts else arguments.mover, arguments.away_wait, arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    quiet = [Phone(serial) for serial in arguments.quiet]
    stages = arguments.stages.split(",")
    run.step("device-steps-built", front.prepare)
    try:
        ios.start()
    except TimeoutError:
        run.step("knit-opened", lambda: front.to_front(ios))
    sender = _PhoneSender(phone, ios)
    phone_id = sender.node_id
    print(json.dumps({"run": "android-keeps-iphone", "phone": phone_id, "iphone": ios.node_id, "stages": stages, "mover": front.mover}))
    if phone_id < ios.node_id:
        ios.stop()
        sys.exit(f"the phone's id sorts below the iPhone's ({phone_id} < {ios.node_id}): pick a phone above it")
    try:
        for other in quiet:
            run.step(f"paused-{other.serial}", lambda other=other: _paused(other, True))
        if "held" in stages:
            _held_at_cap(run, phone, ios, sender, front, arguments, nonce)
        if "redial" in stages:
            _redialed(run, phone, ios, sender, front, arguments)
    finally:
        # Whatever failed, and however the run ended, the cap goes and every paused phone runs again.
        run.step("cap-cleared", lambda: {"cap": phone.bridge("BLECAP", clear=True).get("cap")})
        for other in quiet:
            run.step(f"resumed-{other.serial}", lambda other=other: _paused(other, False))
        if ios.socket is None and not front.prompts:
            # A stage that failed while Knit was away leaves it there; the lab expects it in front.
            run.step("knit-front-at-end", lambda: front.to_front(ios))
        ios.stop()
    print(json.dumps({"summary": "android-keeps-iphone", "steps": run.steps, "failed": run.failed}))
    return run.failed


class KnitFront:
    """Moves Knit out of the iPhone's front and back, never launching it afresh, so the running Knit and its links live
    on. `devicectl`, with nobody at the iPhone: the Mac's devicectl opens the Settings app, then opens Knit again, which
    brings the running process back rather than starting one. `devicetest` does the same through `BackgroundTests`, run
    from an xctestrun that leaves Knit out of the install (`KNIT_DEVICE_KEEP_KNIT`, `scripts/check.sh`); with a passcode
    set, iOS asks for it on the phone before each run's automation mode, so that needs someone there. `prompts` asks a
    person, as `iphone-wake` does. KNIT_DEVICE_STEP_WRAP prefixes each Mac build or test, such as a build lock."""

    TESTS = "KnitDeviceTests/BackgroundTests"
    KNIT = "app.getknit.knit.dev"
    SETTINGS = "com.apple.Preferences"

    def __init__(self, mover: str, wait: float, udid: str | None) -> None:
        self.mover = mover
        self.prompts = mover == "prompts"
        self.wait = wait
        self.udid = udid or first_usb_iphone()
        self.wrap = shlex.split(os.environ.get("KNIT_DEVICE_STEP_WRAP", ""))
        self.log = ROOT / ".build" / "knit-front.log"

    def prepare(self) -> dict:
        """Syncs this tree to the Mac and builds the steps for the iPhone, signed; a run then only installs the runner."""
        if self.mover != "devicetest":
            return {"mover": self.mover}
        return self._mac(["env", f"KNIT_DEVICE={self.udid}", "KNIT_DEVICE_KEEP_KNIT=build", "scripts/check.sh", "devicetest"], sync=True)

    def away(self, ios: IPhone) -> dict:
        """Knit leaves the front, and iOS suspends it: the bridge stops answering, as `_suspended` sees."""
        if self.prompts:
            print(json.dumps({"action": "open the Settings app on the iPhone, leaving Knit running behind it"}), flush=True)
            moved = {}
        elif self.mover == "devicectl":
            moved = self._open(self.SETTINGS)
        else:
            moved = self._mac(self._step("testSendKnitToBackground"))
        suspended = _suspended(ios, self.wait)
        ios.stop()
        return {**moved, "suspendedAfter": suspended["seconds"]}

    def to_front(self, ios: IPhone) -> dict:
        """Knit comes back to the front, and its bridge answers again."""
        if self.prompts:
            print(json.dumps({"action": "open Knit on the iPhone"}), flush=True)
            moved = {}
        elif self.mover == "devicectl":
            moved = self._open(self.KNIT)
        else:
            moved = self._mac(self._step("testBringKnitToFront"))
        opened = _reopened(ios, self.wait)
        return {**moved, "bridgeAfter": opened["seconds"]}

    def _step(self, test: str) -> list[str]:
        only = f"KNIT_DEVICE_TESTS={self.TESTS}/{test}"
        return ["env", f"KNIT_DEVICE={self.udid}", "KNIT_DEVICE_KEEP_KNIT=1", only, "scripts/check.sh", "devicetest"]

    def _open(self, bundle: str) -> dict:
        """Brings `bundle` to the iPhone's front through the Mac's devicectl, which needs no automation mode. Without
        `--terminate-existing` it brings a running app forward in the same process, as Knit's pid showed (2026-10-10)."""
        started = time.monotonic()
        command = ["xcrun", "devicectl", "device", "process", "launch", "--device", self.udid, bundle]
        result = subprocess.run(
            [str(ROOT / "scripts" / "mac.sh"), "run", *command], capture_output=True, text=True, env={**os.environ, "KNIT_MAC_SYNC": "0"}, check=False
        )
        with open(self.log, "a", encoding="utf-8") as log:
            log.write(f"\n== {shlex.join(command)} (exit {result.returncode})\n{result.stdout}{result.stderr}")
        if result.returncode:
            raise RuntimeError(f"devicectl could not open {bundle} (exit {result.returncode}): {result.stderr.strip()[-300:]}")
        return {"opened": bundle, "macSeconds": round(time.monotonic() - started, 1)}

    def _mac(self, command: list[str], sync: bool = False) -> dict:
        """Runs `command` in the Mac's mirror, its output appended to the log; a failed or skipped test raises. Only the
        build syncs the tree, so a step costs no more than the test."""
        started = time.monotonic()
        environment = {**os.environ, "KNIT_MAC_SYNC": "1" if sync else "0"}
        result = subprocess.run(
            [*self.wrap, str(ROOT / "scripts" / "mac.sh"), "run", *command], capture_output=True, text=True, env=environment, check=False
        )
        output = result.stdout + result.stderr
        with open(self.log, "a", encoding="utf-8") as log:
            log.write(f"\n== {shlex.join(command)} (exit {result.returncode})\n{output}")
        tail = output.strip().splitlines()[-5:]
        if result.returncode:
            raise RuntimeError(f"the Mac's step failed (exit {result.returncode}, {self.log}): {tail}")
        if re.search(r"\bskipped\b", output, re.IGNORECASE):
            raise RuntimeError(f"the step skipped: Knit was not running ({self.log})")
        return {"macSeconds": round(time.monotonic() - started, 1)}


# The eviction score each link carries on the phone (knit-next gatt-only-link-score): the last field of a debug build's
# `bt state` line, `linkScores=<node id>:<dBm>,…`, logged each minute. An eviction logs `bt evicting <id> (score=<dBm>
# doorbell=<bool>)` too.
SCORE_LINE = " linkScores="
# The floor a link scores when Android cannot sight its peer (UNSIGHTED_LINK_RSSI), and the score of one that left
# presence (ABSENT_LINK_RSSI), which a backgrounded iPhone had before the fix.
FLOOR_SCORE = -90.0
ABSENT_SCORE = -127.0
# Rule 2's window: a doorbell dialer counts as sighted only if the phone heard it this recently, and presence lingers
# this long after the last sighting.
HEARD_RECENTLY_MS = 12_000
PRESENCE_LINGER_MS = 90_000


def _held_at_cap(run: Run, phone: Phone, ios: IPhone, sender: _PhoneSender, front: KnitFront, arguments: argparse.Namespace, nonce: str) -> None:
    ios_id = ios.node_id
    if run.step("phone-hears-iphone", lambda: _sighted_link(phone, ios, sender.node_id)) is None:
        return
    run.step("phone-at-cap", lambda: _at_cap(phone))
    if run.step("knit-away", lambda: front.away(ios)) is None:
        return
    away = time.monotonic()
    time.sleep(max(0.0, away + PRESENCE_LINGER_MS / 1000 + 10 - time.monotonic()))
    phone.shell("logcat -c")
    run.step("iphone-scores-the-floor", lambda: _scored(phone, ios_id, lambda score: score == FLOOR_SCORE, 150))
    sender.begin()
    sent = _wake_window(sender, nonce, arguments.minutes)
    run.step("link-held", lambda: sender.held(sum(dm["linkGone"] for dm in sent)))
    run.step("iphone-still-scores-the-floor", lambda: _scored(phone, ios_id, lambda score: score == FLOOR_SCORE, 150))
    phone.bridge("BLECAP", clear=True)
    if run.step("knit-front", lambda: front.to_front(ios)) is not None:
        run.step("link-held-on-iphone", lambda: _ios_still_linked(ios, sender.node_id))


def _redialed(run: Run, phone: Phone, ios: IPhone, sender: _PhoneSender, front: KnitFront, arguments: argparse.Namespace) -> None:
    ios_id = ios.node_id
    if ios.socket is None and run.step("knit-front", lambda: front.to_front(ios)) is None:
        return
    phone.bridge("BLECAP", clear=True)
    if arguments.baseline:
        if run.step("redial-link", lambda: _ios_linked(ios, phone, sender.node_id, 360)) is None:
            return
        # A build without the fix logs no scores: give the phone the time a fresh link takes to read the payload.
        time.sleep(30)
    elif run.step("redial-phone-hears-iphone", lambda: _sighted_link(phone, ios, sender.node_id)) is None:
        return
    away = time.monotonic()
    if run.step("redial-knit-away", lambda: front.away(ios)) is None:
        return
    # The phone last heard Knit no later than it left the front, which the step began with. The shed comes as soon
    # as that is 12 s past, so the iPhone's dial lands inside the 90 s presence holds: the first dial that reached the
    # phone came 40 s after the shed (2026-10-10), and a 15 s wait after the suspension had let presence run out.
    time.sleep(max(0.0, away + HEARD_RECENTLY_MS / 1000 + 1 - time.monotonic()))
    phone.shell("logcat -c")
    shed = time.monotonic()
    # The cap stays at 0 until the iPhone has dialed: with a slot free, the phone dials the iPhone itself from the
    # presence it still holds, 8 s after the shed (2026-10-10), and the iPhone's own dial never comes. A dial at the cap
    # is refused, but its line still says whether Rule 2 counted the iPhone as sighted, which is the verdict under test.
    phone.bridge("BLECAP", max=0)
    try:
        run.step("phone-shed-iphone", lambda: {"lines": poll(lambda: _phone_log(phone, f"link down: {ios_id}"), 40, every=1)[:2]})
        if arguments.baseline:
            run.step("phone-judges-redial-sighted", lambda: _judged(phone, ios_id, shed, arguments.redial_timeout, sighted=True))
        else:
            run.step("phone-judges-redial-unsighted", lambda: _judged(phone, ios_id, shed, arguments.redial_timeout, sighted=False))
    finally:
        phone.bridge("BLECAP", clear=True)
    relinked = run.step("redial-relinked", lambda: _relinked_by(phone, ios_id, 180))
    if relinked is not None and relinked["by"] == "iphone":
        time.sleep(arguments.hold)
        tally: list[dict] = []
        run.step("redial-balanced", lambda: {**_balanced(phone, ios_id, tally), **_held_since_accept(phone, ios_id), "heldSeconds": arguments.hold})
    if run.step("redial-knit-front", lambda: front.to_front(ios)) is not None:
        run.step("redial-link-on-iphone", lambda: _ios_linked(ios, phone, sender.node_id))


def _held_since_accept(phone: Phone, node: str) -> dict:
    """The phone logged no link down for `node` after it last accepted its dial; the shed before it logged one."""
    lines = _phone_lines(phone)
    accepts = [index for index, line in enumerate(lines) if line.startswith(f"bt accepted client {node} ")]
    downs = [line for line in lines[accepts[-1] if accepts else 0 :] if f"link down: {node}" in line]
    if downs:
        raise RuntimeError(f"the phone dropped the re-dialed link: {downs[:3]}")
    return {}


def _judged(phone: Phone, node: str, since: float, timeout: float, sighted: bool) -> dict:
    """The phone's verdict on the iPhone's first dial after the shed at `since`, made while the shed's cap of 0 still
    stood. With the fix, Rule 2 counts the iPhone as unsighted: `sighted=false` beside `doorbell=true`, `inPresence=true`
    and a `heardAgoMs` between 12 and 90 s, the case the old rule refused as a sighted dialer below the phone. Without
    the fix (`sighted`), the same dial reads `sighted=true`, and the line has no doorbell suffix."""
    verdict = poll(lambda: next(iter(_client_verdicts(phone, node)), None), timeout, every=1)
    detail = {"secondsAfterShed": round(time.monotonic() - since, 1), "verdict": verdict}
    if verdict.get("sighted") is not sighted:
        raise RuntimeError(f"the phone judged the dial sighted={verdict.get('sighted')}, not {sighted}: {json.dumps(detail)}")
    if sighted:
        return detail
    if verdict.get("doorbell") is not True or verdict.get("doorbellTrusted") is False:
        raise RuntimeError(f"no trusted doorbell suffix: {json.dumps(detail)}")
    heard = verdict.get("heardAgoMs")
    if verdict.get("inPresence") is not True or not isinstance(heard, int) or not HEARD_RECENTLY_MS < heard <= PRESENCE_LINGER_MS:
        raise RuntimeError(f"judged outside the 12-90 s window in presence: {json.dumps(detail)}")
    return detail


def _relinked_by(phone: Phone, node: str, timeout: float) -> dict:
    """Who brought the link back once the cap cleared: the iPhone, whose dial the phone accepted (`bt accepted client`),
    or the phone, which dialed the iPhone itself (`bt initiating to`)."""

    def back() -> dict | None:
        lines = _phone_lines(phone)
        if not any(line.startswith(f"bt link up: {node}") for line in lines):
            return None
        accepted = [v for v in _client_verdicts(phone, node) if v["verdict"] == "accepted"]
        dialed = [line for line in lines if line.startswith(f"bt initiating to {node}")]
        return {"by": "iphone" if accepted else "phone", "accepted": accepted[-1:], "dialed": dialed[-1:]}

    return poll(back, timeout, every=2)


def _paused(phone: Phone, paused: bool) -> dict:
    """Pauses another phone's mesh for an hour, or resumes it, as its notification's Pause and Resume do."""
    reply = phone.bridge("PAUSE", minutes=60) if paused else phone.bridge("RESUME")
    return {"reply": reply.get("status")}


def _at_cap(phone: Phone) -> dict:
    """Caps the phone's links at the number it holds now, so the next link it wants must shed one."""
    linked = phone.bridge("BLECAP")["linked"]
    if not linked:
        raise RuntimeError("the phone holds no link to cap")
    reply = phone.bridge("BLECAP", max=min(int(linked), 6))
    return {"cap": reply["cap"], "linked": reply["linked"]}


def _sighted_link(phone: Phone, ios: IPhone, phone_id: str, tries: int = 4) -> dict:
    """A link the phone holds to the iPhone after sighting it, which is AND-3's case: its score is a raw RSSI while
    Knit is in front. A link the iPhone dialed first is never sighted, since the phone reads no payload from an address
    a link holds, and scores the floor under either rule; then the iPhone refuses the phone a moment, which ends that
    link, and lets it dial again. A phone that was just installed, or whose links were just paused away, can take
    minutes to link an iPhone at all."""
    floors = 0
    for attempt in range(tries):
        linked = _ios_linked(ios, phone, phone_id, 360)
        phone.shell("logcat -c")
        try:
            return {**_scored(phone, ios.node_id, _heard_score, 300), "linkedAfter": linked["seconds"], "relinks": attempt}
        except RuntimeError:
            floors += 1
        if attempt + 1 < tries:
            ios.command(cmd="deny-link", peer=phone_id)
            time.sleep(10)
            ios.command(cmd="allow-link", peer=phone_id)
    raise RuntimeError(f"the phone never held a sighted link to the iPhone: {floors} links scored the floor in front")


def _heard_score(score: float) -> bool:
    """A score the phone gives a link whose peer is in its presence: the raw RSSI, which may sit below the floor, so
    anything but the floor itself and the absent score."""
    return score not in (FLOOR_SCORE, ABSENT_SCORE)


def _scores(phone: Phone) -> list[dict[str, float]]:
    """Each eviction-score line the phone logged since its log was last cleared, as node id to score, oldest first."""
    scored = []
    for line in _phone_log(phone, SCORE_LINE):
        tail = line.split(SCORE_LINE, 1)[1]
        scored.append({node: float(score) for node, score in re.findall(r"([a-z2-7]{26}):(-?\d+(?:\.\d+)?)", tail)})
    return scored


def _scored(phone: Phone, node: str, wanted, timeout: float) -> dict:
    """The first score line, logged since the phone's log was cleared, that scores `node`'s link as `wanted` says; any
    line that scores it otherwise is reported if none does."""
    seen: list[float] = []

    def look() -> dict | None:
        seen.clear()
        for scores in _scores(phone):
            if node in scores:
                seen.append(scores[node])
                if wanted(scores[node]):
                    return {"score": scores[node], "links": len(scores)}
        return None

    try:
        return poll(look, timeout, every=5)
    except TimeoutError:
        raise RuntimeError(f"no score line scored {node} as wanted in {timeout:.0f} s; it scored {seen[-5:] or 'nothing'}") from None


CLIENT_VERDICT = re.compile(r"bt (accepted|refused) client ([a-z2-7]{26}) \((.*?)\)")


def _client_verdicts(phone: Phone, node: str) -> list[dict]:
    """Every admission line the phone logged for `node`'s dials since its log was cleared, oldest first, with its fields:
    `bt refused client <id> (sighted=<b> codedOnly=<b> heldAgeMs=<ms|null> atCap=<b>[ doorbell=true heardAgoMs=<ms|null>
    inPresence=<b>[ doorbellTrusted=false]])`, and `bt accepted client <id> (<Admit|Replace>, sighted=<b> codedOnly=<b>[ …])`
    with the same suffix, whose verdict comes back as `as`. Booleans, numbers and null come back as Python's."""
    verdicts = []
    for line in _phone_log(phone, " client "):
        match = CLIENT_VERDICT.search(line)
        if not match or match.group(2) != node:
            continue
        fields: dict = {"verdict": match.group(1)}
        first = match.group(3).split(",", 1)[0]
        if "=" not in first:
            fields["as"] = first
        for key, value in re.findall(r"(\w+)=(\S+)", match.group(3)):
            fields[key] = {"true": True, "false": False, "null": None}.get(value, int(value) if value.lstrip("-").isdigit() else value)
        verdicts.append(fields)
    return verdicts


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
    payload and dials it. The ATS2851 now on hci1 takes no incoming LE connection, so this run needs a dongle that
    does, such as the Edimax it replaced (.agents/context/linux-peer.md, "What the ATS2851 showed"). The peer rings the
    iPhone back, once BlueZ has read the iPhone's services."""
    ios = IPhone(arguments.udid, arguments.host)
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

    `--order peer-above`: the phone reads the payload and never dials, unless it has held no link for three minutes
    (knit-next #103), and those lonely dials are reported; the peer dials, and the phone accepts it as a dialer it
    sighted, which only the read can have given it. The peer refuses the phone until the phone has logged the read,
    or its dial could land first and be admitted unsighted under A1. The peer is then the link's central, so
    each link must end at knit-next #102's 5 s supervision timeout, not BlueZ's 420 ms put back after the doorbell
    lookup (`link-balanced`). `--links N` brings the link down and up again until N links have found the doorbell,
    each dialed by the peer, held for `--hold` seconds and checked the same way, and the summary lists every link's
    last timeout. `--hci0` runs the peer and its scan on the maintainer's adapter, shared, which needs its own
    go-ahead: the ATS2851 now on hci1 takes no incoming connection, so a phone cannot read a peer there.

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
    adapter = hci0() if arguments.hci0 else None
    heard = in_range(adapter=adapter)
    # An iPhone the scan could not read, as its reads on hci0 can drop, is still no earlier run's peer, and advertises
    # as this port's nodes do.
    heard.update({node: {"capabilities": IOS_ADVERT_CAPABILITIES} for node in arguments.known.split(",") if node and node not in heard})
    others = set(heard) - {phone_id}
    flagged = bool(heard.get(phone_id, {}).get("flags", 0) & DIALS_GATT_PEERS)
    below = arguments.order == "peer-below"
    # Every peer this adapter runs has its address, so the phone must have let the last one go first, and the payload
    # it read there too: one above the phone lasts until the address goes quiet (the open case, ADR 2026-09.xzpt).
    if run.step("phone-forgot-old-peers", lambda: _phone_forgets_all_but(phone, set(heard))) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    address = lab("KNIT_ADAPTER_B") if arguments.hci0 else hci1_address()
    if run.step("phone-forgot-old-payload", lambda: _address_released(phone, address, arguments.quiet_timeout)) is None:
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
    # hci0 holds the maintainer's own links, so only hci1 can be checked for a stray one.
    if not arguments.hci0 and run.step("hci1-idle", lambda: _hci1_idle_after(3)) is None:
        print(json.dumps({"summary": "android-reads", "steps": run.steps, "failed": run.failed}))
        return run.failed
    peer = Peer("ios", f"knit-peer reads {nonce}", refused, arguments.peer_log, arguments.rssi_floor, adapter=adapter, never_sight=held)
    mark = peer.log_mark()
    stop = threading.Event()
    link = None
    tally: list[dict] = []
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
                run.step("phone-never-dialed", lambda: _phone_never_dialed(phone, peer_id, hci1=not arguments.hci0))
            time.sleep(max(0.0, link["at"] + arguments.hold - time.monotonic()))
            run.step("link-held", lambda: {**_phone_held(phone, peer_id), **_no_link_dropped(peer, {phone_id}), "heldSeconds": arguments.hold})
            if not below and run.step("link-balanced", lambda: _balanced(phone, peer_id, tally)) is None:
                link = None
        run.step("reads-only-uuid-nodes", lambda: _reads_only_uuid_nodes(phone, peer_id, androids(heard)))
        run.step("phone-gatt-counts", lambda: _reads_gatt_payloads(phone))
        if link is not None and not below:
            _relinks(run, peer, phone, phone_id, arguments.links, arguments.hold, arguments.link_timeout, tally)
    finally:
        stop.set()
        peer.stop()
    summary = {"summary": "android-reads", "steps": run.steps, "failed": run.failed}
    if not below:
        summary["lastTimeouts"] = _last_timeouts(tally)
    print(json.dumps(summary))
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


# knit-next #154's budget (GattPayloads.BUDGET_READS, BUDGET_WINDOW_MS) and the longest a ripe dial may wait behind
# the one read in flight: its 12 s connect watchdog.
GATT_BUDGET_READS = 12
GATT_BUDGET_WINDOW = 600.0
GATT_READ_TIMEOUT = 12.0
# The root wrapper that runs btmgmt on one of Knit's own adapters (scripts/knit-hci.sh, installed by the maintainer).
KNIT_HCI = "/usr/local/sbin/knit-hci"
# `logcat -v epoch`: seconds since the epoch, pid, tid, level, tag, then the message.
EPOCH_LINE = re.compile(r"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+\w\s+BluetoothMeshTransport\s*:\s(.*)$")
GATT_READ_END = re.compile(r"^bt gatt read (\S+) (?:→ ([a-z2-7]{26})|failed \(|stranger \()")
GATT_CONFIRMED = re.compile(r"^bt gatt confirmed (\S+) → ([a-z2-7]{26})")


class LogcatCapture:
    """The phone's Bluetooth transport log, streamed to a file for a run longer than logcat's ring buffer holds. A
    network adb stream can die while the phone sleeps (the iPhone reinstall note in the lab's memory), so the stream is
    started again from the last second it wrote, and lines it writes twice are dropped."""

    def __init__(self, phone: Phone, path: Path) -> None:
        self.phone = phone
        self.path = path
        self.stop_event = threading.Event()
        self.process: subprocess.Popen[str] | None = None
        self.thread = threading.Thread(target=self._stream, daemon=True)
        self.restarts = 0

    def start(self) -> None:
        self.path.write_text("")
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.process and self.process.poll() is None:
            self.process.terminate()
        self.thread.join(timeout=10)

    def _stream(self) -> None:
        last: float | None = None
        seen_at_last: set[str] = set()
        with open(self.path, "a", encoding="utf-8") as out:
            while not self.stop_event.is_set():
                command = ["adb", "-s", self.phone.serial, "logcat", "-v", "epoch", "-s", "BluetoothMeshTransport:*"]
                if last is not None:
                    command += ["-T", f"{last:.3f}"]
                self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
                assert self.process.stdout
                for raw in self.process.stdout:
                    match = EPOCH_LINE.match(raw)
                    if not match:
                        continue
                    at = float(match.group(1))
                    if last is not None and (at < last or (at == last and raw in seen_at_last)):
                        continue
                    if at != last:
                        last, seen_at_last = at, set()
                    seen_at_last.add(raw)
                    out.write(raw)
                    out.flush()
                self.process.wait()
                if self.stop_event.wait(2):
                    break
                self.restarts += 1
                if ":" in self.phone.serial:
                    self.phone.reconnect()

    def lines(self) -> list[tuple[float, str]]:
        """Every captured line as its time and its message, in order."""
        return _epoch_lines(self.path.read_text(encoding="utf-8").splitlines())


def _epoch_lines(raw: list[str]) -> list[tuple[float, str]]:
    lines = []
    for line in raw:
        match = EPOCH_LINE.match(line)
        if match:
            lines.append((float(match.group(1)), match.group(2)))
    return lines


def _charged_reads(lines: list[tuple[float, str]]) -> list[tuple[float, str]]:
    """The reads knit-next #154 charges, as the time and address of each: every read that ended, whatever it found,
    less each a link confirmed, which refunds the latest charged read at that address that named the confirmed node."""
    charges: list[tuple[float, str, str | None]] = []
    for at, message in lines:
        if ended := GATT_READ_END.match(message):
            charges.append((at, ended.group(1), ended.group(2)))
        elif confirmed := GATT_CONFIRMED.match(message):
            address, node = confirmed.groups()
            for index in range(len(charges) - 1, -1, -1):
                if charges[index][1] == address and charges[index][2] == node:
                    del charges[index]
                    break
    return [(at, address) for at, address, _ in charges]


def _most_charged(charges: list[tuple[float, str]], window: float = GATT_BUDGET_WINDOW) -> dict:
    """The most charged reads any window held, and when: a charge leaves the window `window` seconds after it, as
    `GattPayloads.prune` drops it."""
    times = sorted(at for at, _ in charges)
    most, when, start = 0, None, 0
    for end, at in enumerate(times):
        while at - times[start] >= window:
            start += 1
        if end - start + 1 > most:
            most, when = end - start + 1, at
    return {"most": most, "at": when}


def _dial_waits(lines: list[tuple[float, str]], node: str) -> dict:
    """How long each of the phone's dials of `node` waited after the connect loop first promoted it: from the first
    `promote=[…]` naming it to its `bt initiating to`. A promotion while that dial is in flight, or once the link is up,
    starts no wait; one still waiting at the end of the log is reported as `waiting`."""
    waits: list[float] = []
    since: float | None = None
    dialing = linked = False
    end = lines[-1][0] if lines else 0.0
    for at, message in lines:
        if message.startswith("promote=") and node in message.split(" evict=", 1)[0]:
            if since is None and not dialing and not linked:
                since = at
        elif message.startswith(f"bt initiating to {node} "):
            if since is not None:
                waits.append(round(at - since, 1))
            since, dialing = None, True
        elif message.startswith((f"bt connect {node} failed", f"bt connect ok {node} ")):
            dialing = False
        elif message.startswith(f"bt link up: {node} "):
            since, dialing, linked = None, False, True
        elif message.startswith(f"bt link down: {node} "):
            linked = False
    return {"waits": waits, "waiting": round(end - since, 1) if since is not None else None}


def _btmgmt(adapter: str, commands: list[str]) -> str:
    """Runs btmgmt `commands` on one of Knit's own adapters, through the root wrapper, and answers what it printed.
    btmgmt quits at the end of its input before the replies arrive, so each command gets a moment before the next, and
    the input stays open until the last has answered."""
    process = subprocess.Popen(
        ["sudo", "-n", KNIT_HCI, adapter, "btmgmt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    assert process.stdin
    for command in commands:
        process.stdin.write(command + "\n")
        process.stdin.flush()
        time.sleep(2)
    process.stdin.close()
    output, _ = process.communicate(timeout=30)
    output = re.sub(r"\x1b\[[0-9;]*m", "", output)
    if process.returncode:
        raise RuntimeError(f"knit-hci {adapter} btmgmt failed ({process.returncode}): {output.strip()[-300:]}")
    return output


def _privacy(adapter: str, on: bool) -> dict:
    """Turns LE privacy on or off on one of Knit's own adapters: with it on, the adapter advertises from a resolvable
    private address, while its identity, which knit-peer finds it by, stays its public address (ADR 2026-09.5ftc). The
    adapter must be powered off to change it."""
    state = "on" if on else "off"
    settings = re.findall(r"current settings: (.*)", _btmgmt(adapter, ["power off", f"privacy {state}", "power on", "info"]))
    if not settings:
        raise RuntimeError(f"btmgmt on dongle {adapter.upper()} printed no settings")
    if ("privacy" in settings[-1].split()) != on:
        raise RuntimeError(f"privacy is not {state} on dongle {adapter.upper()}: {settings[-1]}")
    return {"adapter": adapter, "settings": settings[-1].strip()}


def _rpa_timeout(adapter: str, seconds: int) -> dict:
    """Has one of Knit's adapters rotate its resolvable private address every `seconds`, through the root wrapper's
    hcitool: HCI LE Set Resolvable Private Address Timeout (`0x08|0x002E`, 1 to 3600 s). Under LE privacy the kernel
    advertises with own address type `0x03`, so the controller makes the address itself from the key in its resolving
    list, and rotates it on this timeout, which the kernel sets to 900 s. A fresh advert registration moves nothing on
    the lab dongles (`.agents/context/linux-peer.md`, "What the stranger trial showed"). The kernel sets the timeout
    again when the adapter powers on, so this follows `_privacy`."""
    if not 1 <= seconds <= 3600:
        raise ValueError(f"an RPA timeout of {seconds} s is outside 1 to 3600")
    low, high = seconds & 0xFF, seconds >> 8
    result = subprocess.run(
        ["sudo", "-n", KNIT_HCI, adapter, "hcitool", "cmd", "0x08", "0x002e", f"0x{low:02x}", f"0x{high:02x}"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    # The Command Complete's parameters: ncmd, the opcode's two bytes, then the status.
    reply = result.stdout.strip().splitlines()[-1].split() if result.stdout.strip() else []
    if result.returncode or reply[-1:] != ["00"]:
        raise RuntimeError(f"LE Set Resolvable Private Address Timeout failed on dongle {adapter.upper()}: {result.stdout.strip()[-200:]}")
    return {"adapter": adapter, "rpaTimeoutSeconds": seconds}


class Stranger:
    """`knit-peer stranger` on dongle B: the `0xFE30` UUID advertised as a device that is not Knit's, registered afresh
    every `rotate` seconds, serving no payload or a forged one, and never linking (knit-ios #3)."""

    def __init__(self, payload: str, rotate: int, seconds: int, log_path: Path) -> None:
        self.command = [
            str(PEER), "stranger", "--payload", payload, "--rotate", str(rotate), "--seconds", str(seconds), "--log", "info", *hci0()
        ]
        self.log_path = log_path
        self.process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        self.log_path.write_text("")
        log = open(self.log_path, "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(self.command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, text=True)
        poll(lambda: any("stranger advertising 0xFE30" in m for m in self.messages()) or self.process.poll() is not None, 30, every=1)
        if self.process.poll() is not None:
            raise RuntimeError(f"knit-peer stranger exited ({self.process.returncode}): {self.messages()[-3:]}")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def messages(self) -> list[str]:
        messages = []
        for line in self.log_path.read_text(encoding="utf-8").splitlines():
            try:
                messages.append(json.loads(line).get("message", ""))
            except json.JSONDecodeError:
                continue
        return messages



def _budgets_gatt_reads(phone: Phone) -> dict:
    """The phone runs a build with knit-next #154: its `bt state` line carries `gattBudget=<used>/<budget>`."""
    try:
        lines = poll(lambda: _phone_log(phone, "bt state "), 75, every=5)
    except TimeoutError as error:
        raise RuntimeError("the phone logged no bt state line in 75 s: is Knit running, and a debug build?") from error
    budget = re.search(r"gattBudget=(\d+)/(\d+)", lines[-1])
    if not budget:
        raise RuntimeError("the phone's build predates knit-next #154 (8246d2ec): no gattBudget= on its bt state line")
    return {"gattBudget": f"{budget.group(1)}/{budget.group(2)}", **(_gatt_counts(lines[-1]) or {})}


def _cycle_link(peer: Peer, phone: Phone, phone_id: str, timeout: float) -> dict:
    """Takes the link down and lets the phone dial it again, so the run sees a fresh promotion and dial: the peer
    refuses the phone, which closes the link, then once it is down and the connection has had time to go, allows it."""
    since = time.monotonic()
    peer.command(cmd="deny-link", peer=phone_id)
    try:
        peer.wait(lambda line: line.get("event") == "link" and line.get("peer") == phone_id and not line.get("up") and line["_at"] > since, 60)
    finally:
        time.sleep(5)
        peer.command(cmd="allow-link", peer=phone_id)
    link = _link_after(peer, phone, phone_id, time.monotonic(), timeout)
    return {"relinkSeconds": link["seconds"]}


def android_strangers(arguments: argparse.Namespace) -> int:
    """knit-next #154's device trial (knit-ios #3): a phone's GATT payload reads stay within their budget beside a
    device that rotates its address under `0xFE30`, and its dials never wait behind them.

    `knit-peer stranger` runs on dongle B with LE privacy on and an RPA timeout of `--rotate` seconds (`_rpa_timeout`),
    so B advertises from a new resolvable private address the phone cannot resolve that often: a new device each time,
    as an iPhone looks after each rotation. `--variant none` serves no payload, so each read finds a stranger. `--variant forged` serves a valid
    payload naming the highest node id there is, which the phone never dials, so no HELLO ever refunds it. Either way
    it hangs up on any dialer before a HELLO. A knit-peer in the `android` profile on dongle A sorts below the phone, so
    the phone dials it; every `--cycle` seconds it refuses the phone and then allows it, for a fresh promotion and dial.
    A phone with links and nothing to dial scans at its floor and seldom hears the stranger, so the phone is woken every
    minute, and the other Android phones `--quiet` names pause their meshes for the run.

    The phone's transport log is streamed for the whole run (`.build/interop-strangers-logcat.txt`) and graded at the
    end. `reads-within-budget`: every read that ended, less those a link confirmed, at most 12 in any 10 minutes.
    `budget-spent-logged`: `bt gatt budget spent` at least once, since the stranger offers far more than 12 addresses.
    `dials-not-starved`: no dial of the peer more than 12 s, one read, after its first `promote=`. `stranger-rotated`:
    the phone read more than 12 addresses, so the budget, not the per-address waits, did the bounding. The summary also
    reports reads begun per minute, `scan paused: connect in flight` lines, and the `gattBudget=` the `bt state` lines
    showed. Privacy goes off again at the end, whatever happened, since the dongles are shared with knit-next's lab."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    if run.step("phone-build-budgets-gatt", lambda: _budgets_gatt_reads(phone)) is None:
        print(json.dumps({"summary": "android-strangers", "steps": run.steps, "failed": run.failed}))
        return run.failed
    # Other phones' links keep this one at its floor scan, where it seldom hears the stranger: they pause for the run.
    quiet = [Phone(serial) for serial in arguments.quiet]
    for other in quiet:
        run.step(f"paused-{other.serial}", lambda other=other: _paused(other, True))
    try:
        return _strangers_run(arguments, phone, run, nonce, phone_id)
    finally:
        for other in quiet:
            run.step(f"resumed-{other.serial}", lambda other=other: _paused(other, False))


def _strangers_run(arguments: argparse.Namespace, phone: Phone, run: Run, nonce: str, phone_id: str) -> int:
    heard = in_range()
    # An iPhone the scan could not read is still no earlier run's peer: taken as heard, and refused.
    heard.update({node: {"capabilities": IOS_ADVERT_CAPABILITIES} for node in arguments.known.split(",") if node and node not in heard})
    others = set(heard) - {phone_id}
    if run.step("phone-forgot-old-peers", lambda: _phone_forgets_all_but(phone, set(heard))) is None:
        print(json.dumps({"summary": "android-strangers", "steps": run.steps, "failed": run.failed}))
        return run.failed
    peer_id = keygen(phone_id, "phone-dials", others)
    seconds = int(arguments.minutes * 60)
    header = {"run": "android-strangers", "variant": arguments.variant, "phone": phone_id, "peer": peer_id, "refused": sorted(others)}
    print(json.dumps({**header, "rotate": arguments.rotate, "minutes": arguments.minutes, "cycle": arguments.cycle}))
    if run.step("privacy-on-b", lambda: _privacy("b", True)) is None or run.step(
        "rpa-timeout-b", lambda: _rpa_timeout("b", arguments.rotate)
    ) is None:
        run.step("privacy-off-b", lambda: _privacy("b", False))
        print(json.dumps({"summary": "android-strangers", "steps": run.steps, "failed": run.failed}))
        return run.failed
    capture = LogcatCapture(phone, ROOT / ".build" / "interop-strangers-logcat.txt")
    # The stranger's own re-registration moves nothing on the dongles; the power cycles below rotate its address.
    stranger = Stranger(arguments.variant, 7200, seconds + 120, ROOT / ".build" / "interop-stranger.log")
    peer = Peer("android", f"knit-peer strangers {nonce}", others, arguments.peer_log, arguments.rssi_floor)
    stop = threading.Event()
    try:
        phone.shell("logcat -c")
        capture.start()
        started = time.monotonic()
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {phone_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        if run.step("link", lambda: _first_link(peer, phone, phone_id, started, arguments.link_timeout)) is not None:
            run.step("stranger-up", lambda: _start_stranger(stranger))
            end = time.monotonic() + seconds
            relink_at = time.monotonic() + arguments.cycle
            cycle = 0
            while (left := end - time.monotonic()) > 0:
                # Each minute the phone is woken, which nudges a scan: at its floor cadence, with links up, the Pixel 7
                # read 1 of 18 rotated addresses in six minutes on 2026-10-12, too few to reach the budget.
                stop.wait(min(60.0, left))
                phone.wake()
                if time.monotonic() >= relink_at and relink_at + arguments.cycle <= end:
                    cycle += 1
                    run.step(f"relink-{cycle}", lambda: _cycle_link(peer, phone, phone_id, arguments.link_timeout))
                    relink_at += arguments.cycle
    finally:
        stop.set()
        stranger.stop()
        peer.stop()
        capture.stop()
        run.step("privacy-off-b", lambda: _privacy("b", False))
    lines = capture.lines()
    charges = _charged_reads(lines)
    run.step("reads-within-budget", lambda: _within_budget(charges))
    run.step("budget-spent-logged", lambda: _budget_edges(lines))
    run.step("dials-not-starved", lambda: _not_starved(lines, peer_id))
    run.step("stranger-rotated", lambda: _rotated(charges, seconds // arguments.rotate))
    print(
        json.dumps(
            {
                "summary": "android-strangers",
                "steps": run.steps,
                "failed": run.failed,
                "lines": len(lines),
                "logcatRestarts": capture.restarts,
                "readsBegunPerMinute": _per_minute(lines, "bt gatt reading "),
                "scanPausedForConnect": sum(message.startswith("scan paused: connect in flight") for _, message in lines),
                "gattBudgetSeen": sorted({m.group(1) for _, message in lines if (m := re.search(r"gattBudget=(\d+/\d+)", message))}),
            }
        )
    )
    return run.failed


def _within_budget(charges: list[tuple[float, str]]) -> dict:
    most = _most_charged(charges)
    if most["most"] > GATT_BUDGET_READS:
        raise RuntimeError(f"{most['most']} charged reads in 10 minutes, over the budget of {GATT_BUDGET_READS}")
    return {"charged": len(charges), "mostInTenMinutes": most["most"]}


def _budget_edges(lines: list[tuple[float, str]]) -> dict:
    spent = sum(message.startswith("bt gatt budget spent") for _, message in lines)
    free = sum(message.startswith("bt gatt budget free") for _, message in lines)
    if not spent:
        raise RuntimeError("the phone never logged bt gatt budget spent: the stranger never spent its budget")
    return {"spent": spent, "free": free}


def _not_starved(lines: list[tuple[float, str]], node: str) -> dict:
    waits = _dial_waits(lines, node)
    if not waits["waits"]:
        raise RuntimeError("the phone never dialed the peer after promoting it")
    late = [wait for wait in waits["waits"] if wait > GATT_READ_TIMEOUT]
    if late or (waits["waiting"] or 0) > GATT_READ_TIMEOUT:
        raise RuntimeError(f"dials waited longer than one read ({GATT_READ_TIMEOUT:.0f} s): {late}, still waiting {waits['waiting']}")
    return {"dials": len(waits["waits"]), "longestWait": max(waits["waits"]), "waits": waits["waits"]}


def _start_stranger(stranger: Stranger) -> dict:
    stranger.start()
    # The adapter's address stays out of the run's output, which may be pasted into an issue (ADR 2026-10.ab6k).
    return {"command": shlex.join(stranger.command[1 : -len(hci0())])}


def _rotated(charges: list[tuple[float, str]], rotations: int) -> dict:
    addresses = {address for _, address in charges}
    if len(addresses) <= GATT_BUDGET_READS:
        raise RuntimeError(
            f"the phone read only {len(addresses)} addresses in about {rotations} rotations: "
            "the stranger's address did not change on the air, or the phone seldom heard it"
        )
    return {"addressesRead": len(addresses), "rotations": rotations}


def _per_minute(lines: list[tuple[float, str]], prefix: str) -> list[int]:
    """How many lines start with `prefix` in each minute of the log, from its first line."""
    if not lines:
        return []
    first = lines[0][0]
    counts = Counter(int((at - first) // 60) for at, message in lines if message.startswith(prefix))
    return [counts.get(minute, 0) for minute in range(int((lines[-1][0] - first) // 60) + 1)]


def iphone_forgets(arguments: argparse.Namespace) -> int:
    """The payload lifetime's forget rules on the iPhone's own radio, KnitBLE (ADR 2026-09.xzpt, amended 2026-09-29),
    each seen through Knit's log: `ble forgetting the GATT payload of <identifier>: its HELLO named <node>` or `: quiet
    for a minute of scanning`. knit-peer runs on hci1 in the `ios` profile, so the iPhone finds it by reading its GATT
    payload, and every peer there has the adapter's address: each new identity is a node taking a reused address. In
    order, so that no stage meets the
    open case (a payload above the iPhone at an address a peer below it keeps busy):

    1. **dialed:** a peer below the iPhone is read and dialed, then stops, and a new identity below it starts at once
        on the same PSM. The iPhone dials the old node there, the reply names the new one, and the payload goes.
    2. **quiet:** a peer above the iPhone is read, then stops, and nothing advertises there for over a minute of the
        iPhone's scanning. KnitBLE checks for quiet at each UUID-only advert, before that advert can be sighted with
        the payload, so the forget shows when the next peer there first advertises.
    3. **accepted:** a peer above the iPhone is read, then stops, and a new identity above it dials in. The iPhone keys
        an accepted link by its central's identifier and the payload by the peripheral's, so the payload goes only if
        CoreBluetooth gives hci1 the same identifier in both roles, which nothing had checked on hardware.

    Knit must be open on the iPhone, a debug build with the rules, and it stays open throughout. `--hci0` runs the peer
    on the maintainer's adapter, shared, which needs its own go-ahead. The iPhone reads and dials the peer here, and the
    ATS2851 now on hci1 takes neither, so run it with `--hci0` (`.agents/context/linux-peer.md`, "What the ATS2851
    showed")."""
    ios = IPhone(arguments.udid, arguments.host)
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
        adapter = hci0() if arguments.hci0 else None
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
            time.sleep(75)
            current = peer("iphone-below", "quiet-next", reads=False)
            current.command(cmd="deny-link", peer=ios.node_id)
            if read:
                run.step("quiet-forgets", lambda: _ios_forgot(log_path, read["identifier"], "quiet for a minute", arguments.link_timeout))
            current.stop()
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


def adapter_name(address: str) -> str:
    """The `hciN` the kernel gave the adapter with `address` this boot. An index is only the order the adapters' driver
    bound them in, which follows USB ports and replugs, so the scripts name adapters by address (ADR 2026-09.5ftc)."""
    listing = subprocess.run(["hcitool", "dev"], capture_output=True, text=True, check=False).stdout
    for line in listing.splitlines()[1:]:
        fields = line.split()
        if len(fields) == 2 and fields[1].upper() == address.upper():
            return fields[0]
    raise RuntimeError(f"no adapter has the address {address}")


def _hci1_idle_after(seconds: float) -> dict:
    """Waits `seconds`, then reports any connection hci1 still holds with no peer running, which only a phone's stray
    connect can have made."""
    time.sleep(seconds)
    listing = subprocess.run(["hcitool", "-i", adapter_name(hci1_address()), "con"], capture_output=True, text=True, check=False).stdout
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


def _phone_never_dialed(phone: Phone, peer_id: str, hci1: bool) -> dict:
    """The phone, below the peer, never dialed it but for knit-next #103's lonely dials, which are reported. The peer
    refuses a lonely phone it has sighted, and on hci1 none of them can connect: the ATS2851 takes no incoming LE
    connection."""
    dials = _phone_dials(_phone_lines(phone), peer_id)
    stray = [dial for dial in dials if not dial["lonely"]]
    if stray:
        raise RuntimeError(f"the phone dialed the peer with no lonely line first: {stray[:2]}")
    if not dials:
        return {}
    return {"outcome": "lonely dial", "lonelyDials": dials, **({"adapter": "hci1, which takes no incoming connection"} if hci1 else {})}


def _phone_dials(lines: list[str], node: str) -> list[dict]:
    """The phone's dials of `node` in its transport log, in order: whether a lonely line naming `node` came just before
    it (knit-next #103), and how it ended, `linked` at `bt connect ok`, the reason at `bt connect <id> failed`, or
    `open` while it has done neither."""
    dials: list[dict] = []
    lonely = False
    for line in lines:
        if line.startswith(LONELY_DIAL):
            lonely = node in line
        elif line.startswith("bt initiating to "):
            if line.startswith(f"bt initiating to {node} "):
                dials.append({"lonely": lonely, "outcome": "open"})
            lonely = False
        elif dials and dials[-1]["outcome"] == "open":
            if line.startswith(f"bt connect ok {node} "):
                dials[-1]["outcome"] = "linked"
            elif failed := re.match(rf"bt connect {node} failed reason=(\w+)", line):
                dials[-1]["outcome"] = failed.group(1)
    return dials


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
    return [line for line in _phone_lines(phone) if needle in line]


def _phone_lines(phone: Phone) -> list[str]:
    """The messages of every Bluetooth transport log line the phone holds, in order."""
    log = phone.shell("logcat -d -s BluetoothMeshTransport:*", timeout=60)
    return [line.split(": ", 1)[-1] for line in log.splitlines() if ": " in line]


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


# CONNECTION_PRIORITY_BALANCED's supervision timeout, which knit-next #102 asks for once the doorbell lookup finds the
# doorbell, and which every link the phone accepted must end at, whoever the central is.
BALANCED_TIMEOUT_MS = 5000
# The line the phone's doorbell client logs each time the link's parameters change (knit-next `BleDoorbell`).
CONN_PARAMS = re.compile(r"bt conn params (\S+) interval=(\d+)us latency=(\d+) timeout=(\d+)ms(?: status=(\d+))?")
# The fix's line when the doorbell client asks for BALANCED again: `bt doorbell priority <id> again (<why>)
# requested=<bool>`, `why` being `put-back <ms>ms` from the callback or `settle` from the timer.
PRIORITY_AGAIN = re.compile(r"bt doorbell priority (\S+) again \((.*)\) requested=(\w+)")


def _conn_params(phone: Phone, node: str) -> list[dict]:
    """The phone's links with `node` since its log was last cleared, each opened by its `bt accepted client` line, or by
    `bt connect ok` for one the phone dialed: when its doorbell lookup found the doorbell, which is when the phone asks
    for BALANCED, every `bt conn params` line logged for it, how many of those came before the find, and each time the
    fix asked for BALANCED again. Lines before the first open belong to a link already up, and open a link whose
    `openedAt` is None."""
    log = phone.shell("logcat -d -v time -s BluetoothMeshTransport:*", timeout=60)
    links: list[dict] = []

    def opened(at: str | None, accepted: bool | None) -> dict:
        return {
            "openedAt": at,
            "accepted": accepted,
            "acceptedAt": at if accepted else None,
            "foundAt": None,
            "beforeFound": 0,
            "params": [],
            "again": [],
            "events": [],
            "downAt": None,
        }

    def current() -> dict:
        if not links:
            links.append(opened(None, None))
        return links[-1]

    for line in log.splitlines():
        message = line.split(": ", 1)[-1]
        # `-v time` opens each line with "MM-DD HH:MM:SS.mmm".
        at = line[6:18]
        if message.startswith(f"bt accepted client {node} "):
            links.append(opened(at, True))
        elif message.startswith(f"bt connect ok {node}"):
            links.append(opened(at, False))
        elif message.startswith(f"bt doorbell found {node} "):
            link = current()
            link["foundAt"] = at
            link["beforeFound"] = len(link["params"])
        elif (again := PRIORITY_AGAIN.search(message)) and again.group(1) == node:
            current()["again"].append({"at": at, "why": again.group(2), "requested": again.group(3) == "true"})
            current()["events"].append({"at": at, "again": again.group(2)})
        elif f"link down: {node}" in message and links:
            links[-1]["downAt"] = at
        elif (params := CONN_PARAMS.match(message)) and params.group(1) == node:
            interval, latency, timeout = (int(value) for value in params.group(2, 3, 4))
            status = int(params.group(5) or 0)
            current()["params"].append({"at": at, "intervalUs": interval, "latency": latency, "timeoutMs": timeout, "status": status})
            current()["events"].append({"at": at, "params": timeout, "status": status})
    return links


def _balanced(phone: Phone, node: str, tally: list[dict], fresh: bool = True, head_start: bool = False) -> dict:
    """knit-next #102: every link the phone accepted from `node` since its log was cleared, whose doorbell lookup found
    the doorbell, ends at BALANCED's 5 s supervision timeout. The last `bt conn params` line the link logs after
    `bt doorbell found`, for as long as it lives, must say `timeout=5000ms`: a central's first values put back after
    the ask, 720 ms from an iPhone or 420 ms from BlueZ, fail it, and so does a link with no line after the find. A
    link whose lookup never found the doorbell never asked for BALANCED, so it is reported, and neither passes nor
    fails nor counts toward `--links`. Each link goes into `tally`, for the run's summary. With `fresh`, a link must
    have come up since the clear; without, one already up when the log was cleared, which left no lines, passes
    unseen.

    With `head_start`, the iPhone sorts below the phone, so a link the phone accepted is a head-start dial (interop-audit
    finding AND-2), and one whose lookup found no doorbell fails: only that lookup asks for 5 s. A link the phone
    dialed fails too if its last timeout is under 5 s."""
    links = _conn_params(phone, node)
    if fresh:
        links = [link for link in links if link["openedAt"]]
    if not links and fresh:
        # A network adb link sometimes reads back an empty log; read it once more before failing.
        time.sleep(3)
        links = [link for link in _conn_params(phone, node) if link["openedAt"]]
    if not links:
        if fresh:
            raise RuntimeError(f"the phone accepted no link from {node} since its log was cleared")
        return {"links": [], "predatesTheLog": True}
    report = []
    for link in links:
        after = link["params"][link["beforeFound"] :] if link["foundAt"] else []
        report.append(
            {
                "acceptedAt": link["acceptedAt"],
                "accepted": link["accepted"],
                "doorbellFound": link["foundAt"] is not None,
                "foundAt": link["foundAt"],
                "timeouts": [params["timeoutMs"] for params in link["params"]],
                "updatesAfterFound": len(after),
                "last": after[-1] if after else None,
                "lastAny": link["params"][-1] if link["params"] else None,
                "again": link["again"],
                "failedUpdates": _failed_updates(link["events"]),
                "downAt": link["downAt"],
            }
        )
    tally.extend(report)
    found = [link for link in report if link["doorbellFound"]]
    short = [link for link in found if link["last"] is None or link["last"]["timeoutMs"] < BALANCED_TIMEOUT_MS]
    if head_start:
        unfound = [link for link in report if not link["doorbellFound"]]
        short += [link for link in unfound if link["lastAny"] and link["lastAny"]["timeoutMs"] < BALANCED_TIMEOUT_MS]
        silent = [link for link in unfound if link["accepted"]]
        if silent:
            raise RuntimeError(f"{len(silent)} head-start links found no doorbell: {json.dumps(report)}")
    if short:
        raise RuntimeError(f"{len(short)} of {len(report)} links did not end at {BALANCED_TIMEOUT_MS} ms: {json.dumps(report)}")
    counted = sum(1 for link in found if link["accepted"] is not False)
    return {"links": report, "counted": counted, "noDoorbell": len(report) - len(found)}


def _failed_updates(events: list[dict]) -> list[dict]:
    """Each `bt conn params` report with a status other than 0, a parameter update that failed, with the parameter
    reports and re-asks that followed it up to the next successful report, which show what the fix did about it."""
    failed = []
    for index, event in enumerate(events):
        if event.get("status"):
            after = []
            for later in events[index + 1 :]:
                after.append(later)
                if "params" in later and not later["status"]:
                    break
            failed.append({"at": event["at"], "timeoutMs": event["params"], "status": event["status"], "then": after})
    return failed


def _counted(tally: list[dict]) -> int:
    """The links in `tally` that count toward `--links`: those the phone took from the central, whose lookup found the
    doorbell."""
    return sum(1 for link in tally if link["doorbellFound"] and link["accepted"] is not False)


def _relinks(run: Run, central: Node, phone: Phone, phone_id: str, want: int, hold: float, timeout: float, tally: list[dict]) -> None:
    """More link-ups with the phone, each dialed by `central` (knit-peer or the iPhone) and checked by `_balanced`,
    until `want` links whose lookup found the doorbell are in `tally`, or twice that many link-ups have come. Each
    time the central refuses the phone, which closes the link, and once the phone has logged it down and the
    connection has had time to go, lets it link again. Each link must hold for `hold` seconds, and the first that
    fails ends the loop."""
    node = central.node_id
    attempt = 1
    while _counted(tally) < want and attempt < 2 * want:
        attempt += 1
        label = f"relink-{attempt}"
        phone.shell("logcat -c")
        central.command(cmd="deny-link", peer=phone_id)
        down = run.step(f"{label}-down", lambda: {"lines": len(poll(lambda: _phone_log(phone, f"link down: {node}"), 60, every=2))})
        if down is None:
            central.command(cmd="allow-link", peer=phone_id)
            return
        # The central closes the connection a moment after the channel, and the next link must be a new one.
        time.sleep(5)
        phone.shell("logcat -c")
        since = time.monotonic()
        central.command(cmd="allow-link", peer=phone_id)
        link = run.step(label, lambda since=since: _link_after(central, phone, phone_id, since, timeout))
        if link is None:
            return
        time.sleep(max(0.0, link["at"] + hold - time.monotonic()))
        # The first link that fails stops the run, so its logs are fresh when someone looks.
        if run.step(f"{label}-balanced", lambda: {**_balanced(phone, node, tally), **_phone_held(phone, node), "heldSeconds": hold}) is None:
            return
    if _counted(tally) < want:
        run.step("links-counted", lambda: _fail(f"{_counted(tally)} of {want} links found the doorbell in {attempt} link-ups"))


def _link_after(central: Node, phone: Phone, phone_id: str, since: float, timeout: float) -> dict:
    """The central's first link to the phone after `since`, keeping the phone awake meanwhile."""
    deadline = since + timeout
    while True:
        phone.wake()
        try:
            line = central.wait(lambda line: _link(line, phone_id) and line["_at"] > since, 20)
            return {"seconds": round(line["_at"] - since, 1), "at": line["_at"]}
        except TimeoutError:
            if time.monotonic() > deadline:
                raise


def _head_start_relinks(
    run: Run, ios: IPhone, phone: Phone, phone_id: str, arguments: argparse.Namespace, tally: list[dict], head_starts: list[dict], knit
) -> None:
    """With the iPhone below the phone, more link-ups until `--links` head-start links have found the doorbell, or twice
    that many link-ups have come. Each time the iPhone's mesh stops for `--away` seconds, long enough for the phone's
    sighting of it to linger out (90 s, `BlePresenceTracker.kt:274`), then starts, and the first link from there is
    timed, as MVP item 2 times it. Whoever dialed, the link must hold `--hold` seconds and pass `_balanced`. Each link
    goes into `head_starts`: its time, its dialer, and whether the iPhone logged its head-start line."""
    want = arguments.links

    def counted() -> int:
        # `--count any` counts every link-up that passed, whoever dialed, as an open phone's run does.
        return len(head_starts) if arguments.count == "any" else _counted(tally)

    attempt = 0
    while counted() < want and attempt < 2 * want:
        attempt += 1
        label = f"head-start-{attempt}"
        ios.command(cmd="stop")
        time.sleep(arguments.away)
        phone.shell("logcat -c")
        started, wall = time.monotonic(), time.time()
        ios.command(cmd="start")
        link = run.step(label, lambda started=started: _relinked(ios, phone, phone_id, started, 180))
        if link is None:
            return
        time.sleep(max(0.0, started + link["seconds"] + arguments.hold - time.monotonic()))
        dialer = _last_dialer(phone, ios.node_id)
        line = _head_start_line(knit, phone_id, wall)
        entry = {"seconds": link["seconds"], "withinThirtySeconds": link["withinThirtySeconds"], "dialer": dialer, "line": line}
        head_starts.append(entry)

        def checked(entry: dict = entry) -> dict:
            report = _balanced(phone, ios.node_id, tally, head_start=True)
            entry["lastTimeoutMs"] = [link["lastAny"]["timeoutMs"] if link["lastAny"] else None for link in report["links"]]
            if entry["dialer"] == "iphone" and knit and not entry["line"]:
                raise RuntimeError("the iPhone dialed with no head-start line in its log")
            return {**report, **_phone_held(phone, ios.node_id), **entry}

        # The first link that fails stops the run, so its logs are fresh when someone looks.
        if run.step(f"{label}-balanced", checked) is None:
            return
    if counted() < want:
        run.step("links-counted", lambda: _fail(f"{counted()} of {want} links counted ({arguments.count}) in {attempt} link-ups"))


def _last_dialer(phone: Phone, node: str) -> str | None:
    """Who dialed the phone's last link with `node` since its log was cleared: "iphone" for `bt accepted client`,
    "phone" for `bt connect ok`."""
    ends = [line for line in _phone_lines(phone) if line.startswith((f"bt connect ok {node}", f"bt accepted client {node} "))]
    if not ends:
        return None
    return "phone" if ends[-1].startswith("bt connect ok") else "iphone"


# The line the iPhone's link manager logs before each head-start dial (`LinkManager+HeadStart.swift`).
HEAD_START_LINE = "link head start over for "


def _iphone_log(ios: IPhone, name: str):
    """Knit's own log over USB, for the head-start line, or None when the iPhone is not on USB."""
    try:
        return IPhoneLog(ios.udid, ROOT / ".build" / name)
    except (RuntimeError, OSError):
        return None


def _head_start_line(knit, peer: str, since: float) -> str | None:
    """The iPhone's head-start line for `peer` logged since `since`, on the wall clock, if its log is being read."""
    if knit is None:
        return None
    knit.file.flush()
    for entry in IPhoneLog.entries(knit.path):
        if f"{HEAD_START_LINE}{peer}" in entry["message"] and entry.get("ms", 0) / 1000 >= since - 1:
            return entry["message"]
    return None


def _last_timeouts(tally: list[dict]) -> list[dict]:
    """Each link's last supervision timeout after its doorbell was found, in ms, for a run's summary line, with why
    the phone asked for BALANCED again on it, which shows whether the callback or the settle timer put it right."""
    return [
        {
            "accepted": link["accepted"],
            "doorbellFound": link["doorbellFound"],
            "lastTimeoutMs": link["last"]["timeoutMs"] if link["last"] else None,
            "again": [again["why"] for again in link["again"]],
            "failedUpdates": [f"{failed['timeoutMs']}ms status={failed['status']}" for failed in link["failedUpdates"]],
        }
        for link in tally
    ]


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
    ios = IPhone(arguments.udid, arguments.host)
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
    data = Peer("android", f"knit-peer scan data {nonce}", others | {ios.node_id}, arguments.peer_log, None, "scan-data", hci0())
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


def iphone_seek(arguments: argparse.Namespace) -> int:
    """ADR 2026-10.mueg: a locked iPhone with no link seeks peers, with a scan for the 0xFE30 UUID that resumes Knit at
    each match, and spends at most eight wakes a spell. Someone locks the iPhone and later unlocks it. The iPhone refuses
    every node in range but the far side: knit-peer on an adapter, or the Android phone.

    `--mode drop` asks the question under the rest: does a suspended Knit hear a link drop at all? The far side drops
    the link, its process killed or (`--drop radio-off`) hci1 powered off, and the run reads Knit's log for its
    `link down` and counts runningboardd's lines on Knit. Knit hears a link it dialed end through a CoreBluetooth
    delegate, which resumes it, and a link the far side dialed may end unheard. hci1 dials the iPhone (an `ios` peer
    above it), hci0 is dialed by it (an `android` peer), and the phone follows its build and the ids. `--mode relink`
    restarts the far side on the same identity, as reinstalling Knit does: Knit must find it and link while still locked,
    then take a DM the far side rings for. `--mode budget` locks the iPhone with no link beside a far side it cannot
    link, one that refuses it on hci0 or one it cannot dial on hci1, and the wakes it spends must stop at the budget.
    Steps that measure rather than check are findings, and never fail."""
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    try:
        ios.start()
    except TimeoutError:
        print(json.dumps({"action": "open Knit"}), flush=True)
        _reopened(ios, arguments.lock_wait)
    others = others_in_range(ios.node_id) - {ios.node_id}
    far = _SeekPhone(arguments, ios) if arguments.far == "phone" else _SeekPeer(arguments, ios, others, nonce)
    refused = sorted(others - {far.node_id})
    for node in refused:
        ios.command(cmd="deny-link", peer=node)
    out = ROOT / ".build" / "iphone-seek"
    out.mkdir(parents=True, exist_ok=True)
    knit = IPhoneLog(ios.udid, out / f"knit-{nonce}.log")
    board = RunningBoardLog(ios.udid, out / f"runningboard-{nonce}.log")
    before = ios.command(cmd="status")
    header = {"run": "iphone-seek", "mode": arguments.mode, "far": arguments.far, "drop": arguments.drop, "iphone": ios.node_id}
    print(json.dumps({**header, "farSide": far.node_id, "refused": refused, "logs": str(out)}), flush=True)
    try:
        if arguments.mode != "budget":
            run.step("link", far.link)
        try:
            print(json.dumps({"action": "lock the iPhone"}), flush=True)
            run.step("iphone-suspended", lambda: _suspended(ios, arguments.lock_wait))
        finally:
            ios.stop()
        dropped = time.time()
        mark = board.mark()
        if arguments.mode == "budget":
            time.sleep(60 * arguments.minutes)
        else:
            if arguments.mode == "relink":
                far.restart()
            else:
                far.drop(arguments.drop)
            run.step("knit-heard-the-drop", lambda: _knit_heard(knit, f"link down {far.node_id}", dropped, 60))
            if arguments.mode == "relink":
                run.step(
                    "relinked-while-locked",
                    lambda: {**far.relinked(arguments.relink_wait), "afterDrop": round(time.time() - dropped, 1)},
                )
                run.step("dm-delivered-while-locked", lambda: far.dm_delivered(f"interop seek {nonce}", 90))
        run.step("seeking", lambda: _seeking(knit, dropped))
        run.step("knit-resumed", lambda: board.resumes(mark))
        print(json.dumps({"action": "unlock the iPhone and open Knit"}), flush=True)
        opened = run.step("knit-opened", lambda: _reopened(ios, arguments.unlock_wait))
        if opened is not None:
            after = ios.command(cmd="status")
            run.step("counters", lambda: _seek_counters(arguments.mode, before, after))
    finally:
        far.stop()
        knit.stop()
        board.stop()
        if ios.socket:
            for node in refused:
                ios.command(cmd="allow-link", peer=node)
        ios.stop()
    print(json.dumps({"summary": "iphone-seek", "steps": run.steps, "failed": run.failed}))
    return run.failed


class _SeekPeer:
    """knit-peer as the far side of `iphone-seek`. On hci1, the ATS2851, which takes no incoming LE connection, it runs
    the `ios` profile above the iPhone and dials it, so the iPhone holds the link as a peripheral; in `--mode budget` it
    runs the `android` profile instead, which the iPhone dials and never reaches. On hci0, shared, it runs the `android`
    profile, which the iPhone dials; in `--mode budget` it refuses the iPhone."""

    def __init__(self, arguments: argparse.Namespace, ios: IPhone, others: set[str], nonce: str) -> None:
        if arguments.far == "hci1" and arguments.mode == "relink":
            sys.exit("the iPhone cannot dial hci1, so it cannot relink there: use --far hci0 or --far phone")
        if arguments.far == "hci0" and arguments.drop == "radio-off":
            sys.exit("--drop radio-off powers off hci1 alone: hci0 is the maintainer's, and keeps its power")
        profile = "ios" if arguments.far == "hci1" and arguments.mode == "drop" else "android"
        instance = f"iphone-seek-{arguments.far}"
        self.ios_id = ios.node_id
        # An `ios` peer dials the iPhone, so it sorts above it; the iPhone dials an `android` one whatever the order.
        self.node_id = _keygen(instance, "--above", max(others | {ios.node_id}))
        refuse = set(others) | ({ios.node_id} if arguments.mode == "budget" and arguments.far == "hci0" else set())
        adapter = hci0() if arguments.far == "hci0" else []
        self.peer = Peer(profile, f"knit-peer seek {nonce}", refuse, arguments.peer_log, arguments.rssi_floor, instance, adapter)
        self.peer.start()
        self.powered_off = False

    def link(self) -> dict:
        return _timed(lambda: self.peer.lines(lambda line: _link(line, self.ios_id)), 180)

    def drop(self, how: str) -> None:
        if how == "radio-off":
            _ats2851_power(on=False)
            self.powered_off = True
            self.peer.wait(lambda line: line.get("event") == "radio" and line.get("state") == "off", 15)
        else:
            self.kill()

    def kill(self) -> None:
        """Ends knit-peer at once, as a crash or an uninstall does: no quit, so nothing closes the link first."""
        if self.peer.process and self.peer.process.poll() is None:
            self.peer.process.kill()
            self.peer.process.wait(timeout=10)
        self.peer.process = None
        with self.peer.arrived:
            self.peer.seen.clear()

    def restart(self) -> None:
        """Ends knit-peer at once and starts it again on the same identity, as reinstalling Knit on a phone does."""
        self.kill()
        time.sleep(5)
        self.peer.start()

    def relinked(self, timeout: float) -> dict:
        return _timed(lambda: self.peer.lines(lambda line: _link(line, self.ios_id)), timeout)

    def dm_delivered(self, body: str, timeout: float) -> dict:
        frame = self.peer.command(cmd="dm", to=self.ios_id, text=body)["id"]
        return _timed(lambda: self.peer.lines(lambda line: line.get("event") == "delivered" and line.get("id") == frame), timeout)

    def stop(self) -> None:
        if self.powered_off:
            _ats2851_power(on=True)
        self.peer.stop()


def _ats2851_power(on: bool) -> None:
    """Powers the ATS2851 on or off through BlueZ, found by its address. Not through knit-hci: it finds the adapter in
    `hcitool dev`, which lists only adapters that are up, so it cannot power one back on."""
    wanted = f's "{hci1_address()}"'
    for index in range(8):
        path = f"/org/bluez/hci{index}"
        address = subprocess.run(
            ["busctl", "get-property", "org.bluez", path, "org.bluez.Adapter1", "Address"], capture_output=True, text=True, check=False
        ).stdout.strip()
        if address == wanted:
            power = ["busctl", "set-property", "org.bluez", path, "org.bluez.Adapter1", "Powered", "b", "true" if on else "false"]
            subprocess.run(power, check=True)
            return
    raise RuntimeError(f"BlueZ has no adapter at {hci1_address()}")


class _SeekPhone:
    """The Android phone as the far side of `iphone-seek`, through knit-next's debug bridge. Whether it dials the
    iPhone or the iPhone dials it follows from their ids and its build, since A3 reads the iPhone's payload. `drop`
    force-stops Knit, as reinstalling it does, and `restart` opens it again."""

    def __init__(self, arguments: argparse.Namespace, ios: IPhone) -> None:
        if arguments.mode == "budget":
            sys.exit("--mode budget needs a far side the iPhone cannot link: use --far hci1 or --far hci0")
        if arguments.drop == "radio-off":
            sys.exit("--drop radio-off powers off hci1 alone: use --far hci1")
        self.phone = Phone(arguments.device)
        self.ios_id = ios.node_id
        self.node_id = self.phone.state()["self"]["nodeId"]
        self.stopped = False

    def link(self) -> dict:
        return _timed(self._linked, 180)

    def _linked(self) -> bool:
        try:
            reachable = self.phone.state().get("reachable", [])
        except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError):
            return False
        return any(peer["nodeId"] == self.ios_id for peer in reachable)

    def drop(self, _how: str) -> None:
        self.phone.shell(f"am force-stop {PACKAGE}")
        self.stopped = True

    def restart(self) -> None:
        self.drop("kill")
        time.sleep(5)
        self.phone.shell(f"am start -n {PACKAGE}/.MainActivity")
        self.stopped = False

    def relinked(self, timeout: float) -> dict:
        return _timed(self._linked, timeout)

    def dm_delivered(self, body: str, timeout: float) -> dict:
        self.phone.wake()
        self.phone.send(body, conversation=self.ios_id)

        def ticked() -> bool:
            try:
                messages = self.phone.state(self.ios_id, limit=20).get("messages", [])
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError):
                return False
            return any(message["body"] == body and message.get("received") for message in messages)

        return _timed(ticked, timeout)

    def stop(self) -> None:
        if self.stopped:
            self.phone.shell(f"am start -n {PACKAGE}/.MainActivity")


class RunningBoardLog:
    """runningboardd's lines about Knit from the iPhone's unified log, kept as they come. bluetoothd takes an assertion on
    Knit to deliver it each Bluetooth event, a ring, a disconnect or a scan's match, and runningboardd resumes it for
    about 10 s (`.agents/context/linux-peer.md`, P8's scan-filter check). The raw lines stay in the file, since the
    wording varies across iOS releases."""

    def __init__(self, udid: str, path: Path) -> None:
        self.path = path
        self.file = open(path, "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(
            # Line-buffered: runningboardd says little, and a block-buffered file would hold a run's lines past its end.
            ["stdbuf", "-oL", "idevicesyslog", "-u", udid, "-p", "runningboardd", "-m", "getknit", "--no-colors"],
            stdout=self.file,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )

    def mark(self) -> int:
        """Where the file ends now, for `resumes`."""
        self.file.flush()
        return self.path.stat().st_size

    def resumes(self, mark: int) -> dict:
        """A finding: since `mark`, the assertions bluetoothd took on Knit, each a resume for a Bluetooth event, when
        they came, and how long Knit ran in all before runningboardd suspended it again."""
        self.file.flush()
        with open(self.path, encoding="utf-8", errors="replace") as log:
            log.seek(mark)
            lines = log.read().splitlines()
        woken = [line.split()[2] for line in lines if "Acquiring assertion" in line and "com.apple.bluetoothd" in line]
        changes = [(line.split()[2], "Resuming task" in line) for line in lines if "Resuming task" in line or "Suspending task" in line]
        running, started = 0, None
        for at, resumed in changes:
            seconds = _clock_seconds(at)
            if resumed and started is None:
                started = seconds
            elif not resumed and started is not None:
                running += (seconds - started) % 86400
                started = None
        return {"bluetoothdAssertions": len(woken), "at": woken[:20], "secondsRunning": running}

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.file.close()


def _clock_seconds(at: str) -> int:
    """Seconds into the day of a syslog `HH:MM:SS`."""
    hours, minutes, seconds = (int(part) for part in at.split(":"))
    return hours * 3600 + minutes * 60 + seconds


def _knit_heard(knit: IPhoneLog, needle: str, since: float, timeout: float) -> dict:
    """A finding: whether Knit logged `needle` within `timeout` of `since`, the iPhone locked all the while, and when."""
    deadline = time.monotonic() + timeout
    while True:
        knit.file.flush()
        for entry in IPhoneLog.entries(knit.path):
            if needle in entry["message"] and entry.get("ms", 0) / 1000 >= since - 1:
                return {"heard": True, "after": round(entry["ms"] / 1000 - since, 1)}
        if time.monotonic() > deadline:
            return {"heard": False}
        time.sleep(2)


def _seeking(knit: IPhoneLog, since: float) -> dict:
    """A finding: what Knit's link manager said of seeking since `since`, and how many wakes it counted."""
    knit.file.flush()
    prefixes = ("link seeking", "link seek wake", "link in the background", "link at the front")
    said = [
        entry["message"]
        for entry in IPhoneLog.entries(knit.path)
        if entry.get("ms", 0) / 1000 >= since - 1 and entry["message"].startswith(prefixes)
    ]
    return {"wakes": sum(1 for line in said if line.startswith("link seek wake")), "said": said[:40]}


def _seek_counters(mode: str, before: dict, after: dict, budget: int = 8) -> dict:
    """What Knit counted while locked, from its status before and after: it stopped seeking at the front, a relink held,
    and a budget run spent no more wakes than the budget."""
    detail = {
        "spells": after.get("seekSpells", 0) - before.get("seekSpells", 0),
        "wakes": after.get("seekWakes", 0) - before.get("seekWakes", 0),
        "seeking": after.get("seeking"),
        "links": after.get("links"),
    }
    if after.get("seeking"):
        raise RuntimeError(f"Knit is at the front and still seeking: {detail}")
    if mode == "relink" and after.get("links", 0) < 1:
        raise RuntimeError(f"the relink did not hold: {detail}")
    if mode == "budget" and detail["wakes"] > budget:
        raise RuntimeError(f"seeking spent more than its {budget} wakes: {detail}")
    return detail


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
    ios = IPhone(arguments.udid, arguments.host)
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
    Over USB, a connection open when Knit closes never hears it: iproxy keeps its end open."""
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
    ios = IPhone(arguments.udid, arguments.host)
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


def record_pull(arguments: argparse.Namespace) -> int:
    """Copies the bridge's last finished screen recording (ADR 2026-10.x2cq) to --out, a chunk at a time, checks its
    SHA-256 against the one `record-stop` reported, then deletes it on the phone unless --keep. Run `record-stop`
    first; asking it again only reads back the finished file."""
    ios = IPhone(arguments.udid, arguments.host)
    ios.start()
    try:
        take = ios.command(cmd="record-stop", timeout=120)
        if not take.get("ok"):
            raise RuntimeError(f"no recording to pull: {take.get('code')}: {take.get('error')}")
        started = time.monotonic()
        digest = hashlib.sha256()
        offset = 0
        with open(arguments.out, "wb") as out:
            while True:
                chunk = ios.command(cmd="record-fetch", offset=offset, length=arguments.chunk, timeout=60)
                if not chunk.get("ok"):
                    raise RuntimeError(f"record-fetch at {offset}: {chunk.get('code')}: {chunk.get('error')}")
                data = base64.b64decode(chunk["data"])
                out.write(data)
                digest.update(data)
                offset += len(data)
                if chunk["eof"]:
                    break
        seconds = time.monotonic() - started
        if offset != take["bytes"] or digest.hexdigest() != take["sha256"]:
            raise RuntimeError(f"{arguments.out} is {offset} bytes, sha256 {digest.hexdigest()}; the phone has {take['bytes']}, {take['sha256']}")
        if not arguments.keep:
            ios.command(cmd="record-delete")
        result = {key: take[key] for key in ("file", "bytes", "sha256", "startedAt", "durationMs", "endedBy")}
        print(json.dumps({**result, "out": arguments.out, "seconds": round(seconds, 1), "mbps": round(offset * 8 / seconds / 1e6, 1)}))
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
    refused = [line for line in _client_verdicts(phone, peer_id) if line["verdict"] == "refused" and line.get("sighted") is False]
    ages = [line["heldAgeMs"] for line in refused if isinstance(line.get("heldAgeMs"), int)]
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
            "files": status.get("files"),
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
    sample = {"t": elapsed, **{key: status.get(key) for key in ("links", "custody", "dropped", "files", "footprint", "router")}}
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
    b = Peer("android", f"knit-peer B {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "relay-b", hci0())
    a = Peer(arguments.radio_profile, f"knit-peer A {nonce}", others, arguments.peer_log, arguments.rssi_floor, "relay-a")
    b.start()
    a.start()
    stop = threading.Event()
    threading.Thread(target=_keep_to, args=(b, {a_id}, set(b.refuse), stop, b.instance), daemon=True).start()
    threading.Thread(target=_keep_to, args=(a, {phone_id, b_id}, set(a.refuse), stop, a.instance), daemon=True).start()
    try:
        if arguments.peer_avatar:
            jpeg = base64.b64encode(_unique_jpeg(arguments.peer_avatar, nonce)).decode()
            run.step("photo-set-b", lambda: {"avatarHash": b.command(cmd="avatar", jpeg=jpeg)["avatarHash"]})
        run.step("link-a-b", lambda: a.wait(lambda line: _link(line, b_id), 180) and b.wait(lambda line: _link(line, a_id), 10) and {})
        run.step("link-a-phone", lambda: link_up(a, phone, phone_id) and {})
        run.step("phone-profile-reaches-b", lambda: {"name": b.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 240)["displayName"]})
        # B never links the phone, so it asks A for the photo the phone's profile names. A serves the copy the phone
        # pushed it, or fetches one first and serves B's next ask, a minute on (ADR 2026-10.ym9y).
        if arguments.expect_avatar:
            run.step("photo-pulled-to-b", lambda: poll(lambda: _photo(b, phone_id), 240))
        # The phone asks A for B's photo the same way. A has no photo of its own, so its count of files out whole is
        # its serves; Android's bridge does not say which photo it shows, and the phone's screen is the rest.
        if arguments.peer_avatar:
            run.step("photo-served-by-a", lambda: poll(lambda: _files_sent(a), 240))
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
    sorts above every phone in range, so no phone dials it. It runs on hci0 because the ATS2851 on hci1 takes no
    incoming LE connection (.agents/context/linux-peer.md, "What the ATS2851 showed")."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id) - {ios.node_id}
    peer_id = _keygen("iphone-relay", "--above", max(others | {phone_id}))
    print(json.dumps({"run": "iphone-relay", "phone": phone_id, "iphone": ios.node_id, "peer": peer_id, "refused": sorted(others)}))
    status = ios.command(cmd="status")
    before, sent_before = status["router"], status["files"]["sent"]
    stop = threading.Event()
    kept_off: set[str] = set()
    threading.Thread(target=_keep_to, args=(ios, {phone_id, peer_id}, kept_off, stop, "iphone"), daemon=True).start()
    peer = Peer(
        arguments.radio_profile, f"knit-peer relay {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "iphone-relay", hci0()
    )
    peer_photo = ""
    try:
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        if arguments.peer_avatar:
            jpeg = _unique_jpeg(arguments.peer_avatar, nonce)
            peer_photo = hashlib.sha256(jpeg).hexdigest()
            run.step("photo-set", lambda: {"avatarHash": peer.command(cmd="avatar", jpeg=base64.b64encode(jpeg).decode())["avatarHash"]})
        run.step("link-iphone-phone", lambda: _ios_linked(ios, phone, phone_id))
        run.step("link-iphone-peer", lambda: _timed(lambda: peer.lines(lambda line: _link(line, ios.node_id)), 180))
        run.step(
            "phone-profile-reaches-peer",
            lambda: {"name": peer.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 240)["displayName"]},
        )
        # The phone and the iPhone back-fill the newcomer, and new frames queue behind that, as in `relay`.
        run.step("custody-iphone-phone", lambda: _converges(ios, phone, 900))
        run.step("custody-peer-iphone", lambda: _peers_converge(peer, ios, 300))
        # Neither end links the other, and the iPhone refuses every other node, so a photo crosses only as the
        # iPhone's serve: each end wants the other's photo and asks its neighbours, and the iPhone holds the copy
        # the photo's owner pushed it (ADR 2026-10.ym9y). Android pulls only a photo whose owner it does not link.
        if arguments.expect_avatar:
            run.step("phone-photo-pulled-to-peer", lambda: poll(lambda: _photo(peer, phone_id), 240))
        if arguments.peer_avatar:
            run.step("peer-photo-served-to-phone", lambda: poll(lambda: _phone_got_file(phone, peer_photo, ios.node_id), 240))
        if arguments.expect_avatar or arguments.peer_avatar:
            run.step("iphone-served", lambda: _ios_served(ios, sent_before))
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


def iphone_group(arguments: argparse.Namespace) -> int:
    """v1 groups between the iPhone and an Android phone, with knit-peer on hci0 as a third member (ADR 2026-09.n393).
    The line is `iphone-relay`'s: the phone, then the iPhone, then the peer, which refuses the phone, so whatever the
    phone and the peer say to each other in a group crossed the iPhone. `_group_walk` has the steps.

    The peer runs the `android` profile and sorts above every phone in range, so the iPhone dials it and no phone
    does. It runs on hci0 because the ATS2851 on hci1 takes no incoming LE connection."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    stop = threading.Event()
    kept_off: set[str] = set()
    peer: Peer | None = None
    ios.start()
    try:
        phone_id = phone.state()["self"]["nodeId"]
        others = others_in_range(phone_id) - {ios.node_id}
        peer_id = _keygen("iphone-group", "--above", max(others | {phone_id}))
        ghost = _ghost("iphone-group-ghost")
        known = _knows(ios, phone_id)
        print(
            json.dumps(
                {
                    "run": "iphone-group",
                    "phone": phone_id,
                    "iphone": ios.node_id,
                    "peer": peer_id,
                    "ghost": ghost,
                    "phoneKnown": known,
                    "refused": sorted(others),
                }
            )
        )
        threading.Thread(target=_keep_to, args=(ios, {phone_id, peer_id}, kept_off, stop, "iphone"), daemon=True).start()
        peer = Peer(
            "android", f"knit-peer group {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "iphone-group", hci0()
        )
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("link-iphone-phone", lambda: _ios_linked(ios, phone, phone_id))
        run.step("link-iphone-peer", lambda: _timed(lambda: peer.lines(lambda line: _link(line, ios.node_id)), 180))
        _keys_cross(run, phone, phone_id, peer)
        run.step("custody-iphone-phone", lambda: _converges(ios, phone, 900))
        run.step("custody-peer-iphone", lambda: _peers_converge(peer, ios, 300, frozenset()))
        # The iPhone's view of the phone decides whether the phone's group is a request there; a False may be an Accept
        # the control lines cannot show, so it takes either answer and reports which.
        trio = _group_walk(run, ios, phone, phone_id, peer, ghost, nonce, False if known else None)
        run.step("custody-iphone-phone-again", lambda: _converges(ios, phone, 300, frozenset({trio})))
        run.step("custody-peer-iphone-again", lambda: _peers_converge(peer, ios, 300, frozenset()))
        run.step("peer-linked-only-the-iphone", lambda: _linked_only(peer, {ios.node_id}))
    finally:
        stop.set()
        if peer:
            peer.stop()
        for node in sorted(kept_off):
            try:
                ios.command(cmd="allow-link", peer=node)
            except (TimeoutError, OSError):
                pass
        ios.stop()
    print(json.dumps({"summary": "iphone-group", "steps": run.steps, "failed": run.failed, "keptOff": len(kept_off)}))
    return run.failed


def group(arguments: argparse.Namespace) -> int:
    """v1 groups between knit-peer and an Android phone (ADR 2026-09.n393), with the phone in the middle: peer A on
    hci0, shared, and peer B on hci1 each link the phone and refuse each other, so whatever A and B say to each other
    in a group crossed the phone. A does what the iPhone does in `iphone-group`, and `_group_walk` has the steps. Both
    sort above every phone in range, so each dials the phone and no phone dials either. The phone needs a link free
    for each, and hci1 has to reach it: on 2026-09-30 the ATS2851 linked no Pixel 3 (.agents/context/linux-peer.md,
    "What the group runs showed")."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    top = max(others | {phone_id})
    a_id = _keygen("group-a", "--above", top)
    b_id = _keygen("group-b", "--above", top)
    ghost = _ghost("group-ghost")
    print(json.dumps({"run": "group", "phone": phone_id, "a": a_id, "b": b_id, "ghost": ghost, "refused": sorted(others)}))
    a = Peer(arguments.radio_profile, f"knit-peer A {nonce}", others | {b_id}, arguments.peer_log, arguments.rssi_floor, "group-a", hci0())
    b = Peer("android", f"knit-peer B {nonce}", others | {a_id}, arguments.peer_log, arguments.rssi_floor, "group-b")
    stop = threading.Event()
    try:
        a.start()
        b.start()
        threading.Thread(target=_keep_to, args=(a, {phone_id}, set(a.refuse), stop, a.instance), daemon=True).start()
        threading.Thread(target=_keep_to, args=(b, {phone_id}, set(b.refuse), stop, b.instance), daemon=True).start()
        run.step("link-a-phone", lambda: link_up(a, phone, phone_id) and {})
        run.step("link-b-phone", lambda: link_up(b, phone, phone_id) and {})
        _keys_cross(run, phone, phone_id, b)
        # A seals to B, and B checks A's signature, with keys that crossed the phone.
        run.step("b-profile-reaches-a", lambda: {"name": a.wait(lambda line: line.get("event") == "profile" and line.get("peer") == b_id, 240)["displayName"]})
        run.step("a-profile-reaches-b", lambda: {"name": b.wait(lambda line: line.get("event") == "profile" and line.get("peer") == a_id, 240)["displayName"]})
        run.step("custody-a-phone", lambda: _converges(a, phone, 900))
        run.step("custody-b-phone", lambda: _converges(b, phone, 900))
        # A is a fresh identity, so the phone is a stranger to it and its group is a request there.
        trio = _group_walk(run, a, phone, phone_id, b, ghost, nonce, True)
        run.step("custody-a-phone-again", lambda: _converges(a, phone, 300, frozenset({trio})))
        run.step("custody-b-phone-again", lambda: _converges(b, phone, 300))
        run.step("a-never-linked-b", lambda: _never_linked(a, b_id))
    finally:
        stop.set()
        a.stop()
        b.stop()
    print(json.dumps({"summary": "group", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _keys_cross(run: Run, phone: Phone, phone_id: str, far: Node) -> None:
    """The phone and `far`, the group's third member, pin each other's keys: Android seals a group message only to
    members whose key it holds, and skips the rest without a word (`MeshManager.kt:1159-1179`)."""
    run.step(
        "phone-profile-reaches-far-end",
        lambda: {"name": far.wait(lambda line: line.get("event") == "profile" and line.get("peer") == phone_id, 240)["displayName"]},
    )
    run.step("far-end-profile-reaches-phone", lambda: _timed(lambda: _phone_holds_profile(phone, far.node_id), 240))


def _group_walk(run: Run, hub: Node, phone: Phone, phone_id: str, far: Node, ghost: str, nonce: str, hub_request: bool | None) -> str:
    """The group steps `iphone-group` and `group` share (ADR 2026-09.n393). `hub` acts as the iPhone does in
    `iphone-group`, and the phone and `far` are the group's other members. `ghost` is an identity nothing runs, so no
    member holds its key. `hub_request` is whether the phone's group should reach the hub as a message request, None
    for either. Returns the id of the group of all three, whose frames the hub and the phone both carry.

    1. The phone makes a group of all three and writes in it. `far`, to which the phone is a stranger, holds it as a
    request.
    2. The hub accepts it and replies. The phone and `far` show the reply, which is sealed to both, and the reply and
    the phone's first message are ticked.
    3. The hub renames the group. The phone shows the new name in its rename line, and `far` holds it.
    4. The hub makes a group of itself, the phone and `ghost`, and writes in it. The message is sealed to the phone
    alone, since nobody holds the ghost's key, and the phone shows it.
    5. The phone leaves that group: the hub shows it, and its next message there waits, sealed to nobody. Then `far`
    leaves the first group: the hub and the phone show it, the hub's roster has `far` departed, and its next message
    there is sealed to the phone alone and never reaches `far`.
    6. The hub leaves the first group and makes it again: the phone shows the hub's leave, then its rejoin, then its
    message."""
    hub_id, far_id = hub.node_id, far.node_id
    # 1
    trio = phone.make_group([hub_id, far_id])
    run.step("group-id-agrees", lambda: _same_id(trio, [phone_id, hub_id, far_id]))
    first = f"interop group from phone {nonce}"
    _phone_sends(phone, first, trio)
    run.step("phone-group-on-hub", lambda: _group_request(hub.wait(lambda line: _message(line, first), 60), hub_request))
    run.step("phone-group-on-far-end-is-a-request", lambda: _group_request(far.wait(lambda line: _message(line, first), 90), True))
    run.step("hub-roster-is-the-phones", lambda: _roster(hub, trio, [hub_id, far_id, phone_id]))
    # 2
    hub.command(cmd="accept", conv=trio)
    reply = f"interop group reply {nonce}"
    sent = hub.command(cmd="group-send", conv=trio, text=reply)
    run.step("reply-on-phone", lambda: _timed(lambda: _has(phone.state(trio), reply), 30))
    run.step("reply-on-far-end", lambda: _latency(far.wait(lambda line: _message(line, reply), 60)))
    run.step("reply-sealed-to-both", lambda: _sealed_to(hub, sent["id"], {phone_id, far_id}))
    run.step("reply-ticked", lambda: _delivered(hub, sent, 60))
    run.step("phone-message-ticked", lambda: _timed(lambda: _received(phone.state(trio), first), 60))
    # 3
    name = f"Interop {nonce}"
    hub.command(cmd="group-rename", conv=trio, name=name)
    run.step("rename-on-phone", lambda: _timed(lambda: _phone_row(phone, trio, f"grename:{trio}:", name), 60))
    run.step("rename-on-far-end", lambda: _timed(lambda: _group_of(far, trio)["name"] == name, 60))
    # 4
    duo = hub.command(cmd="group-create", members=[phone_id, ghost])["id"]
    run.step("hub-group-id-agrees", lambda: _same_id(duo, [hub_id, phone_id, ghost]))
    body = f"interop hub group {nonce}"
    sent = hub.command(cmd="group-send", conv=duo, text=body)
    run.step("hub-group-sealed-to-phone-alone", lambda: _sealed_to(hub, sent["id"], {phone_id}))
    run.step("hub-group-on-phone", lambda: _timed(lambda: _has(phone.state(duo), body), 60))
    run.step("hub-group-ticked", lambda: _delivered(hub, sent, 60))
    # 5
    phone.leave_group(duo)
    run.step("phone-leave-on-hub", lambda: _timed(lambda: _node_row(hub, duo, MEMBER_LEFT, f"leave:{duo}:{phone_id}"), 60))
    waits = hub.command(cmd="group-send", conv=duo, text=f"interop hub group after the phone left {nonce}")
    run.step("hub-group-waits-for-a-key", lambda: _waits(waits))
    far.command(cmd="group-leave", conv=trio)
    run.step("far-leave-on-hub", lambda: _timed(lambda: _node_row(hub, trio, MEMBER_LEFT, f"leave:{trio}:{far_id}"), 60))
    run.step("far-leave-on-phone", lambda: _timed(lambda: _phone_row(phone, trio, f"leave:{trio}:{far_id}"), 60))
    run.step("hub-roster-without-far-end", lambda: _roster(hub, trio, [hub_id, phone_id], departed=[far_id]))
    body = f"interop group after a leave {nonce}"
    sent = hub.command(cmd="group-send", conv=trio, text=body)
    run.step("after-leave-sealed-to-phone-alone", lambda: _sealed_to(hub, sent["id"], {phone_id}))
    run.step("after-leave-on-phone", lambda: _timed(lambda: _has(phone.state(trio), body), 60))
    run.step("after-leave-not-on-far-end", lambda: _left_out(far, body, 20))
    # 6
    hub.command(cmd="group-leave", conv=trio)
    run.step("hub-leave-on-phone", lambda: _timed(lambda: _phone_row(phone, trio, f"leave:{trio}:{hub_id}"), 60))
    again = hub.command(cmd="group-create", members=[phone_id, far_id])["id"]
    run.step("hub-makes-the-same-group", lambda: _same_id(again, [phone_id, hub_id, far_id]))
    body = f"interop group after a rejoin {nonce}"
    hub.command(cmd="group-send", conv=trio, text=body)
    run.step("rejoin-on-phone", lambda: _timed(lambda: _phone_row(phone, trio, f"rejoin:{trio}:{hub_id}"), 60))
    run.step("rejoin-message-on-phone", lambda: _timed(lambda: _has(phone.state(trio), body), 60))
    return trio


# The `kind` of a member's leave in a `messages` reply: Android's notice code (MessageEntity.KIND_MEMBER_LEFT).
MEMBER_LEFT = 1
# The largest canonical node id, which every other sorts below.
LAST_NODE_ID = "z" * 25 + "y"


def _ghost(instance: str) -> str:
    """An identity nothing ever runs, for a group member nobody holds a key for. keygen wants a bound, and any id will
    do."""
    return _keygen(instance, "--below", LAST_NODE_ID)


def _knows(node: Node, other: str) -> bool:
    """Whether `node` has written to `other` or verified it, either of which makes `other` a known sender there, so a
    group `other` writes in is a chat rather than a request (`Conversations.isAccepted`). An Accept leaves nothing the
    control lines show, so False may still be a known sender."""
    wrote = any(m.get("from") == node.node_id for m in node.command(cmd="messages", conv=other, limit=500)["messages"])
    return wrote or any(p["peer"] == other and p.get("verified") for p in node.command(cmd="peers")["peers"])


def _group_id(members: list[str]) -> str:
    """knit-next's `Conversations.groupIdFor`. Node ids are ASCII, so Python's sort is Java's here."""
    canonical = ",".join(sorted(set(members)))
    return "g-" + hashlib.sha256(f"knit-group-id-v1:{canonical}".encode()).hexdigest()[:24]


def _same_id(group: str, members: list[str]) -> dict:
    expected = _group_id(members)
    if group != expected:
        raise RuntimeError(f"{group}, where its members derive {expected}")
    return {"group": group}


def _phone_sends(phone: Phone, body: str, conversation: str) -> None:
    reply = phone.send(body, conversation=conversation)
    if reply.get("status") != "ok":
        raise RuntimeError(f"the phone did not send to {conversation}: {reply}")


def _phone_holds_profile(phone: Phone, node: str) -> dict | None:
    """Whether the phone carries `node`'s profile, which it pins as it takes it."""
    rows = phone.bridge("STORE", limit=5000).get("rows", [])
    return {"profile": True} if any(row.get("type") == "profile" and row.get("sender") == node for row in rows) else None


def _group_request(line: dict, expected: bool | None) -> dict:
    """A group message's arrival, as a message request or not; `expected` None takes either and says which."""
    request = bool(line.get("request"))
    if expected is not None and request != expected:
        raise RuntimeError(f"arrived {'as' if request else 'not as'} a message request")
    return {**_latency(line), "request": request}


def _group_of(node: Node, group: str) -> dict:
    held = next((entry for entry in node.command(cmd="groups")["groups"] if entry["id"] == group), None)
    if held is None:
        raise RuntimeError(f"no group {group}")
    return held


def _roster(node: Node, group: str, members: list[str], departed: list[str] | None = None) -> dict:
    """The node holds `group` with `members` in roster order, and `departed` when given."""
    held = _group_of(node, group)
    if held["members"] != members or (departed is not None and held["departed"] != departed):
        raise RuntimeError(f"holds {held['members']}, departed {held['departed']}")
    return {"members": len(members)}


def _sealed_to(node: Node, message_id: str, expected: set[str]) -> dict:
    """The sealed chat `message_id`, as the node carries it, is wrapped to `expected` and to nobody else."""
    frame = next((frame for frame in node.command(cmd="custody")["frames"] if frame["id"] == message_id), None)
    if frame is None or "wrappedTo" not in frame:
        raise RuntimeError(f"carries no sealed frame {message_id}")
    wrapped = set(frame["wrappedTo"])
    if wrapped != expected:
        raise RuntimeError(f"wrapped to {sorted(wrapped)}, not {sorted(expected)}")
    return {"wrappedTo": len(wrapped)}


def _waits(reply: dict) -> dict:
    """A group message that no member can open yet waits for a key, unsent (ADR 2026-09.n393)."""
    if not reply.get("ok") or not reply.get("pendingKey"):
        raise RuntimeError(f"not waiting: {reply}")
    return {}


def _phone_row(phone: Phone, conversation: str, prefix: str, body: str | None = None) -> dict | None:
    """The phone's row in `conversation` whose id starts with `prefix`, and whose body is `body` when given. STATE
    reports no row kind, but a status line's id names its event (`leave:`, `rejoin:`, `grename:`, knit-next's
    StatusNotices.kt), and a rename's body is the new name."""
    for message in phone.state(conversation, limit=50).get("messages", []):
        if message.get("id", "").startswith(prefix) and (body is None or message.get("body") == body):
            return {"row": message["id"]}
    return None


def _node_row(node: Node, conversation: str, kind: int, row_id: str) -> dict | None:
    """The node's status line `row_id`, of `kind`, from its `messages` reply."""
    rows = node.command(cmd="messages", conv=conversation, limit=50)["messages"]
    return {"row": row_id} if any(row.get("kind") == kind and row.get("id") == row_id for row in rows) else None


def _left_out(node: Node, body: str, seconds: float) -> dict:
    """`body` never reaches the node within `seconds`: it left the group, so it drops the group's frames unopened."""
    time.sleep(seconds)
    if node.lines(lambda line: _message(line, body)):
        raise RuntimeError("took a message for a group it left")
    return {}


def iphone_peer(arguments: argparse.Namespace) -> int:
    """MVP items 2 to 6 between the iPhone and knit-peer on hci0, which the spec asks of the peer as well as of
    an Android phone. `--order` puts the iPhone's node id above or below a fresh peer identity, so the iPhone's first DM
    is a message request on the peer every run.

    The peer runs the `android` profile, which leaves FLAG_DIALS_GATT_PEERS clear by default, as Android before knit-next
    `713b29d6` does, so the iPhone dials it in both orders and the peer admits it unsighted, as an A1 phone does (ADR
    2026-09.6es2). `--release-android` sets the flag (knit-peer's `--gatt-reads`), as every Android build since does,
    and has the peer never sight the iPhone, a gapped Android that never dials it: the iPhone below it then dials it
    once its 12 s head start ends (interop-audit finding AND-2), and the run records the first link's time and the
    iPhone's head-start line. With `--order iphone-above`, the iPhone dials it at the ordinary dwell, and logs no
    head-start line. The peer refuses every node but the iPhone, so whatever crosses between the two crossed
    their own link. It runs on hci0, dongle B since 2026-10-03, which takes the iPhone's dial (.agents/context/linux-peer.md,
    "What the nRF52840 dongles showed"), unless `--adapter hci1` picks dongle A."""
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    others = others_in_range(ios.node_id)
    peer_id = _keygen("iphone-peer", *_peer_window(ios.node_id, others, arguments.order))
    header = {"run": "iphone-peer", "iphone": ios.node_id, "peer": peer_id, "order": arguments.order, "refused": sorted(others)}
    print(json.dumps({**header, "releaseAndroid": arguments.release_android, "adapter": arguments.adapter}))
    run.step("iphone-forgot-old-peers", lambda: _forgets_all_but(ios, others))
    stop = threading.Event()
    release = arguments.release_android
    peer = Peer(
        "android",
        f"knit-peer {nonce}",
        others,
        arguments.peer_log,
        arguments.rssi_floor,
        "iphone-peer",
        hci0() if arguments.adapter == "hci0" else [],
        never_sight={ios.node_id} if release else None,
        gatt_reads=True if release else None,
    )
    knit = _iphone_log(ios, f"interop-iphone-peer-{nonce}.log") if release else None
    try:
        started, wall = time.monotonic(), time.time()
        peer.start()
        threading.Thread(target=_keep_to, args=(peer, {ios.node_id}, set(peer.refuse), stop, peer.instance), daemon=True).start()
        run.step("link", lambda: _linked_since(peer, ios.node_id, started, 180))
        below = arguments.order == "iphone-below"
        if release:
            run.step("peer-flagged", lambda: _sighted_flagged(ios, peer_id))
            if below:
                run.step("head-start-line", lambda: _head_start_logged(knit, peer_id, wall))
            else:
                run.step("no-head-start-line", lambda: _no_head_start_line(knit, peer_id, wall))
        run.step("profile-on-iphone", lambda: _ios_pinned(ios, peer_id, peer.name))
        run.step("profile-on-peer", lambda: _peer_pinned(peer, ios))
        run.step("safety-numbers-match", lambda: _same_safety_number(ios, peer))
        # The iPhone back-fills the newcomer first, and new frames queue behind that, so posts are timed after it. Group
        # frames are left out: a group frame is served only to its members, and the fresh peer is in no group.
        run.step("custody-converges", lambda: _peers_converge(peer, ios, 300, frozenset()))
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
            wall = time.time()
            _offline(run, ios, peer, peer_id, nonce)
            if release and below:
                run.step("relink-head-start-line", lambda: _head_start_logged(knit, peer_id, wall))
        run.step("custody-converges-again", lambda: _peers_converge(peer, ios, 300, frozenset()))
    finally:
        stop.set()
        peer.stop()
        ios.stop()
        if knit:
            knit.stop()
    print(json.dumps({"summary": "iphone-peer", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _sighted_flagged(ios: IPhone, peer_id: str) -> dict:
    """The iPhone sights the peer with FLAG_DIALS_GATT_PEERS set, so only the head start dialed it."""
    flags = next((s["flags"] for s in ios.command(cmd="links")["sightings"] if s["peer"] == peer_id), None)
    if flags is None or not flags & DIALS_GATT_PEERS:
        raise RuntimeError(f"the iPhone sights the peer with flags {flags}")
    return {"flags": flags}


def _head_start_logged(knit, peer_id: str, since: float, timeout: float = 30) -> dict:
    """The iPhone logged its head-start line for the peer since `since`, on the wall clock."""
    if knit is None:
        raise RuntimeError("the iPhone's log is not being read: it needs the iPhone on USB")
    line = poll(lambda: _head_start_line(knit, peer_id, since), timeout, every=2)
    return {"line": line}


def _no_head_start_line(knit, peer_id: str, since: float) -> dict:
    """The iPhone, above the peer, dialed it without a head start: no head-start line for it since `since`."""
    if knit is None:
        raise RuntimeError("the iPhone's log is not being read: it needs the iPhone on USB")
    line = _head_start_line(knit, peer_id, since)
    if line:
        raise RuntimeError(f"the iPhone gave a head start to a peer below it: {line}")
    return {}


def iphone_photos(arguments: argparse.Namespace) -> int:
    """Photos in chats both ways between the iPhone and an Android phone, in Nearby, a DM and a group (ADR 2026-10.6cas).
    The iPhone sends through its bridge and the phone through SENDIMG, each a fresh picture, so no node holds it yet. The
    phone's log shows the iPhone's photo come in whole from the iPhone, and the bridge's `messages` shows the phone's
    photo held on the iPhone. A DM's or a group's photo travels sealed, and only its message's key opens it: the screens
    show whether it opened. With `--animated` both pictures are GIFs, and the iPhone must play both, the phone's as the
    animated WebP Android sends. The two must already hold each other's keys."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    try:
        phone_id = phone.state()["self"]["nodeId"]
        print(json.dumps({"run": "iphone-photos", "phone": phone_id, "iphone": ios.node_id, "nonce": nonce}))
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
        group = ios.command(cmd="group-create", members=[phone_id])["id"]
        run.step("group-ids-agree", lambda: _agrees(group, phone.make_group([ios.node_id])))
        for kind, on_ios, on_phone in (("room", "nearby", "nearby"), ("dm", phone_id, ios.node_id), ("group", group, group)):
            _photos_both_ways(run, ios, phone, kind, (on_ios, on_phone), nonce, animated=arguments.animated)
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone-photos", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _photos_both_ways(
    run: Run, ios: IPhone, phone: Phone, kind: str, threads: tuple[str, str], nonce: str, *, animated: bool = False
) -> None:
    """A photo from the iPhone to the phone, then one back, in the thread the two know as `threads`, the iPhone's id for
    it first: GIFs when `animated`, which the iPhone must play."""
    on_ios, on_phone = threads
    body = f"photo from iphone, {kind} {nonce}"
    seed = f"{nonce}-iphone-{kind}"
    picture, mime = (_noise_gif(seed), "image/gif") if animated else (_noise_jpeg(seed), "image/jpeg")
    sent = _ios_photo(ios, kind, on_ios, body, picture, mime)
    run.step(f"{kind}-iphone-to-phone", lambda: poll(lambda: _has(phone.state(on_phone), body), 60) and {})
    run.step(
        f"{kind}-iphone-photo-on-phone",
        lambda: poll(lambda: _phone_got_file(phone, sent["attachmentHash"], ios.node_id), 180),
        hash=sent["attachmentHash"],
    )
    back = f"photo from phone, {kind} {nonce}"
    reply = phone.bridge("SENDIMG", path=_stage_photo(phone, f"{nonce}-phone-{kind}", animated), text=back, conv=on_phone)
    held = run.step(f"{kind}-phone-photo-on-iphone", lambda: poll(lambda: _ios_holds(ios, on_ios, back), 180), sent=reply)
    shown = {sent["attachmentHash"]} | ({held["hash"]} if held else set())
    run.step(f"{kind}-photos-show-on-iphone", lambda: _ios_shows(ios, on_ios, shown))
    if animated:
        run.step(f"{kind}-photos-play-on-iphone", lambda: _ios_plays(ios, on_ios, shown))
    run.step(f"{kind}-phone-screen", lambda: _phone_screen(phone, on_phone, f"{nonce}-{kind}"))


def iphone_block(arguments: argparse.Namespace) -> int:
    """A block on the iPhone changes nothing the mesh sees (ADR 2026-10.5wgg, after knit-next's ADRs 010 and bts9). The
    iPhone blocks the phone through its bridge, and the phone posts in Nearby and sends a DM. The phone's post still
    shows the iPhone's ✓✓ while its DM shows none, the iPhone stores neither and counts both under `blocked`, and the two
    custody sets still converge. After the unblock, the DM sent before the block is still there and the one sent during
    it never arrives. The phone must link to the iPhone alone, so that the post's ✓✓ is the iPhone's, and the two must
    already hold each other's keys."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    try:
        phone_id = phone.state()["self"]["nodeId"]
        print(json.dumps({"run": "iphone-block", "phone": phone_id, "iphone": ios.node_id, "nonce": nonce}))
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
        before = f"interop dm before the block {nonce}"
        phone.send(before, conversation=ios.node_id)
        run.step("dm-before-the-block", lambda: _latency(ios.wait(lambda line: _message(line, before), 20)))
        ios.command(cmd="block", peer=phone_id)
        run.step("blocked", lambda: _ios_blocked(ios, phone_id, True))
        counted = _ios_dropped_blocked(ios)
        room = f"interop room while blocked {nonce}"
        phone.send(room)
        run.step("room-while-blocked-ticked", lambda: _timed(lambda: _received(phone.state("nearby"), room), 30))
        during = f"interop dm while blocked {nonce}"
        phone.send(during, conversation=ios.node_id)
        run.step("both-counted-blocked", lambda: _timed(lambda: _ios_dropped_blocked(ios) >= counted + 2, 30))
        run.step("dm-while-blocked-unticked", lambda: _stays_false(lambda: _received(phone.state(ios.node_id), during), 30))
        run.step("iphone-stores-neither", lambda: _ios_lacks(ios, {"nearby": room, phone_id: during}))
        run.step("custody-converges-while-blocked", lambda: _converges(ios, phone, 180))
        ios.command(cmd="unblock", peer=phone_id)
        run.step("unblocked", lambda: _ios_blocked(ios, phone_id, False))
        run.step("dm-before-the-block-kept", lambda: _ios_has(ios, phone_id, before))
        # Past a re-offer, so a peer that would serve the DM again has had its chance.
        run.step("dm-while-blocked-stays-unseen", lambda: _stays_false(lambda: _ios_has_body(ios, phone_id, during), 90))
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone-block", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone_delete(arguments: argparse.Namespace) -> int:
    """A delete on the iPhone sends nothing and stays deleted (ADR 2026-10.u7cq). The phone posts in Nearby, sends a DM
    and writes in a group the two share. Through its bridge the iPhone deletes the post and the group message one by one,
    and the DM's whole chat. Its mesh then stops and starts, and the start replays every group message its own custody
    holds and its threads lack: the deleted one stays gone, and so do the others past a re-offer. The two custody sets
    still converge, and the phone's next DM brings the chat back. The two must already hold each other's keys."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    try:
        phone_id = phone.state()["self"]["nodeId"]
        print(json.dumps({"run": "iphone-delete", "phone": phone_id, "iphone": ios.node_id, "nonce": nonce}))
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
        group = ios.command(cmd="group-create", members=[phone_id])["id"]
        run.step("group-ids-agree", lambda: _agrees(group, phone.make_group([ios.node_id])))
        # Each thread as the iPhone names it, then as the phone does.
        threads = {"room": ("nearby", "nearby"), "dm": (phone_id, ios.node_id), "group": (group, group)}
        bodies = {kind: f"interop {kind} to delete {nonce}" for kind in threads}
        for kind, (on_ios, on_phone) in threads.items():
            _phone_sends(phone, bodies[kind], on_phone)
            run.step(f"{kind}-arrived", lambda on_ios=on_ios, body=bodies[kind]: _timed(lambda: _ios_has_body(ios, on_ios, body), 60))
        for kind in ("room", "group"):
            on_ios = threads[kind][0]
            run.step(f"{kind}-deleted", lambda on_ios=on_ios, body=bodies[kind]: _ios_deletes_message(ios, on_ios, body))
        run.step("dm-chat-deleted", lambda: _ios_ok(ios.command(cmd="delete-chat", conv=phone_id)))
        deleted = {on_ios: bodies[kind] for kind, (on_ios, _) in threads.items()}
        run.step("iphone-shows-none", lambda: _ios_lacks(ios, deleted))
        ios.command(cmd="stop")
        ios.command(cmd="start")
        run.step("relinked", lambda: _ios_linked(ios, phone, phone_id))
        # The start replays our custody's group messages; past a re-offer, a peer that would serve the rest again has had
        # its chance.
        run.step("deleted-stays-deleted", lambda: _stays_false(lambda: bool(_ios_holds_any(ios, deleted)), 90))
        run.step("custody-converges", lambda: _converges(ios, phone, 180))
        again = f"interop dm after the delete {nonce}"
        _phone_sends(phone, again, ios.node_id)
        run.step("dm-chat-comes-back", lambda: _timed(lambda: _ios_has_body(ios, phone_id, again), 60))
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone-delete", "steps": run.steps, "failed": run.failed}))
    return run.failed


def iphone_react(arguments: argparse.Namespace) -> int:
    """Reactions both ways, in the clear as Android floods them toward a peer without the ratchet (ADR 2026-10.ehe6).
    The phone posts in Nearby, sends a DM and writes in a group, and reacts 👍 to each through its bridge; the iPhone
    must show each. The group adds a fresh ghost nobody runs, since a group's id comes from its members alone, and the
    two phones' own group may be one either has left. The iPhone reacts ❤️ to each, and the phone must show each; it
    then replaces the room's with 😂 and takes that back with a repeat. The phone replaces its room reaction with 🔥,
    outside the iPhone's six, which the iPhone must still take. A stop and start of the iPhone's mesh flips nothing, and
    the custody sets converge. While the iPhone blocks the phone, the phone's next reaction never lands. The two must
    already hold each other's keys."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
    run = Run()
    nonce = secrets.token_hex(3)
    thumbs, heart, laugh, fire, gasp = "\U0001f44d", "\u2764\ufe0f", "\U0001f602", "\U0001f525", "\U0001f62e"
    ios.start()
    try:
        phone_id = phone.state()["self"]["nodeId"]
        print(json.dumps({"run": "iphone-react", "phone": phone_id, "iphone": ios.node_id, "nonce": nonce}))
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
        ghost = _ghost("iphone-react-ghost")
        group = ios.command(cmd="group-create", members=[phone_id, ghost])["id"]
        run.step("group-ids-agree", lambda: _agrees(group, phone.make_group([ios.node_id, ghost])))
        # Each thread as the iPhone names it, then as the phone does, and the phone's message in it.
        threads = {"room": ("nearby", "nearby"), "dm": (phone_id, ios.node_id), "group": (group, group)}
        ids = {}
        for kind, (on_ios, on_phone) in threads.items():
            body = f"interop {kind} to react to {nonce}"
            _phone_sends(phone, body, on_phone)
            run.step(f"{kind}-arrived", lambda on_ios=on_ios, body=body: _timed(lambda: _ios_has_body(ios, on_ios, body), 60))
            ids[kind] = _ios_message_id(ios, on_ios, body)
        for kind, (on_ios, _) in threads.items():
            phone.bridge("REACT", id=ids[kind], emoji=thumbs)
            run.step(f"{kind}-phone-reaction-shows", lambda on_ios=on_ios, kind=kind: _timed(
                lambda: _ios_reactions(ios, on_ios, ids[kind]).get(phone_id) == thumbs, 60))
        for kind, (_, on_phone) in threads.items():
            _ios_ok(ios.command(cmd="react", id=ids[kind], emoji=heart))
            run.step(f"{kind}-iphone-reaction-shows", lambda on_phone=on_phone, kind=kind: _timed(
                lambda: _phone_reactions(phone, on_phone, ids[kind]).get(ios.node_id) == heart, 60))
        _ios_ok(ios.command(cmd="react", id=ids["room"], emoji=laugh))
        run.step("iphone-replaces", lambda: _timed(lambda: _phone_reactions(phone, "nearby", ids["room"]).get(ios.node_id) == laugh, 60))
        taken = _ios_ok(ios.command(cmd="react", id=ids["room"], emoji=laugh))
        run.step("iphone-takes-back", lambda: _timed(
            lambda: taken.get("emoji") is None and ios.node_id not in _phone_reactions(phone, "nearby", ids["room"]), 60))
        phone.bridge("REACT", id=ids["room"], emoji=fire)
        run.step("any-emoji-shows", lambda: _timed(lambda: _ios_reactions(ios, "nearby", ids["room"]).get(phone_id) == fire, 60))
        before = {kind: _ios_reactions(ios, on_ios, ids[kind]) for kind, (on_ios, _) in threads.items()}
        ios.command(cmd="stop")
        ios.command(cmd="start")
        run.step("relinked", lambda: _ios_linked(ios, phone, phone_id))
        run.step("nothing-flips", lambda: _stays_false(
            lambda: any(_ios_reactions(ios, on_ios, ids[kind]) != before[kind] for kind, (on_ios, _) in threads.items()), 90))
        run.step("custody-converges", lambda: _converges(ios, phone, 180))
        _ios_ok(ios.command(cmd="block", peer=phone_id))
        try:
            phone.bridge("REACT", id=ids["dm"], emoji=gasp)
            run.step("blocked-reaction-never-lands", lambda: _stays_false(
                lambda: _ios_reactions(ios, phone_id, ids["dm"]).get(phone_id) == gasp, 60))
        finally:
            ios.command(cmd="unblock", peer=phone_id)
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone-react", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _ios_message_id(ios: IPhone, conversation: str, body: str) -> str:
    """The id of the iPhone's message `body` in `conversation`: the frame id both sides key reactions by."""
    found = [message["id"] for message in ios.command(cmd="messages", conv=conversation, limit=50)["messages"] if message.get("body") == body]
    if not found:
        raise RuntimeError(f"the iPhone has no {body!r}")
    return found[0]


def _ios_reactions(ios: IPhone, conversation: str, message_id: str) -> dict[str, str]:
    """The reactions standing on the iPhone's message `message_id`, as `{reactor: emoji}`."""
    for message in ios.command(cmd="messages", conv=conversation, limit=50)["messages"]:
        if message.get("id") == message_id:
            return message.get("reactions") or {}
    raise RuntimeError(f"the iPhone has no message {message_id} in {conversation}")


def _phone_reactions(phone: Phone, conversation: str, message_id: str) -> dict[str, str]:
    """The reactions standing on the phone's message `message_id`, as its bridge's `STATE` reports them."""
    for message in phone.state(conversation, limit=50).get("messages", []):
        if message.get("id") == message_id:
            return message.get("reactions") or {}
    raise RuntimeError(f"the phone has no message {message_id} in {conversation}")


def _ios_ok(reply: dict) -> dict:
    """A bridge reply that did what it was asked."""
    if not reply.get("ok"):
        raise RuntimeError(f"the iPhone refused: {reply}")
    return reply


def _ios_deletes_message(ios: IPhone, conversation: str, body: str) -> dict:
    """Deletes the iPhone's message `body` in `conversation` through the bridge, as its bubble's Delete would."""
    found = [message["id"] for message in ios.command(cmd="messages", conv=conversation, limit=50)["messages"] if message.get("body") == body]
    if not found:
        raise RuntimeError(f"the iPhone has no {body!r} to delete")
    return _ios_ok(ios.command(cmd="delete-message", id=found[0]))


def _ios_holds_any(ios: IPhone, bodies: dict[str, str]) -> list[str]:
    """Which of `bodies` the iPhone stores, each looked for in the thread it names."""
    return [body for conversation, body in bodies.items() if _ios_has_body(ios, conversation, body)]


def _ios_blocked(ios: IPhone, peer: str, blocked: bool) -> dict:
    """Whether the iPhone's `peers` says `peer` is blocked, as `blocked` expects."""
    found = [entry for entry in ios.command(cmd="peers")["peers"] if entry["peer"] == peer]
    if not found or found[0].get("blocked") != blocked:
        raise RuntimeError(f"expected blocked {blocked}: {found}")
    return {}


def _ios_dropped_blocked(ios: IPhone) -> int:
    """How many frames the iPhone stopped at delivery because their sender is blocked."""
    return int(ios.command(cmd="status")["dropped"].get("blocked", 0))


def _ios_has_body(ios: IPhone, conversation: str, body: str) -> bool:
    return any(message.get("body") == body for message in ios.command(cmd="messages", conv=conversation, limit=50)["messages"])


def _ios_has(ios: IPhone, conversation: str, body: str) -> dict:
    if not _ios_has_body(ios, conversation, body):
        raise RuntimeError(f"the iPhone lost {body!r}")
    return {}


def _ios_lacks(ios: IPhone, bodies: dict[str, str]) -> dict:
    """The iPhone stores none of `bodies`, each looked for in the thread it names."""
    stored = [body for conversation, body in bodies.items() if _ios_has_body(ios, conversation, body)]
    if stored:
        raise RuntimeError(f"the iPhone stored {stored}")
    return {}


def _stays_false(check, seconds: float, every: float = 2) -> dict:
    """Waits out `seconds`, failing the moment `check` holds."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            raise RuntimeError(f"it happened within {seconds} s")
        time.sleep(every)
    return {"seconds": seconds}


def _ios_shows(ios: IPhone, conversation: str, hashes: set[str]) -> dict:
    """Whether each photo in `hashes` decodes on the iPhone as its thread draws it, a sealed one opened with its key
    (the bridge's `photos`)."""
    photos = {photo["hash"]: photo for photo in ios.command(cmd="photos", conv=conversation)["photos"]}
    missing = sorted(hash_ for hash_ in hashes if not photos.get(hash_, {}).get("shown"))
    if missing:
        raise RuntimeError(f"the iPhone shows none of {missing}: {[photos.get(hash_) for hash_ in missing]}")
    return {"shown": [{key: photos[hash_].get(key) for key in ("mime", "sealed", "width", "height", "frames")} for hash_ in sorted(hashes)]}


def _ios_plays(ios: IPhone, conversation: str, hashes: set[str]) -> dict:
    """Whether each photo in `hashes` plays on the iPhone, more than one frame of it (the bridge's `photos`): a GIF from
    the iPhone as it went, and one from the phone as the animated WebP Android shrinks it into."""
    photos = {photo["hash"]: photo for photo in ios.command(cmd="photos", conv=conversation)["photos"]}
    still = sorted(hash_ for hash_ in hashes if photos.get(hash_, {}).get("frames", 0) < 2)
    if still:
        raise RuntimeError(f"the iPhone plays none of {still}: {[photos.get(hash_) for hash_ in still]}")
    return {"frames": [photos[hash_]["frames"] for hash_ in sorted(hashes)]}


def _phone_screen(phone: Phone, conversation: str, name: str) -> dict:
    """The phone's screen on the thread, kept for a person to look at, since Android's bridge does not say whether a
    photo opened."""
    phone.wake()
    # A swipe lock only: the lab's phones have no PIN, and a keyguard would hide the thread.
    phone.shell("wm dismiss-keyguard")
    phone.open_route(f"chat/{conversation}")
    time.sleep(3)
    path = ROOT / ".build" / "interop-photos" / f"{name}.png"
    shot = subprocess.run(["adb", "-s", phone.serial, "exec-out", "screencap", "-p"], capture_output=True, check=True, timeout=60)
    path.write_bytes(shot.stdout)
    return {"screenshot": str(path.relative_to(ROOT))}


def _agrees(ours: str, theirs: str) -> dict:
    if ours != theirs:
        raise RuntimeError(f"the iPhone's group is {ours} and the phone's {theirs}")
    return {"group": ours}


def _ios_photo(ios: IPhone, kind: str, conversation: str, body: str, picture: bytes, mime: str = "image/jpeg") -> dict:
    """Sends `picture` with `body` from the iPhone, as its composer would: to the room, a DM or a group."""
    photo = base64.b64encode(picture).decode()
    if kind == "room":
        reply = ios.command(cmd="room", text=body, photo=photo, mime=mime)
    elif kind == "dm":
        reply = ios.command(cmd="dm", to=conversation, text=body, photo=photo, mime=mime)
    else:
        reply = ios.command(cmd="group-send", conv=conversation, text=body, photo=photo, mime=mime)
    if not reply.get("attachmentHash") or reply.get("pendingKey"):
        raise RuntimeError(f"the iPhone did not send its photo: {reply}")
    return reply


def _ios_holds(ios: IPhone, conversation: str, body: str) -> dict | None:
    """The iPhone's message `body` once its photo's bytes are here."""
    for message in ios.command(cmd="messages", conv=conversation, limit=50)["messages"]:
        if message.get("body") == body and message.get("attachmentHeld"):
            return {"hash": message["attachmentHash"], "mime": message.get("attachmentMime")}
    return None


def _noise_jpeg(seed: str) -> bytes:
    """A small picture no node holds yet: noise drawn from `seed`, which no encoder shrinks to anything another run made.
    Pillow's `effect_noise` draws the same noise in every process, so two runs' first pictures could match at one of
    its 32 levels, and a node that held one from an earlier run never asked for it (2026-10-06)."""
    from PIL import Image  # noqa: PLC0415 - only the photo runs need it

    draw = random.Random(seed)
    sigma = 64 + draw.randrange(32)
    pixels = bytes(min(255, max(0, round(draw.gauss(128, sigma)))) for _ in range(320 * 240))
    out = io.BytesIO()
    Image.frombytes("L", (320, 240), pixels).convert("RGB").save(out, "JPEG", quality=70)
    return out.getvalue()


def _noise_gif(seed: str) -> bytes:
    """A small moving picture no node holds yet: four frames of `_noise_jpeg`'s noise, a tenth of a second each, for
    good."""
    from PIL import Image  # noqa: PLC0415 - only the photo runs need it

    frames = [Image.open(io.BytesIO(_noise_jpeg(f"{seed}-{index}"))).convert("L") for index in range(4)]
    out = io.BytesIO()
    frames[0].save(out, "GIF", save_all=True, append_images=frames[1:], duration=100, loop=0)
    return out.getvalue()


def _stage_photo(phone: Phone, seed: str, animated: bool = False) -> str:
    """A fresh picture in the app's own storage, where SENDIMG can read it, as `_stage_image` stages the soak's: a GIF
    when `animated`, which Android shrinks into an animated WebP as it sends it."""
    name = "knit-photo.gif" if animated else "knit-photo.jpg"
    local = ROOT / ".build" / "interop-photos" / f"{seed}{Path(name).suffix}"
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_bytes(_noise_gif(seed) if animated else _noise_jpeg(seed))
    subprocess.run(["adb", "-s", phone.serial, "push", str(local), f"/data/local/tmp/{name}"], capture_output=True, check=True, timeout=60)
    phone.shell(f"cat /data/local/tmp/{name} | run-as {PACKAGE} sh -c 'cat > files/{name}'")
    return f"/data/data/{PACKAGE}/files/{name}"


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
    so the `files` counts are reported, not required.

    It passes with the bridge open throughout and no crash or jetsam report for Knit, no link the iPhone or the peer
    ended, every post arriving and ticked, custody and the SeenSet under their caps, memory flat through the second
    half, and custody converged at the end. `idevicesyslog` records the iPhone's log, which says why each of its links
    ended. Knit must stay in front for the hour, so the iPhone's Auto-Lock should be Never. Everything lands in
    `.build/interop-iphone-soak/<start>/`: the iPhone's log, the peer's, `samples.jsonl` and `summary.json`."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid, arguments.host)
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
                "android", f"knit-peer soak {nonce}", others | {phone_id}, arguments.peer_log, arguments.rssi_floor, "iphone-soak", hci0(), out / "peer.log"
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
        self.reacted: set[str] = set()  # the iPhone's posts the phone reacted to
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
            if done is not None and latest:
                self.reacted.add(latest)
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
        # The phone's reactions the iPhone took, from its event lines (ADR 2026-10.ehe6). The same post can be reacted to
        # twice, which takes the reaction back, so only whether each post heard one counts.
        reactions = {line["id"] for line in self.ios.lines(lambda line: line.get("event") == "reaction" and line.get("from") == self.phone_id)}
        status = self.ios.command(cmd="status")
        detail: dict[str, object] = {
            "sent": self.extras,
            "photosHeard": len(self.photo_bodies & heard),
            "phoneDmsHeard": len(self.phone_dms & heard),
            "iphoneDmsDelivered": len([i for i in self.sent_dms["iphone"] if i in ios_delivered]),
            "reactionsHeard": len(self.reacted & reactions),
            "files": status.get("files"),
            "dropped": status.get("dropped"),
        }
        problems = []
        if self.photo_bodies - heard:
            problems.append(f"{len(self.photo_bodies - heard)} photo captions never arrived")
        if self.reacted - reactions:
            problems.append(f"{len(self.reacted - reactions)} of the phone's reactions never reached the iPhone")
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
        keys = ("links", "custody", "dropped", "files", "footprint", "router", "memoryAvailableKb")
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


def _peers_converge(first: Node, second: Node, timeout: float, groups: frozenset[str] | None = None) -> dict:
    """Whether two nodes carry the same live frames. With `groups`, group frames are left out on both sides bar those
    of `groups`, as in `_converged`."""

    def kept(frame: dict) -> bool:
        return groups is None or not frame.get("group") or frame["group"] in groups

    def same() -> dict | None:
        ours = {frame["id"]: frame for frame in first.command(cmd="custody")["frames"] if kept(frame)}
        theirs = {frame["id"]: frame for frame in second.command(cmd="custody")["frames"] if kept(frame)}
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


def _photo(peer: Peer, phone_id: str) -> dict | None:
    """The phone's photo as the peer shows it: held, and the one the phone's signed profile names."""
    phone = next((p for p in peer.command(cmd="peers")["peers"] if p["peer"] == phone_id), None)
    if phone is None or not phone.get("avatarHash"):
        return None
    return {"avatarHash": phone["avatarHash"], "files": peer.command(cmd="status").get("files")}


def _unique_jpeg(path: str, nonce: str) -> bytes:
    """The JPEG at `path` with the run's nonce in a comment segment after its start marker: the same picture under a
    hash no node holds yet, so every run moves the photo afresh."""
    data = Path(path).read_bytes()
    if data[:2] != b"\xff\xd8":
        raise SystemExit(f"{path} is not a JPEG")
    text = f"knit interop {nonce}".encode()
    return data[:2] + b"\xff\xfe" + (len(text) + 2).to_bytes(2, "big") + text + data[2:]


def _phone_got_file(phone: Phone, key: str, sender: str) -> dict | None:
    """The phone's log line for a whole file `sender` streamed it (`rx KIND/key NB in Tms ← sender`), once there is one."""
    for line in _phone_lines(phone):
        match = re.match(rf"rx (\w+)/{key} (\d+)B in (\d+)ms ← {sender}", line)
        if match:
            return {"kind": match[1], "bytes": int(match[2]), "ms": int(match[3])}
    return None


def _ios_served(ios: IPhone, sent_before: int) -> dict:
    """The files the iPhone sent whole during the run. With no photo of its own it pushes nothing, so each is a serve."""
    status = ios.command(cmd="status")
    sent = status["files"]["sent"] - sent_before
    if sent < 1:
        raise RuntimeError(f"the iPhone sent no file: {status['files']}")
    return {"filesSent": sent, "ownPhoto": status.get("avatarHash"), "files": status["files"]}


def _files_sent(peer: Peer) -> dict | None:
    """The peer's files out whole, once there is one: its photo pushed at link-up, or a blob it served."""
    files = peer.command(cmd="status").get("files") or {}
    return files if files.get("sent") else None


LAST_CUSTODY_DIFFERENCE: dict = {}


def _converged(peer: Node, phone: Phone, groups: frozenset[str] = frozenset()) -> dict | None:
    """Whether the node's live custody ids are the phone's. Each side serves a group frame only to the members the
    frame lists (`ForwardSync.onDigest`), and either may carry one it was never served, so group frames are left out
    on both sides, bar those of `groups`, which the caller knows the two must both carry."""
    frames = peer.command(cmd="custody")["frames"]
    ours = {frame["id"] for frame in frames if not frame.get("group") or frame["group"] in groups}
    store = phone.bridge("STORE", limit=5000)
    expired = set(store.get("expiredIds", []))
    left_out = {row["id"] for row in store.get("rows", []) if row.get("group") and row["group"] not in groups}
    theirs = set(store.get("allIds", [])) - expired - left_out
    if ours == theirs:
        return {"ids": len(ours), "groupFramesLeftOut": len(left_out)}
    # Kept for the report when the poll gives up: what each side holds that the other does not.
    rows = {row["id"]: row for row in store.get("rows", [])}
    frames = {frame["id"]: frame for frame in frames}
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


def _converges(peer: Node, phone: Phone, timeout: float, groups: frozenset[str] = frozenset()) -> dict:
    try:
        return poll(lambda: _converged(peer, phone, groups), timeout, every=10)
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
    for name in ("check", "refusal", "replace", "soak", "relay", "iphone-relay", "group", "iphone-group"):
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
    commands.choices["check"].add_argument("--expect-avatar", action="store_true", help="the phone has a photo: check the peer shows it")
    commands.choices["check"].add_argument("--peer-avatar", default="", help="a JPEG the peer takes as its photo and pushes to the phone")
    commands.choices["iphone-relay"].add_argument("--expect-avatar", action="store_true", help="the phone has a photo: check the peer pulls it through the iPhone")
    commands.choices["iphone-relay"].add_argument("--peer-avatar", default="", help="a JPEG the peer takes as its photo, for the phone to pull through the iPhone")
    commands.choices["relay"].add_argument("--expect-avatar", action="store_true", help="the phone has a photo: check B pulls it through A")
    commands.choices["relay"].add_argument("--peer-avatar", default="", help="a JPEG B takes as its photo, for the phone to pull through A")
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
    ios.add_argument(
        "--links", type=int, default=1, help="link-ups to check at the 5 s timeout: the iPhone's dials above the phone (#102), head-start links below it"
    )
    ios.add_argument("--hold", type=float, default=60, help="seconds the relink and each extra link must hold before they are judged")
    ios.add_argument(
        "--count", default="head-start", choices=["head-start", "any"], help="below the phone, which extra links count toward --links"
    )
    ios.add_argument("--away", type=float, default=95, help="below the phone, seconds the iPhone's mesh stays stopped before each extra link")
    ios.add_argument(
        "--wake",
        default="heal",
        choices=["heal", "screen", "none"],
        help="what a poll does to the phone: keep it on and nudge a scan, keep its screen on only, or nothing (a screen-off phone)",
    )
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
    keeps = commands.add_parser("android-keeps-iphone")
    keeps.add_argument("--device", required=True, help="the adb serial of a phone whose id sorts above the iPhone's, with the go-ahead")
    keeps.add_argument("--stages", default="held,redial", help="which of held and redial to run, comma-separated")
    keeps.add_argument("--minutes", type=int, default=10, help="how long the iPhone's link must hold in the background, a DM each minute")
    keeps.add_argument("--hold", type=float, default=60, help="seconds the re-dialed link must hold before its parameters are judged")
    keeps.add_argument("--redial-timeout", type=float, default=150, help="seconds after the shed for the iPhone's dial to be admitted")
    keeps.add_argument("--baseline", action="store_true", help="the phone runs a build without the fix: its re-dial must be refused")
    keeps.add_argument("--quiet", nargs="*", default=[], help="adb serials of other Android phones in range, whose meshes pause for the run")
    keeps.add_argument("--away-wait", type=float, default=300, help="seconds for Knit to leave the front, or come back, once asked")
    keeps.add_argument(
        "--mover",
        default="devicectl",
        choices=["devicectl", "devicetest", "prompts"],
        help="how Knit leaves the front and comes back: the Mac's devicectl, the BackgroundTests device tests, or a person",
    )
    keeps.add_argument("--prompts", action="store_true", help="the same as --mover prompts, for when the Mac cannot reach the iPhone")
    ios_peer = commands.add_parser("iphone-peer")
    ios_peer.add_argument(
        "--order", default="iphone-below", choices=["iphone-below", "iphone-above"], help="where the iPhone's id sorts against the peer's"
    )
    ios_peer.add_argument("--skip-offline", action="store_true", help="leave out MVP item 6, which stops the iPhone's mesh")
    ios_peer.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    ios_peer.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    ios_peer.add_argument(
        "--release-android",
        action="store_true",
        help="the peer advertises as a release Android does, FLAG_DIALS_GATT_PEERS set, and never sights the iPhone, which must dial it",
    )
    ios_peer.add_argument("--adapter", default="hci0", choices=["hci0", "hci1"], help="the peer's adapter: hci0 (dongle B) or hci1 (dongle A)")
    ios_photos = commands.add_parser("iphone-photos")
    ios_photos.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    ios_photos.add_argument("--animated", action="store_true", help="send GIFs both ways, and check that the iPhone plays both")
    ios_block = commands.add_parser("iphone-block")
    ios_block.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    ios_delete = commands.add_parser("iphone-delete")
    ios_delete.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    ios_react = commands.add_parser("iphone-react")
    ios_react.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
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
    pull = commands.add_parser("record-pull")
    pull.add_argument("--out", required=True, help="where to write the recording")
    pull.add_argument("--chunk", type=int, default=1_048_576, help="bytes per record-fetch; the phone sends at most 1 MiB")
    pull.add_argument("--keep", action="store_true", help="leave the recording on the phone after the copy")
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
    seek = commands.add_parser("iphone-seek")
    seek.add_argument("--far", required=True, choices=["hci1", "hci0", "phone"], help="the far side: knit-peer on an adapter, or the phone")
    seek.add_argument("--device", help="the adb serial of a phone the maintainer approved for this session; needed with --far phone")
    seek.add_argument("--mode", default="drop", choices=["drop", "relink", "budget"], help="what happens once the iPhone is locked")
    seek.add_argument("--drop", default="kill", choices=["kill", "radio-off"], help="how --mode drop ends the link; radio-off is hci1's")
    seek.add_argument("--minutes", type=float, default=10, help="how long --mode budget keeps the iPhone locked")
    seek.add_argument("--relink-wait", type=float, default=300, help="how long --mode relink waits for the link while locked")
    seek.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    seek.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    seek.add_argument("--lock-wait", type=float, default=900, help="how long to wait for someone to lock the iPhone")
    seek.add_argument("--unlock-wait", type=float, default=1800, help="how long to wait for someone to open Knit again")
    reads = commands.add_parser("android-reads")
    reads.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    reads.add_argument("--order", default="peer-below", choices=["peer-below", "peer-above"], help="where the peer's id sorts against the phone's")
    reads.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    reads.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
    reads.add_argument("--link-timeout", type=float, default=180, help="seconds for the phone's read and for the link")
    reads.add_argument("--hold", type=float, default=60, help="seconds the link must hold after it comes up")
    reads.add_argument("--quiet-timeout", type=float, default=600, help="seconds for the phone to let go of an earlier peer's payload")
    reads.add_argument("--known", default="", help="iPhones in range the scan may fail to read, by node id, taken as heard and refused; comma-separated")
    reads.add_argument("--hci0", action="store_true", help="run the peer and its scan on hci0, shared, which needs its own go-ahead")
    reads.add_argument("--links", type=int, default=1, help="link-ups to check at the 5 s timeout, with --order peer-above (#102)")
    strangers = commands.add_parser("android-strangers")
    strangers.add_argument("--device", required=True, help="the adb serial of a phone the maintainer approved for this session")
    strangers.add_argument("--variant", required=True, choices=["none", "forged"], help="what the stranger's GATT service serves")
    strangers.add_argument("--minutes", type=float, default=30, help="how long the stranger advertises beside the phone")
    strangers.add_argument("--rotate", type=int, default=20, help="dongle B's RPA timeout in seconds: how often its address changes")
    strangers.add_argument("--quiet", nargs="*", default=[], help="adb serials of other Android phones in range, whose meshes pause for the run")
    strangers.add_argument("--cycle", type=float, default=180, help="seconds between relinks, each a fresh promotion and dial")
    strangers.add_argument("--link-timeout", type=float, default=180, help="seconds for each link")
    strangers.add_argument("--known", default="", help="iPhones in range the scan may fail to read, by node id, taken as heard and refused; comma-separated")
    strangers.add_argument("--peer-log", default="info", choices=["debug", "info", "warning"], help="knit-peer's log level")
    strangers.add_argument("--rssi-floor", type=int, default=-100, help="the peer's promotion floor in dBm (Android's is -90)")
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
    for sub in (
        ios,
        wake,
        keeps,
        reboot,
        rings,
        scan,
        seek,
        by_hand,
        pull,
        ios_peer,
        ios_photos,
        ios_block,
        ios_delete,
        ios_react,
        ios_soak,
        ios_forgets,
        commands.choices["iphone-relay"],
        commands.choices["iphone-group"],
    ):
        sub.add_argument("--udid", help="the iPhone's UDID, when more than one is on USB")
        sub.add_argument(
            "--host",
            default=os.environ.get("KNIT_IPHONE_HOST"),
            help="the iPhone's Wi-Fi address, to reach its bridge over Wi-Fi once its network is pinned (default KNIT_IPHONE_HOST)",
        )
    arguments = parser.parse_args()
    if arguments.command == "iphone-wake" and arguments.sender == "phone" and not arguments.device:
        parser.error("--sender phone needs --device")
    if arguments.command == "iphone-seek" and arguments.far == "phone" and not arguments.device:
        parser.error("--far phone needs --device")
    if arguments.command == "android-reads" and arguments.links > 1 and arguments.order != "peer-above":
        parser.error("--links needs --order peer-above, so that the peer is each link's central")
    if arguments.command in (
        "iphone", "iphone-wake", "android-keeps-iphone", "iphone-reboot", "iphone-photos", "iphone-block", "iphone-delete",
        "iphone-react", "bridge", "record-pull",
    ):
        return {
            "iphone": iphone,
            "iphone-wake": iphone_wake,
            "android-keeps-iphone": android_keeps_iphone,
            "iphone-reboot": iphone_reboot,
            "iphone-photos": iphone_photos,
            "iphone-block": iphone_block,
            "iphone-delete": iphone_delete,
            "iphone-react": iphone_react,
            "bridge": bridge,
            "record-pull": record_pull,
        }[arguments.command](arguments)
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
    if arguments.command == "android-strangers":
        return android_strangers(arguments)
    if arguments.command == "iphone-scan":
        return iphone_scan(arguments)
    if arguments.command == "iphone-seek":
        return iphone_seek(arguments)
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
    scenarios = {
        "check": check,
        "refusal": refusal,
        "replace": replace,
        "soak": soak,
        "relay": relay,
        "iphone-relay": iphone_relay,
        "group": group,
        "iphone-group": iphone_group,
    }
    return scenarios[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
