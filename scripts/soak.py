#!/usr/bin/env python3
"""A long soak of knit-peer on hci1 against every Knit phone in range: MVP item 11, then a night of it.

    scripts/soak.py run    [--hours 10] [--phases "0=shakeout 1=sparse 2=dark 9=mixed"] [--out DIR]
    scripts/soak.py status [DIR]
    scripts/soak.py report [DIR] [--json]
    scripts/soak.py stop   [DIR]

`run` drives no phone. The peer takes a node id above every phone's, so it dials each of them and none dials it:
this adapter cannot be a peripheral and a central at once (`.agents/context/linux-peer.md`), so a phone dialing in
would cut the rest off. The peer then sends traffic by phase, the way knit-next's lab soak does
(`.private/scripts/soak/` there), and the phones answer on their own: a room tick for each post while linked, a
receipt for each DM (Android acknowledges a stranger's DM too), their profiles, digests and back-fill, key requests,
and whatever the lab posts.

- **shakeout:** MVP item 11's hour, a room post every 7 to 13 s and a round of DMs every 10 minutes.
- **sparse:** a post every 4 to 6 minutes, a burst every 20 to 40, and DMs every 30.
- **dark:** no drip, so the phones can doze: a burst every one to two hours and DMs every two, to see both land.
- **mixed:** a post every 20 to 40 s, bursts and DMs every 20 to 40 minutes.

A burst is 4 to 24 posts, 3 to 20 s apart. Posts carry knit-next's audit keys, `soak <phase> #<n> peer <hhmmss>` and
`burst <id> #<i>/<n>`, so its `cleanup.sh` purges them from the fleet afterwards. DMs go to the phones the first scan
heard and to any the peer links since, never to the stale identities their back-fill pins.

Everything lands in the run's directory, `.build/soak/<start>/` unless `--out` says otherwise, and
`.build/soak/current` names the latest; `status`, `report` and `stop` read it when given no directory:

- `knit-peer`: the binary the run started with, which it keeps using, restarts included;
- `run.json`: the settings, the peer's node id, the commit and the phones the first scan heard;
- `sent.jsonl`: each post and DM, with its phase and the driver's wall-clock time;
- `events.jsonl`: every event the peer emitted, stamped the same way;
- `metrics.jsonl`: the peer's `status`, links, custody, footprint and the process's memory, every few minutes;
- `status.json` and `heartbeat`: the latest of those, rewritten each sample;
- `crashes.jsonl`: a peer that exited or stopped answering, with the tail of its log (the driver restarts it);
- `peer.log`: the peer's own log, at debug level, which says why each link ended;
- `summary.json`: the report, written when the run ends.

`report` reads a run's directory, finished or not, and checks it against MVP item 11: no crash, no link drop our
side caused, custody within Android's quotas, and memory tables that level off. `stop`, SIGINT or SIGTERM ends a
run early and still writes the summary. Obey `.agents/rules/devices.md`: hci1 only.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import random
import re
import secrets
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PEER = ROOT / ".build" / "out" / "Products" / "Debug-linux-x86_64" / "knit-peer"
INSTANCE = "soak"
CURRENT = ROOT / ".build" / "soak" / "current"
# Node ids are base32, and compare as ASCII: a `zz` prefix sorts above all but one id in 1024, so a phone that
# arrives mid-run is almost surely below the peer too, and the peer dials it.
TOP = "zz" + "a" * 24
ANSWER_SECONDS = 20
RESTART_SECONDS = 10
# Android's overall custody cap; the room and each sender get 200 of it (.agents/context/custody.md).
CUSTODY_CAP = 1000
SEEN_CAP = 4096
# Per phase: seconds between drip posts, minutes between bursts, minutes between DM rounds. None is never.
PHASES = {
    "shakeout": {"post": (7, 13), "burst": None, "dm": 10},
    "sparse": {"post": (240, 360), "burst": (20, 40), "dm": 30},
    "dark": {"post": None, "burst": (60, 120), "dm": 120},
    "mixed": {"post": (20, 40), "burst": (20, 40), "dm": 20},
}
BURST_SIZE = (4, 24)
BURST_GAP = (3, 20)
ERRNO = {103: "ECONNABORTED", 104: "ECONNRESET", 107: "ENOTCONN", 110: "ETIMEDOUT", 111: "ECONNREFUSED", 112: "EHOSTDOWN", 113: "EHOSTUNREACH"}


def wall_ms() -> int:
    return time.time_ns() // 1_000_000


def append(path: Path, record: dict) -> None:
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(record, sort_keys=True) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    lines = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            lines.append(json.loads(raw))
        except json.JSONDecodeError:
            continue
    return lines


class Peer:
    """knit-peer as a child process. One reader thread queues its stdout; the driver's thread is the only consumer,
    so replies are matched by tag and every event on the way is written down."""

    def __init__(self, out: Path, arguments: argparse.Namespace) -> None:
        self.out = out
        self.arguments = arguments
        self.process: subprocess.Popen[str] | None = None
        self.lines: queue.Queue[dict | None] = queue.Queue()
        self.on_event = lambda line: None

    def start(self) -> dict:
        command = [
            str(self.out / "knit-peer"), "run", "--instance", INSTANCE, "--radio-profile", "android", "--name", self.arguments.name,
            "--log", self.arguments.peer_log, "--rssi-floor", str(self.arguments.rssi_floor),
        ]
        log = (self.out / "peer.log").open("a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
        log.close()
        self.lines = queue.Queue()
        threading.Thread(target=self._read, args=(self.process, self.lines), daemon=True).start()
        return self.wait(lambda line: line.get("event") == "ready", 30)

    @staticmethod
    def _read(process: subprocess.Popen[str], lines: queue.Queue[dict | None]) -> None:
        assert process.stdout
        for raw in process.stdout:
            try:
                lines.put(json.loads(raw))
            except json.JSONDecodeError:
                continue
        lines.put(None)

    def alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def pump(self, seconds: float) -> None:
        """Writes down every event that arrives within `seconds`."""
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            try:
                line = self.lines.get(timeout=min(left, 1))
            except queue.Empty:
                continue
            if line is None:
                return
            self._route(line)

    def wait(self, match, seconds: float) -> dict:
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            try:
                line = self.lines.get(timeout=min(left, 1))
            except queue.Empty:
                continue
            if line is None:
                raise EOFError("knit-peer exited")
            if match(line):
                return line
            self._route(line)
        raise TimeoutError("knit-peer did not answer")

    def _route(self, line: dict) -> None:
        if "event" in line:
            self.on_event(line)

    def command(self, **fields) -> dict:
        tag = secrets.token_hex(4)
        assert self.process and self.process.stdin
        self.process.stdin.write(json.dumps({**fields, "tag": tag}) + "\n")
        self.process.stdin.flush()
        return self.wait(lambda line: line.get("tag") == tag, ANSWER_SECONDS)

    def stop(self) -> None:
        if self.alive():
            try:
                self.command(cmd="quit")
            except (TimeoutError, EOFError, BrokenPipeError):
                pass
            try:
                assert self.process
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.terminate()
        self.process = None

    def kill(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait()

    def usage(self) -> dict:
        """The process's memory, threads and open files, from /proc."""
        if not self.alive():
            return {}
        assert self.process
        pid = self.process.pid
        fields: dict = {"pid": pid}
        try:
            for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition(":")
                if key in ("VmRSS", "VmHWM"):
                    fields[key.lower() + "Kb"] = int(value.split()[0])
                elif key == "Threads":
                    fields["threads"] = int(value)
            fields["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
            ticks = os.sysconf("SC_CLK_TCK")
            stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()
            fields["cpuSeconds"] = round((int(stat[11]) + int(stat[12])) / ticks, 1)
        except OSError:
            pass
        return fields


def scan(binary: Path, seconds: int) -> list[dict]:
    result = subprocess.run([str(binary), "scan", "--seconds", str(seconds)], capture_output=True, text=True, check=True)
    return json.loads(result.stdout.strip().splitlines()[-1])["nodes"]


def keygen(binary: Path) -> str:
    result = subprocess.run([str(binary), "keygen", "--above", TOP, "--instance", INSTANCE], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)["nodeId"]


def git_head() -> str:
    result = subprocess.run(["git", "-C", str(ROOT), "describe", "--always", "--dirty"], capture_output=True, text=True, check=False)
    return result.stdout.strip()


def parse_phases(text: str) -> list[tuple[float, str]]:
    """`"0=shakeout 1=sparse"`, hours from the start, as sorted (hour, phase) pairs."""
    table = []
    for item in text.split():
        hour, _, phase = item.partition("=")
        if phase not in PHASES:
            raise argparse.ArgumentTypeError(f"no phase {phase!r}; the phases are {', '.join(PHASES)}")
        table.append((float(hour), phase))
    return sorted(table)


def gap(bounds: tuple[float, float]) -> float:
    return random.uniform(*bounds)


class Soak:
    def __init__(self, out: Path, arguments: argparse.Namespace) -> None:
        self.out = out
        self.arguments = arguments
        self.peer = Peer(out, arguments)
        self.peer.on_event = self.on_event
        self.stopping = False
        self.posts = 0
        self.bursts = 0
        self.dms = 0
        self.restarts = 0
        self.phones: set[str] = set()
        self.linked: list[str] = []
        self.started = time.monotonic()

    def phase(self) -> str:
        hours = (time.monotonic() - self.started) / 3600
        return [name for hour, name in self.arguments.phases if hour <= hours][-1]

    def on_event(self, line: dict) -> None:
        append(self.out / "events.jsonl", {"t": wall_ms(), **line})
        if line.get("event") == "link" and line.get("up"):
            self.phones.add(line["peer"])

    def crashed(self, why: str) -> None:
        """Records a peer that exited or stopped answering, with the tail of its log, and starts it again."""
        code = self.peer.process.poll() if self.peer.process else None
        self.peer.kill()
        log = self.out / "peer.log"
        tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-60:] if log.exists() else []
        append(self.out / "crashes.jsonl", {"t": wall_ms(), "why": why, "returncode": code, "logTail": tail})
        print(json.dumps({"crash": why, "returncode": code}), flush=True)
        time.sleep(RESTART_SECONDS)
        self.restarts += 1
        self.start_peer()

    def start_peer(self) -> None:
        """Starts the peer, and keeps trying once a minute while it will not come up."""
        while not self.stopping:
            try:
                ready = self.peer.start()
            except (TimeoutError, EOFError) as error:
                self.peer.kill()
                append(self.out / "crashes.jsonl", {"t": wall_ms(), "why": f"did not start: {error}", "returncode": None, "logTail": []})
                time.sleep(60)
                continue
            self.on_event({"event": "ready", "nodeId": ready.get("nodeId"), "restart": self.restarts})
            return

    def ask(self, **fields) -> dict | None:
        """Sends a command; a peer that has exited or does not answer counts as a crash."""
        try:
            return self.peer.command(**fields)
        except EOFError:
            self.crashed("exited")
        except TimeoutError:
            self.crashed(f"no answer to {fields.get('cmd')} in {ANSWER_SECONDS} s")
        except BrokenPipeError:
            self.crashed("its standard input closed")
        return None

    def post(self, text: str, **extra) -> None:
        sent = wall_ms()
        reply = self.ask(cmd="room", text=text)
        if reply and reply.get("ok"):
            append(self.out / "sent.jsonl", {"t": sent, "kind": "room", "id": reply["id"], "phase": self.phase(), "text": text, **extra})

    def drip(self) -> None:
        self.posts += 1
        self.post(f"soak {self.phase()} #{self.posts} peer {time.strftime('%H%M%S')}")

    def burst(self) -> list[tuple[float, str]]:
        """A burst's posts, as (when, text) pairs to send in turn."""
        self.bursts += 1
        size = random.randint(*BURST_SIZE)
        tag = f"{secrets.token_hex(2)}{self.bursts}"
        when = time.monotonic()
        schedule = []
        for index in range(1, size + 1):
            schedule.append((when, f"burst {tag} #{index}/{size}"))
            when += random.randint(*BURST_GAP)
        return schedule

    def direct_messages(self) -> None:
        """One DM to each phone in range. A phone is one the first scan heard or the peer has linked; the stale
        identities that back-fill pins are left alone."""
        pinned = {peer["peer"] for peer in (self.ask(cmd="peers") or {}).get("peers", [])}
        for phone in sorted(self.phones):
            self.dms += 1
            text = f"soak dm #{self.dms} peer {time.strftime('%H%M%S')}"
            sent = wall_ms()
            reply = self.ask(cmd="dm", to=phone, text=text)
            if reply and reply.get("ok"):
                append(
                    self.out / "sent.jsonl",
                    {
                        "t": sent, "kind": "dm", "id": reply["id"], "to": phone, "phase": self.phase(), "pinned": phone in pinned,
                        "pendingKey": reply.get("pendingKey"), "text": text,
                    },
                )

    def sample(self) -> None:
        status = self.ask(cmd="status")
        links = self.ask(cmd="links")
        digest = self.ask(cmd="digest")
        if not (status and links and digest):
            return
        self.linked = [link["peer"] for link in links.get("links", [])]
        record = {
            "t": wall_ms(),
            "phase": self.phase(),
            "links": self.linked,
            "sightings": {s["peer"]: s["rssi"] for s in links.get("sightings", [])},
            "custody": status.get("custody"),
            "fingerprint": digest.get("fingerprint"),
            "peers": status.get("peers"),
            "dropped": status.get("dropped"),
            "fileRecords": status.get("fileRecords"),
            "footprint": status.get("footprint"),
            "router": status.get("router"),
            "process": self.peer.usage(),
            "restarts": self.restarts,
            "sent": {"posts": self.posts, "bursts": self.bursts, "dms": self.dms},
        }
        append(self.out / "metrics.jsonl", record)
        temporary = self.out / "status.json.tmp"
        temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(self.out / "status.json")
        (self.out / "heartbeat").write_text(f"{int(time.time())}\n", encoding="utf-8")

    def run(self) -> int:
        (self.out / "pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        # The run keeps its own copy of the binary, so a build meanwhile changes nothing, restarts included.
        binary = self.out / "knit-peer"
        shutil.copy2(PEER, binary)
        nodes = scan(binary, self.arguments.scan_seconds)
        node_id = keygen(binary)
        self.phones = {node["peer"] for node in nodes}
        above = sorted(node["peer"] for node in nodes if node["peer"] > node_id)
        record = {"started": wall_ms(), "nodeId": node_id, "commit": git_head(), "settings": vars(self.arguments), "inRange": nodes}
        (self.out / "run.json").write_text(json.dumps(record, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
        print(json.dumps({"soak": str(self.out), "nodeId": node_id, "inRange": sorted(self.phones), "above": above}), flush=True)
        self.start_peer()
        self.started = time.monotonic()
        end = self.started + self.arguments.hours * 3600
        phase = self.phase()
        next_sample = time.monotonic()
        next_post = next_burst = next_dm = None
        pending: list[tuple[float, str]] = []
        try:
            while not self.stopping and time.monotonic() < end:
                now = time.monotonic()
                if not self.peer.alive():
                    self.crashed("exited")
                    continue
                if next_post is None or self.phase() != phase:
                    # A new phase draws its own timers; the first post waits 30 s for links to come up.
                    phase = self.phase()
                    settings = PHASES[phase]
                    next_post = now + (30 if settings["post"] else float("inf"))
                    next_burst = now + gap(settings["burst"]) * 60 if settings["burst"] else float("inf")
                    next_dm = now + settings["dm"] * 60 if settings["dm"] else float("inf")
                    print(json.dumps({"phase": phase, "at": time.strftime("%H:%M:%S")}), flush=True)
                settings = PHASES[phase]
                if now >= next_sample:
                    self.sample()
                    next_sample = now + self.arguments.sample_minutes * 60
                if now >= next_post:
                    self.drip()
                    next_post = now + gap(settings["post"])
                if now >= next_burst and not pending:
                    pending = self.burst()
                    next_burst = now + gap(settings["burst"]) * 60
                while pending and pending[0][0] <= now:
                    _, text = pending.pop(0)
                    self.post(text, burst=True)
                if now >= next_dm:
                    self.direct_messages()
                    next_dm = now + settings["dm"] * 60
                timers = [next_sample, next_post, next_burst, next_dm, end]
                if pending:
                    timers.append(pending[0][0])
                self.peer.pump(max(0.0, min(min(timers) - time.monotonic(), 30)))
            # The last posts' ticks and the last DMs' receipts.
            self.peer.pump(60)
            self.sample()
        finally:
            self.peer.stop()
        summary = report(self.out)
        (self.out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"summary": str(self.out / "summary.json"), "findings": summary["findings"]}), flush=True)
        return len(summary["findings"])


def link_endings(log: Path) -> tuple[list[dict], Counter]:
    """Why each link ended, from the peer's log: the last thing said of its channel before `link down`.

    Our side caused it when the link manager closed the channel (a bad record, a missed HELLO, an eviction) or the
    radio gave up reading. A read that fails with ETIMEDOUT is the controller's supervision timeout, which either
    end's radio can cause; the far end closing reads as an `ended` channel.

    ECONNABORTED is this host hanging up. bluetoothd removes a device it has not heard for `TemporaryTimeout` (30 s),
    connected or not, and restarts that timer with every advert (BlueZ 5.72, `device_update_last_seen`); a phone
    that rotates its private address goes quiet on the old one, and the link on it is cut 30 s later. When some
    device fell silent 29 to 32 s before the abort, that is the reason given."""
    last: dict[str, str] = {}
    endings: list[dict] = []
    reasons: Counter = Counter()
    patterns = [
        (re.compile(r"^bluez (ch\d+) read failed: errno (\d+)"), lambda m: f"read failed: {ERRNO.get(int(m[2]), m[2])}"),
        (re.compile(r"^bluez (ch\d+) write failed: errno (\d+)"), lambda m: f"write failed: {ERRNO.get(int(m[2]), m[2])}"),
        (re.compile(r"^bluez (ch\d+) ended$"), lambda _: "the phone closed it"),
        (re.compile(r"^bluez (ch\d+) stopped reading"), lambda _: "ours: stopped reading"),
        (re.compile(r"^link (ch\d+) sent a bad record: (.*)"), lambda m: f"ours: bad record ({m[2][:60]})"),
        (re.compile(r"^link (ch\d+) timed out"), lambda _: "ours: HELLO timed out"),
    ]
    down = re.compile(r"^link down (\S+) on (ch\d+)$")
    sighted = re.compile(r"^bluez (dev_\S+) changed")
    last_heard: dict[str, int] = {}
    evicting = re.compile(r"^link evicting (\S+)$")
    evicted: set[str] = set()
    for line in read_jsonl(log):
        message = line.get("message", "")
        if match := sighted.match(message):
            last_heard[match[1]] = line.get("ms", 0)
            continue
        if message.endswith("errno 103") and (match := re.match(r"^bluez (ch\d+) read failed", message)):
            now = line.get("ms", 0)
            if any(29_000 <= now - heard <= 32_000 for heard in last_heard.values()):
                last[match[1]] = "host: bluetoothd removed a device it stopped hearing"
                continue
        if match := evicting.match(message):
            evicted.add(match[1])
            continue
        if match := down.match(message):
            node, channel = match[1], match[2]
            reason = "ours: evicted" if node in evicted else last.pop(channel, "closed here (stop or refusal)")
            evicted.discard(node)
            endings.append({"ms": line.get("ms"), "peer": node, "channel": channel, "reason": reason})
            reasons[reason] += 1
            continue
        for pattern, describe in patterns:
            if match := pattern.match(message):
                last[match[1]] = describe(match)
                break
    return endings, reasons


def percentile(values: list[int], fraction: float) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def report(out: Path) -> dict:
    run = json.loads((out / "run.json").read_text(encoding="utf-8"))
    sent = read_jsonl(out / "sent.jsonl")
    events = read_jsonl(out / "events.jsonl")
    metrics = read_jsonl(out / "metrics.jsonl")
    crashes = read_jsonl(out / "crashes.jsonl")
    now = max([run["started"]] + [line["t"] for line in events + metrics + sent])
    me = run["nodeId"]
    # A post counts once it has had two minutes to be ticked.
    settle_ms = 120_000

    delivered: dict[str, int] = {}
    for event in events:
        if event.get("event") == "delivered" and event["id"] not in delivered:
            delivered[event["id"]] = event["t"]
    posts = [s for s in sent if s["kind"] == "room"]
    dms = [s for s in sent if s["kind"] == "dm"]
    due = [p for p in posts if now - p["t"] >= settle_ms]
    latencies = [delivered[p["id"]] - p["t"] for p in posts if p["id"] in delivered]

    def room(of: list[dict]) -> dict:
        ticked = [p for p in of if p["id"] in delivered]
        waits = [delivered[p["id"]] - p["t"] for p in ticked]
        settled = [p for p in of if now - p["t"] >= settle_ms]
        return {
            "sent": len(of),
            "ticked": len(ticked),
            "untickedWhenDue": len([p for p in settled if p["id"] not in delivered]),
            "latencyMs": {"p50": percentile(waits, 0.5), "p95": percentile(waits, 0.95), "max": max(waits, default=None)},
        }

    phases = {phase: room([p for p in posts if p.get("phase") == phase]) for phase in dict.fromkeys(p.get("phase") for p in posts)}
    dm_by_peer: dict[str, dict] = defaultdict(lambda: {"sent": 0, "delivered": 0, "pendingKey": 0})
    for dm in dms:
        entry = dm_by_peer[dm["to"]]
        entry["sent"] += 1
        entry["delivered"] += dm["id"] in delivered
        entry["pendingKey"] += bool(dm.get("pendingKey"))

    links: dict[str, dict] = defaultdict(lambda: {"ups": 0, "downs": 0, "upSeconds": 0.0, "longestSeconds": 0.0})
    up_since: dict[str, int] = {}
    ready_times = [e["t"] for e in events if e.get("event") == "ready"]
    for event in events:
        if event.get("event") == "ready":
            # A restarted peer starts with no links; close whatever was open.
            for node, since in list(up_since.items()):
                links[node]["upSeconds"] += (event["t"] - since) / 1000
                up_since.pop(node)
        if event.get("event") != "link":
            continue
        node = event["peer"]
        if event.get("up"):
            links[node]["ups"] += 1
            up_since[node] = event["t"]
        else:
            links[node]["downs"] += 1
            if node in up_since:
                held = (event["t"] - up_since.pop(node)) / 1000
                links[node]["upSeconds"] += held
                links[node]["longestSeconds"] = max(links[node]["longestSeconds"], held)
    for node, since in up_since.items():
        held = (now - since) / 1000
        links[node]["upSeconds"] += held
        links[node]["longestSeconds"] = max(links[node]["longestSeconds"], held)
    for entry in links.values():
        entry["upSeconds"] = round(entry["upSeconds"])
        entry["longestSeconds"] = round(entry["longestSeconds"])

    received = Counter()
    for event in events:
        if event.get("event") == "message":
            received["room" if event.get("conv") == "nearby" else "dm"] += 1
    endings, reasons = link_endings(out / "peer.log")

    def series(key: str) -> list:
        return [m[key] for m in metrics if m.get(key) is not None]

    footprints = [m["footprint"] for m in metrics if m.get("footprint")]
    usage = [m["process"] for m in metrics if m.get("process", {}).get("vmrssKb")]
    hour = [m["process"] for m in metrics if m["t"] - run["started"] >= 3_600_000 and m.get("process", {}).get("vmrssKb")]
    custody = series("custody")
    footprint = {
        key: {"max": max(f[key] for f in footprints), "last": footprints[-1][key]} for key in (footprints[0] if footprints else {})
    }
    memory = (
        {
            "rssKbFirst": usage[0]["vmrssKb"],
            "rssKbAtOneHour": hour[0]["vmrssKb"] if hour else None,
            "rssKbLast": usage[-1]["vmrssKb"],
            "rssKbPeak": max(u.get("vmhwmKb", 0) for u in usage),
            "fdsFirst": usage[0].get("fds"),
            "fdsMax": max(u.get("fds", 0) for u in usage),
            "fdsLast": usage[-1].get("fds"),
            "threadsMax": max(u.get("threads", 0) for u in usage),
            "cpuSeconds": usage[-1].get("cpuSeconds"),
        }
        if usage
        else {}
    )

    findings = []
    if crashes:
        findings.append(f"the peer crashed or hung {len(crashes)} times: {Counter(c['why'] for c in crashes).most_common()}")
    ours = {reason: count for reason, count in reasons.items() if reason.startswith("ours")}
    if ours:
        findings.append(f"our side ended links: {ours}")
    host = sum(count for reason, count in reasons.items() if reason.startswith("host"))
    if host:
        findings.append(f"bluetoothd cut {host} links when it removed a device it had stopped hearing (TemporaryTimeout)")
    if custody and max(custody) > CUSTODY_CAP:
        findings.append(f"custody reached {max(custody)}, over Android's {CUSTODY_CAP}")
    if footprint.get("seen", {}).get("max", 0) > SEEN_CAP:
        findings.append(f"the SeenSet held {footprint['seen']['max']}, over its {SEEN_CAP}")
    if due and len([p for p in due if p["id"] in delivered]) < len(due):
        missing = len([p for p in due if p["id"] not in delivered])
        findings.append(f"{missing} of {len(due)} room posts were never ticked")
    for node, entry in dm_by_peer.items():
        if entry["sent"] and not entry["delivered"]:
            findings.append(f"no DM to {node} was delivered ({entry['sent']} sent)")
    if memory.get("rssKbAtOneHour") and memory["rssKbLast"] > memory["rssKbAtOneHour"] * 1.5:
        findings.append(f"memory grew from {memory['rssKbAtOneHour']} KB at one hour to {memory['rssKbLast']} KB")
    if memory and memory["fdsLast"] > memory["fdsFirst"] + 20:
        findings.append(f"open files grew from {memory['fdsFirst']} to {memory['fdsLast']}")
    last = metrics[-1] if metrics else {}
    return {
        "run": str(out),
        "nodeId": me,
        "commit": run.get("commit"),
        "hours": round((now - run["started"]) / 3_600_000, 2),
        "restarts": len(ready_times) - 1 if ready_times else 0,
        "room": {
            "sent": len(posts),
            "ticked": len([p for p in posts if p["id"] in delivered]),
            "due": len(due),
            "tickedWhenDue": len([p for p in due if p["id"] in delivered]),
            "latencyMs": {"p50": percentile(latencies, 0.5), "p95": percentile(latencies, 0.95), "max": max(latencies, default=None)},
        },
        "roomByPhase": phases,
        "dms": dict(dm_by_peer),
        "received": dict(received),
        "links": dict(links),
        "linkEndings": dict(reasons.most_common()),
        "lastEndings": endings[-10:],
        "custody": {"max": max(custody, default=None), "last": custody[-1] if custody else None},
        "footprint": footprint,
        "router": last.get("router"),
        "dropped": last.get("dropped"),
        "fileRecords": last.get("fileRecords"),
        "linkedNow": last.get("links"),
        "memory": memory,
        "findings": findings,
    }


def status(out: Path) -> dict:
    """The latest sample, how old the heartbeat is, and whether the driver still runs."""
    latest = json.loads((out / "status.json").read_text(encoding="utf-8")) if (out / "status.json").exists() else {}
    beat = int((out / "heartbeat").read_text(encoding="utf-8")) if (out / "heartbeat").exists() else None
    pid = int((out / "pid").read_text(encoding="utf-8")) if (out / "pid").exists() else None
    running = False
    if pid:
        try:
            os.kill(pid, 0)
            running = True
        except OSError:
            pass
    return {
        "running": running,
        "heartbeatAgeSeconds": int(time.time()) - beat if beat else None,
        "phase": latest.get("phase"),
        "links": latest.get("links"),
        "custody": latest.get("custody"),
        "footprint": latest.get("footprint"),
        "process": latest.get("process"),
        "restarts": latest.get("restarts"),
        "sent": latest.get("sent"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--hours", type=float, default=10)
    run.add_argument(
        "--phases", type=parse_phases, default=parse_phases("0=shakeout 1=sparse 2=dark 9=mixed"),
        help="hours from the start at which each phase begins",
    )
    run.add_argument("--sample-minutes", type=float, default=5)
    run.add_argument("--scan-seconds", type=int, default=40)
    run.add_argument("--name", default="knit-peer soak")
    run.add_argument("--peer-log", default="debug", choices=["debug", "info"])
    # Knit advertises at medium power, and the Pixel 3's controller picks -11 dBm, so the peer hears some phones
    # near Android's -90 dBm floor. The looser floor is a development aid: it gets the links up, which is not
    # what the soak measures.
    run.add_argument("--rssi-floor", type=int, default=-100)
    run.add_argument("--out", type=Path)
    for name in ("status", "report", "stop"):
        commands.add_parser(name).add_argument("dir", type=Path, nargs="?", default=CURRENT, help="a run's directory; the latest by default")
    commands.choices["report"].add_argument("--json", action="store_true", help="print the whole report, not only the findings")
    arguments = parser.parse_args()
    if arguments.command == "status":
        print(json.dumps(status(arguments.dir), indent=2))
        return 0
    if arguments.command == "stop":
        os.kill(int((arguments.dir / "pid").read_text(encoding="utf-8")), signal.SIGTERM)
        return 0
    if arguments.command == "report":
        summary = report(arguments.dir)
        brief = ("hours", "restarts", "room", "roomByPhase", "linkEndings", "custody", "memory", "findings")
        print(json.dumps(summary if arguments.json else {k: summary[k] for k in brief}, indent=2))
        return 0
    if arguments.phases[0][0] != 0:
        parser.error("--phases must start at hour 0")
    if not PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({PEER} is missing)")
    out = (arguments.out or ROOT / ".build" / "soak" / time.strftime("%Y%m%d-%H%M")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if out.parent == CURRENT.parent:
        CURRENT.unlink(missing_ok=True)
        CURRENT.symlink_to(out.name)
    soak = Soak(out, arguments)

    def finish(*_: object) -> None:
        soak.stopping = True

    signal.signal(signal.SIGTERM, finish)
    signal.signal(signal.SIGINT, finish)
    return soak.run()


if __name__ == "__main__":
    sys.exit(main())
