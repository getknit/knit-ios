#!/usr/bin/env python3
"""Checklist L against an Android phone running a debug build of Knit: knit-peer on hci1 on one side, the phone
driven through knit-next's debug bridge on the other (.agents/specs/mvp.md, .agents/context/linux-peer.md).

    scripts/interop.py check   --device SERIAL [--order phone-dials|peer-dials] [--radio-profile android|ios]
                                [--blank-name] [--expect-avatar]
    scripts/interop.py refusal --device SERIAL [--seconds 120]
    scripts/interop.py replace --device SERIAL
    scripts/interop.py soak    --device SERIAL [--minutes 60] [--per-minute 20] [--extras]
    scripts/interop.py relay   --device SERIAL [--radio-profile ios|android]
    scripts/interop.py iphone  --device SERIAL [--udid UDID] [--skip-offline]
    scripts/interop.py iphone-relay --device SERIAL [--udid UDID]
    scripts/interop.py iphone-wake [--sender phone|peer] [--device SERIAL] [--udid UDID] [--minutes 10]
    scripts/interop.py bridge  [--udid UDID] [--watch SECONDS] [COMMAND_JSON ...]

`iphone` runs MVP items 2 to 6 between an iPhone and the Android phone, driving the iPhone through a debug build's
bridge over USB (ADR 2026-09.kwa8); `iphone-relay` runs MVP item 7's line through the iPhone; `iphone-wake` is item 9's
wake test, with someone to lock the iPhone and unlock it again; `bridge` sends that bridge commands by hand and prints
what comes back.

Driving a physical phone needs the maintainer's go-ahead for the session (.agents/rules/devices.md). Nothing here
installs or launches anything: it wakes the phone, asks its bridge to scan, send and report, and reads the answers.
`relay` also runs a second peer on hci0, the maintainer's own adapter, and `iphone-relay` runs its one peer there; hci0
needs its own go-ahead. The peer runs there with --shared-adapter, so it never drops a link it did not make.

Each step prints one JSON line, {"step": ..., "ok": ..., ...}, and the run ends with a summary line. The exit code
is the number of failed steps.
"""

from __future__ import annotations

import argparse
import json
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
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PEER = ROOT / ".build" / "out" / "Products" / "Debug-linux-x86_64" / "knit-peer"
PACKAGE = "app.getknit.knit"
INSTANCE = "interop"
# The maintainer's own adapter, for `relay` only, shared with the devices already on it (.agents/rules/devices.md).
HCI0 = ["--adapter", "hci0", "--adapter-address", "A0:00:00:00:00:01", "--shared-adapter"]
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
    ) -> None:
        super().__init__()
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
        command = [str(PEER), "run", "--instance", self.instance, "--radio-profile", self.profile, "--name", self.name, "--log", self.log_level]
        command += self.adapter
        if self.rssi_floor is not None:
            command += ["--rssi-floor", str(self.rssi_floor)]
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

    def start(self) -> None:
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

    def _write(self, line: str) -> None:
        assert self.socket
        self.socket.sendall(line.encode())

    def stop(self) -> None:
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


def others_in_range(phone_id: str, seconds: int = 20) -> set[str]:
    """Every Knit node a quiet scan hears, bar the phone under test."""
    result = subprocess.run([str(PEER), "scan", "--seconds", str(seconds)], capture_output=True, text=True, check=True)
    summary = json.loads(result.stdout.strip().splitlines()[-1])
    return {node["peer"] for node in summary["nodes"]} - {phone_id}


def keygen(phone_id: str, order: str, others: set[str]) -> str:
    """An identity the phone dials, or that dials the phone, and that no other phone in range dials: this adapter
    cannot advertise while a peer is connected to it, so a refused phone dialing in would hide the peer from the
    phone under test. The larger id dials, so the peer sorts above every other phone, and below the phone when the
    phone should dial it."""
    above = max((node for node in others if node < phone_id or order == "peer-dials"), default=None)
    bounds = ["--below", phone_id] if order == "phone-dials" else ["--above", max(phone_id, above or phone_id)]
    if order == "phone-dials" and above:
        bounds += ["--above", above]
    result = subprocess.run([str(PEER), "keygen", *bounds, "--instance", INSTANCE], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)["nodeId"]


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
    both. The first DM between two phones is a message request only once, so a pair that has talked before checks
    the replies alone. Item 6 stops the iPhone's mesh, which closes every link it has, not only the phone's."""
    phone = Phone(arguments.device)
    ios = IPhone(arguments.udid)
    run = Run()
    nonce = secrets.token_hex(3)
    ios.start()
    state = phone.state()
    phone_id = state["self"]["nodeId"]
    phone_name = state["self"]["name"]
    print(json.dumps({"run": "iphone", "iphone": ios.node_id, "iphoneName": ios.name, "phone": phone_id, "phoneName": phone_name}))
    try:
        run.step("link", lambda: _ios_linked(ios, phone, phone_id))
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
        body = f"interop dm from phone {nonce}"
        phone.send(body, conversation=ios.node_id)
        run.step("dm-phone-to-iphone", lambda: _latency(ios.wait(lambda line: _message(line, body), 20)))
        run.step("dm-phone-to-iphone-ticked", lambda: _timed(lambda: _received(phone.state(ios.node_id), body), 30))
        if not arguments.skip_offline:
            _offline(run, ios, phone, phone_id, nonce)
        run.step("custody-converges", lambda: _converges(ios, phone, 180))
    finally:
        ios.stop()
    print(json.dumps({"summary": "iphone", "steps": run.steps, "failed": run.failed}))
    return run.failed


def _offline(run: Run, ios: IPhone, phone: Phone, phone_id: str, nonce: str) -> None:
    """MVP item 6: a room post and a DM the phone writes while the iPhone's mesh is stopped arrive within 60 s of the
    next link."""
    ios.command(cmd="stop")
    room = f"interop offline room {nonce}"
    direct = f"interop offline dm {nonce}"
    phone.send(room)
    phone.send(direct, conversation=ios.node_id)
    time.sleep(5)
    started = time.monotonic()
    ios.command(cmd="start")
    link = run.step("offline-relinks", lambda: _relinked(ios, phone, phone_id, started))
    if link is None:
        return
    linked_at = started + link["seconds"]
    for name, body in (("offline-room-arrives", room), ("offline-dm-arrives", direct)):
        run.step(name, lambda body=body: _arrives_after(ios, body, linked_at))


def iphone_wake(arguments: argparse.Namespace) -> int:
    """MVP item 9, and P8's first task: whether a DM wakes Knit while the iPhone is locked. With Knit open and linked
    to the sender, someone locks the iPhone. Once iOS suspends Knit, which the run sees as its bridge going quiet, the
    sender DMs it every minute. Knit sends a DM's receipt only once it has opened the DM, so a DM the sender sees
    delivered within its minute woke Knit. Then someone unlocks the iPhone and opens Knit, and the run reads when each
    DM arrived there. The link must hold throughout.

    Data on an open link does not wake a suspended Knit; a write to its doorbell does (.agents/context/linux-peer.md).
    `--sender peer` has knit-peer on hci0 send the DMs, ringing after each as its link manager does, and every DM
    must wake Knit. `--sender phone` has the Android phone send them. Android rings no doorbell yet (companion change
    A4), so its DMs are only counted, and the check is the fallback: each arrives within 60 s of Knit opening."""
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
    print(json.dumps({"run": "iphone-wake", "sender": arguments.sender, "from": sender.node_id, "iphone": ios.node_id, "minutes": arguments.minutes}))
    try:
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
        if arguments.sender == "peer":
            run.step("dms-woke-knit", lambda: _all_woke(len(woke), ticks))
            run.step("peer-rang", sender.rang)
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
        log = self.phone.shell("logcat -d -s BluetoothMeshTransport:*")
        downs = [line.split(": ", 1)[-1] for line in log.splitlines() if f"link down: {self.ios_id}" in line]
        if downs or gone:
            raise RuntimeError(f"the link went down: {gone} looks without it, {downs[:3]}")
        return {}

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


def _relinked(ios: IPhone, phone: Phone, phone_id: str, since: float, timeout: float = 120) -> dict:
    """The next link to the phone after `since`, from the iPhone's own link event."""
    deadline = time.monotonic() + timeout
    while True:
        phone.wake()
        try:
            line = ios.wait(lambda line: _link(line, phone_id) and line.get("up") and line["_at"] > since, 15)
            return {"seconds": round(line["_at"] - since, 1)}
        except TimeoutError:
            if time.monotonic() > deadline:
                raise


def _arrives_after(ios: IPhone, body: str, linked_at: float) -> dict:
    line = ios.wait(lambda line: _message(line, body), 60 + max(0, linked_at - time.monotonic()))
    after = round(line["_at"] - linked_at, 1)
    if after > 60:
        raise RuntimeError(f"arrived {after} s after the link")
    return {"secondsAfterLink": after}


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
    """Checklist L's third group: with the `ios` profile Android 2.7 cannot see the peer, so the peer dials, and
    Android's responder closes a dialer whose id sorts below its own (`BluetoothMeshTransport.kt:754`). The link
    never comes up; companion change A1 is what lets it."""
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
        the new one: the old link's end must not take it down, and nothing else may drop it meanwhile."""
    phone = Phone(arguments.device)
    run = Run()
    nonce = secrets.token_hex(3)
    phone_id = phone.state()["self"]["nodeId"]
    others = others_in_range(phone_id)
    peer_id = keygen(phone_id, arguments.order, others)
    print(json.dumps({"run": "replace", "phone": phone_id, "peer": peer_id, "refused": sorted(others)}))
    state = Path.home() / ".local" / "state" / "knit-peer"
    name = f"knit-peer {nonce}"
    # Both processes refuse the phone until both are up, so neither one's start releases the other's link. The
    # second copies the first's state once the first has published its profile, so the two publish the same
    # profile frame; different stamps under one identity would be a clone, and custody would never converge.
    first = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor)
    first.start()
    shutil.copytree(state / INSTANCE, state / f"{INSTANCE}-b", dirs_exist_ok=True)
    second = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor, instance=f"{INSTANCE}-b")
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
        first = Peer("ios", name, others | {phone_id}, arguments.peer_log, arguments.rssi_floor)
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
    try:
        return _converges(peer, phone, 120)
    except TimeoutError:
        dropped = peer.command(cmd="status")["dropped"]
        difference = dict(LAST_CUSTODY_DIFFERENCE)
        if difference.get("onlyPeer") or not dropped.get("noSenderKey"):
            raise RuntimeError(f"custody differs, and not for want of the key: {difference}, dropped {dropped}") from None
        return {"converged": False, "onlyPhone": difference["onlyPhone"], "noSenderKey": dropped["noSenderKey"]}


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
    threading.Thread(target=_keep_to, args=(peer, {phone_id}, stop), daemon=True).start()
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
    for name in ("check", "replace"):
        commands.choices[name].add_argument("--order", default="phone-dials", choices=["phone-dials", "peer-dials"])
    commands.choices["check"].add_argument("--blank-name", action="store_true", help="run the peer with no name, so each side shows the alias")
    commands.choices["check"].add_argument("--expect-avatar", action="store_true", help="the phone has a photo: check its FILE records")
    commands.choices["refusal"].add_argument("--seconds", type=float, default=120, help="how long to watch the dials fail")
    commands.choices["soak"].add_argument("--minutes", type=float, default=60)
    commands.choices["soak"].add_argument("--per-minute", type=float, default=20, help="posts a minute, both sides together")
    commands.choices["soak"].add_argument("--extras", action="store_true", help="the phone also reacts, types, DMs and posts photos")
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
    by_hand = commands.add_parser("bridge")
    by_hand.add_argument("--watch", type=float, default=0, help="print the bridge's events for this many seconds")
    by_hand.add_argument("commands", nargs="*", help='commands as JSON, such as \'{"cmd":"status"}\'')
    for sub in (ios, wake, by_hand, commands.choices["iphone-relay"]):
        sub.add_argument("--udid", help="the iPhone's UDID, when more than one is on USB")
    arguments = parser.parse_args()
    if arguments.command == "iphone-wake" and arguments.sender == "phone" and not arguments.device:
        parser.error("--sender phone needs --device")
    if arguments.command in ("iphone", "iphone-wake", "bridge"):
        return {"iphone": iphone, "iphone-wake": iphone_wake, "bridge": bridge}[arguments.command](arguments)
    global RECEIVE_MTU, SEND_MTU  # noqa: PLW0603 - two knobs, read by Peer.start
    RECEIVE_MTU = arguments.receive_mtu
    SEND_MTU = arguments.send_mtu
    if not PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
    if arguments.command == "relay" and "--radio-profile" not in sys.argv:
        # Peer A stands in for the iPhone, which Android finds only by its GATT payload.
        arguments.radio_profile = "ios"
    scenarios = {"check": check, "refusal": refusal, "replace": replace, "soak": soak, "relay": relay, "iphone-relay": iphone_relay}
    return scenarios[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
