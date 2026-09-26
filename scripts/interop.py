#!/usr/bin/env python3
"""Checklist L against an Android phone running a debug build of Knit: knit-peer on hci1 on one side, the phone
driven through knit-next's debug bridge on the other (.agents/specs/mvp.md, .agents/context/linux-peer.md).

    scripts/interop.py check   --device SERIAL [--order phone-dials|peer-dials] [--radio-profile android|ios]
                                [--blank-name] [--expect-avatar]
    scripts/interop.py refusal --device SERIAL [--seconds 120]
    scripts/interop.py replace --device SERIAL
    scripts/interop.py soak    --device SERIAL [--minutes 60] [--per-minute 12]

Driving a physical phone needs the maintainer's go-ahead for the session (.agents/rules/devices.md). Nothing here
installs or launches anything: it wakes the phone, asks its bridge to scan, send and report, and reads the answers.

Each step prints one JSON line, {"step": ..., "ok": ..., ...}, and the run ends with a summary line. The exit code
is the number of failed steps.
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PEER = ROOT / ".build" / "out" / "Products" / "Debug-linux-x86_64" / "knit-peer"
PACKAGE = "app.getknit.knit"
INSTANCE = "interop"
# Diagnostic knobs for the L2CAP receive MTU and the largest SDU written, set with --receive-mtu and --send-mtu.
RECEIVE_MTU = ""
SEND_MTU = ""


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


class Peer:
    """knit-peer as a child process: JSON lines in on stdin, replies and events out on stdout.

    Every Knit node in range other than the phone under test is refused a link as soon as the peer is up, before
    the 12 s promotion dwell lets either side dial: the go-ahead covers one phone, and the rest of the mesh should
    not carry the run's traffic."""

    def __init__(
        self, profile: str, name: str, refuse: set[str], log_level: str, rssi_floor: int | None, instance: str = INSTANCE
    ) -> None:
        self.instance = instance
        self.profile = profile
        self.name = name
        self.refuse = refuse
        self.log_level = log_level
        self.rssi_floor = rssi_floor
        self.process: subprocess.Popen[str] | None = None
        self.events: queue.Queue[dict] = queue.Queue()
        self.seen: list[dict] = []
        self.node_id = ""

    def start(self) -> None:
        command = [str(PEER), "run", "--instance", self.instance, "--radio-profile", self.profile, "--name", self.name, "--log", self.log_level]
        if self.rssi_floor is not None:
            command += ["--rssi-floor", str(self.rssi_floor)]
        if RECEIVE_MTU:
            command += ["--receive-mtu", RECEIVE_MTU]
        if SEND_MTU:
            command += ["--send-mtu", SEND_MTU]
        log = open(ROOT / ".build" / "interop-peer.log", "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        ready = self.wait(lambda line: line.get("event") == "ready", 20)
        self.node_id = ready["nodeId"]
        for node in sorted(self.refuse):
            self.command(cmd="deny-link", peer=node)

    def _read(self) -> None:
        assert self.process and self.process.stdout
        for raw in self.process.stdout:
            try:
                self.events.put(json.loads(raw))
            except json.JSONDecodeError:
                continue

    def wait(self, match, timeout: float) -> dict:
        """The first line, already seen or still to come, that matches; raises TimeoutError otherwise."""
        for line in self.seen:
            if match(line):
                return line
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try:
                line = self.events.get(timeout=min(left, 1))
            except queue.Empty:
                continue
            self.seen.append(line)
            if match(line):
                return line
        raise TimeoutError("no matching line from knit-peer")

    def command(self, **fields) -> dict:
        tag = secrets.token_hex(4)
        assert self.process and self.process.stdin
        self.process.stdin.write(json.dumps({**fields, "tag": tag}) + "\n")
        self.process.stdin.flush()
        return self.wait(lambda line: line.get("tag") == tag, 10)

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
        self.seen.clear()


class Run:
    def __init__(self) -> None:
        self.failed = 0
        self.steps = 0

    def step(self, name: str, check, **context) -> object:
        self.steps += 1
        started = time.monotonic()
        try:
            detail = check()
            print(json.dumps({"step": name, "ok": True, "seconds": round(time.monotonic() - started, 1), **context, **(detail or {})}))
            return detail
        except Exception as error:  # noqa: BLE001 - every failure is reported, then the run goes on
            self.failed += 1
            print(json.dumps({"step": name, "ok": False, "seconds": round(time.monotonic() - started, 1), "error": str(error), **context}))
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
        ups = [line for line in peer.seen if line.get("event") == "link" and line.get("peer") == phone_id and line.get("up")]
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
    phone = Phone(arguments.device)
    phone_id = phone.state()["self"]["nodeId"]
    peer = Peer(arguments.radio_profile, "knit-peer soak", others_in_range(phone_id), arguments.peer_log, arguments.rssi_floor)
    peer.start()
    run = Run()
    sent_by_peer: set[str] = set()
    sent_by_phone: set[str] = set()
    try:
        run.step("link", lambda: link_up(peer, phone, phone_id) and {})
        interval = 60 / arguments.per_minute
        end = time.monotonic() + arguments.minutes * 60
        turn = 0
        while time.monotonic() < end:
            body = f"soak {turn}"
            if turn % 2 == 0:
                peer.command(cmd="room", text=body)
                sent_by_peer.add(body)
            else:
                phone.send(body)
                sent_by_phone.add(body)
            turn += 1
            if turn % 50 == 0:
                status = peer.command(cmd="status")
                print(json.dumps({"soak": turn, "links": status["links"], "custody": status["custody"], "dropped": status["dropped"]}))
                sys.stdout.flush()
            time.sleep(interval)
        time.sleep(15)
        heard = {line.get("body") for line in peer.seen if line.get("event") == "message"}
        run.step("no-link-dropped", lambda: _no_link_dropped(peer))
        run.step("phone-posts-all-arrived", lambda: _all(sent_by_phone, heard))
        # The bridge lists a thread's newest messages, so the phone side checks the most recent posts.
        shown = {message["body"] for message in phone.state("nearby", limit=200).get("messages", [])}
        recent = {f"soak {n}" for n in range(max(0, turn - 100), turn, 2) if f"soak {n}" in sent_by_peer}
        run.step("peer-posts-reached-phone", lambda: _all(recent, shown))
        run.step("custody-bounded", lambda: _bounded(peer))
        run.step("peer-alive", lambda: _alive(peer))
    finally:
        peer.stop()
    print(json.dumps({"summary": "soak", "turns": turn, "steps": run.steps, "failed": run.failed}))
    return run.failed


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


def _converged(peer: Peer, phone: Phone) -> dict | None:
    ours = set(peer.command(cmd="digest")["ids"])
    store = phone.bridge("STORE")
    expired = set(store.get("expiredIds", []))
    theirs = set(store.get("allIds", [])) - expired
    if ours == theirs:
        return {"ids": len(ours)}
    # Kept for the report when the poll gives up.
    LAST_CUSTODY_DIFFERENCE.update(
        onlyPeer=len(ours - theirs), onlyPhone=len(theirs - ours), samples=sorted(ours ^ theirs)[:5]
    )
    return None


def _converges(peer: Peer, phone: Phone, timeout: float) -> dict:
    try:
        return poll(lambda: _converged(peer, phone), timeout, every=10)
    except TimeoutError as error:
        raise TimeoutError(f"custody still differs: {LAST_CUSTODY_DIFFERENCE}") from error


def _no_link_dropped(peer: Peer) -> dict:
    downs = [line for line in peer.seen if line.get("event") == "link" and not line.get("up")]
    if downs:
        raise RuntimeError(f"{len(downs)} link downs")
    return {}


def _bounded(peer: Peer) -> dict:
    custody = peer.command(cmd="status")["custody"]
    if custody > 1000:
        raise RuntimeError(f"custody holds {custody}, over Android's 1000")
    return {"custody": custody}


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
    for name in ("check", "refusal", "replace", "soak"):
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
    commands.choices["soak"].add_argument("--per-minute", type=float, default=12, help="posts a minute, both sides together")
    for sub in commands.choices.values():
        sub.add_argument("--receive-mtu", default="", help="the receive MTU each peer channel offers, for diagnosis")
        sub.add_argument("--send-mtu", default="", help="the largest SDU each peer channel writes, for diagnosis")
    arguments = parser.parse_args()
    global RECEIVE_MTU, SEND_MTU  # noqa: PLW0603 - two knobs, read by Peer.start
    RECEIVE_MTU = arguments.receive_mtu
    SEND_MTU = arguments.send_mtu
    if not PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
    return {"check": check, "refusal": refusal, "replace": replace, "soak": soak}[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
