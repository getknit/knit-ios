"""The profile door cap's photo and profile rules tried on air, with knit-peer lying on purpose (knit-ios ADR
2026-10.r88m; the `door-cap-lying-peers` contract, cases 1 to 5; `.agents/context/linux-peer.md`, "Lying on purpose").

One receiver per pass, the iPhone through its bridge or an Android phone through its debug bridge, and two knit-peers:
A, the liar, on dongle A with `run --lying`, and B, the honest owner of a small photo, on dongle B. The other phone is
kept off the receiver for the pass through the iPhone's `deny-link`, and both peers refuse every node but the ones a
step allows. Every case starts B on a fresh photo, so no node holds it and no earlier mark on the receiver applies.

    python3 scripts/door_cap.py --device iphone --other pixel-3.home:5559
    python3 scripts/door_cap.py --device pixel-3.home:5559 --other iphone

The cases run in the order 1, 5, 3, 4, 2: 5 needs a liar passed over as in 1; 3 needs a liar that never held the photo,
so A starts afresh; and 2 goes last, since A's own sweep declines the junk hash. Each prints one `PASS` or `FAIL` line
with its evidence, and the run writes everything to `.build/door-cap/<start>/`. It needs the maintainer's go-ahead for
both phones and both dongles (`.agents/rules/devices.md`), and P7, P8, P9 and every other Knit phone out of range.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import interop  # noqa: E402

# A size no honest photo has: over the 1 MiB ceiling (FileIntake.maxAvatarBytes) by about half.
LIED_SIZE = 1_500_000
# The junk streamed in case 2: just past the ceiling, since Android's abort leaves A's feed window silent and the
# rest then streams at the 4 KiB/s pace.
JUNK_BYTES = 1_048_576 + 65_536
# The receiver's re-offer is a minute (`reofferMilliseconds`); four of them cover three re-wants with room.
REWANT_SECONDS = 240
COUNTERS = ("profileOversizeRefused", "custodyOversizeRefused", "photosOverCeiling", "avatarsOverCeiling")


def say(what: str, **fields) -> None:
    print(json.dumps({"t": time.strftime("%H:%M:%S"), "what": what, **fields}), flush=True)


def find(value, name: str):
    """The first value under key `name` anywhere in a bridge reply."""
    if isinstance(value, dict):
        if name in value:
            return value[name]
        for inner in value.values():
            if (found := find(inner, name)) is not None:
                return found
    elif isinstance(value, list):
        for inner in value:
            if (found := find(inner, name)) is not None:
                return found
    return None


class Receiver:
    """The phone under test: its counters, its links, and what it shows for a peer."""

    # How long a peer may take to link the receiver once a step allows it. An Android phone dials the peers, whose ids
    # sort below its own, and backs off a refused dial for minutes, refused as it is while a pass keeps it off: its streak
    # reached 30 and its retry 3.5 minutes on the Pixel 3 (2026-10-31).
    link_seconds = 300

    def __init__(self, label: str) -> None:
        self.label = label
        self.node_id = ""

    def counters(self) -> dict:
        raise NotImplementedError

    def linked(self) -> set[str]:
        raise NotImplementedError

    def peer(self, node: str) -> dict | None:
        """The receiver's row for `node`: the photo shown, the one advertised and the status, or None where the bridge
        says nothing of it (Android)."""
        return None

    def log_lines(self) -> list[str]:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class IPhoneReceiver(Receiver):
    def __init__(self, ios: interop.IPhone, out: Path) -> None:
        super().__init__("iphone")
        self.ios = ios
        self.node_id = ios.node_id
        self.path = out / "iphone.log"
        self.log = interop.IPhoneLog(ios.udid, self.path)

    def counters(self) -> dict:
        status = self.ios.command(cmd="status", timeout=30)
        return {name: find(status, name) for name in COUNTERS}

    def linked(self) -> set[str]:
        reply = self.ios.command(cmd="links", timeout=30)
        return {link.get("peer") for link in reply.get("links", [])}

    def peer(self, node: str) -> dict | None:
        for row in self.ios.command(cmd="peers", timeout=30).get("peers", []):
            if row.get("peer") == node:
                return {key: row.get(key) for key in ("avatarHash", "advertisedAvatarHash", "status", "name")}
        return {}

    def log_lines(self) -> list[str]:
        return [entry["message"] for entry in interop.IPhoneLog.entries(self.path)]

    def stop(self) -> None:
        self.log.stop()


class AndroidReceiver(Receiver):
    link_seconds = 900

    def __init__(self, phone: interop.Phone, out: Path) -> None:
        super().__init__("android")
        self.phone = phone
        self.node_id = find(phone.state(), "self")["nodeId"]
        self.path = out / "logcat.txt"
        self.file = open(self.path, "a", encoding="utf-8")  # noqa: SIM115 - lives with the process
        # The whole log from now on: Android's ceiling lines come from more than one tag. `-T 1` starts at the newest
        # line rather than clearing anything.
        self.process = subprocess.Popen(
            ["adb", "-s", phone.serial, "logcat", "-v", "epoch", "-T", "1"], stdout=self.file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL
        )
        phone.wake()

        # A phone dozing with its screen off scans and advertises too seldom to link (the Pixel 3, 2026-10-30 and 31): kept
        # awake for the pass as interop.py's `--wake heal` keeps one, the screen woken and a scan nudged every half minute.
        self.awake = threading.Event()
        threading.Thread(target=self._keep_awake, daemon=True).start()

    def _keep_awake(self) -> None:
        while not self.awake.wait(30):
            try:
                self.phone.wake()
            except (RuntimeError, subprocess.TimeoutExpired, OSError):
                continue

    def counters(self) -> dict:
        metrics = find(self.phone.state(), "metrics") or {}
        return {name: metrics.get(name) for name in COUNTERS}

    def linked(self) -> set[str]:
        reachable = json.dumps(find(self.phone.state(), "reachable"))
        return {node for node in WATCHED if node in reachable}

    def log_lines(self) -> list[str]:
        return self.path.read_text(encoding="utf-8", errors="replace").splitlines()

    def stop(self) -> None:
        self.awake.set()
        if self.process.poll() is None:
            self.process.terminate()
        self.file.close()


# The peers' node ids, which an Android receiver's links are read against.
WATCHED: set[str] = set()


class Fence:
    """Which nodes each peer may link, enforced every few seconds: anything else it sights or links is refused, and a
    node allowed again is let back in. A step changes `allowed` and waits for the links to follow."""

    def __init__(self, peer: interop.Peer, name: str) -> None:
        self.peer = peer
        self.name = name
        self.allowed: set[str] = set()
        self.refused: set[str] = set(peer.refuse)
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        threading.Thread(target=self._keep, daemon=True).start()

    def allow(self, nodes: set[str]) -> None:
        with self.lock:
            self.allowed = set(nodes)
            for node in self.refused & self.allowed:
                self.peer.command(cmd="allow-link", peer=node)
            self.refused -= self.allowed
        self._enforce()

    def _enforce(self) -> None:
        try:
            reply = self.peer.command(cmd="links")
        except (TimeoutError, BrokenPipeError, ValueError, AssertionError, OSError):
            return
        near = {s["peer"] for s in reply.get("sightings", [])} | {link["peer"] for link in reply.get("links", [])}
        with self.lock:
            for node in near - self.allowed - self.refused:
                self.peer.command(cmd="deny-link", peer=node)
                self.refused.add(node)

    def _keep(self) -> None:
        while not self.stop_event.wait(3):
            if self.peer.process is not None:
                self._enforce()

    def links(self) -> set[str]:
        return {link["peer"] for link in self.peer.command(cmd="links", timeout=20).get("links", [])}

    def stop(self) -> None:
        self.stop_event.set()


class Trial:
    def __init__(self, arguments: argparse.Namespace) -> None:
        self.out = interop.ROOT / ".build" / "door-cap" / time.strftime("%Y%m%d-%H%M%S")
        self.out.mkdir(parents=True, exist_ok=True)
        self.ios = interop.IPhone(None, arguments.iphone_host)
        self.ios.start()
        android_serial = arguments.other if arguments.device == "iphone" else arguments.device
        self.android = interop.Phone(android_serial)
        self.android_id = find(self.android.state(), "self")["nodeId"]
        self.receiver: Receiver = (
            IPhoneReceiver(self.ios, self.out) if arguments.device == "iphone" else AndroidReceiver(self.android, self.out)
        )
        # Both phones are refused from each peer's `ready` line, before either side's dwell can end, and a step lets the
        # receiver in only when it means to: a fence's first sweep, three seconds in, came too late (2026-10-31).
        phones = {self.ios.node_id, self.android_id}
        # An Android receiver dials a peer whose id sorts below its own, and backs off each dial a pass refuses for minutes
        # on end, so a peer it may link only late in a case was never dialed in time (2026-10-31). Against one, A and B are
        # fresh identities above its id, so they dial it themselves the moment a step lets them.
        instances = ("doorcap-a", "doorcap-b")
        if isinstance(self.receiver, AndroidReceiver):
            instances = ("doorcap-a-above", "doorcap-b-above")
            for instance in instances:
                say("keygen", instance=instance, nodeId=interop._keygen(instance, "--above", self.receiver.node_id))
        self.a = interop.Peer(
            "android", "door-cap A", phones, "debug", None, instance=instances[0], log_path=self.out / "peer-a.log", lying=True
        )
        self.b = interop.Peer(
            "android", "door-cap B", phones, "debug", None, instance=instances[1], adapter=interop.hci0(), log_path=self.out / "peer-b.log"
        )
        self.fence_a: Fence | None = None
        self.fence_b: Fence | None = None
        self.results: list[dict] = []

    # Setting up and taking down

    def start(self) -> None:
        # The other phone stays off the receiver: the iPhone refuses the Android phone, whichever is under test.
        self.ios.command(cmd="deny-link", peer=self.android_id)
        self.start_a()
        self.b.start()
        # A runs on the photo-less profile a liar needs: a photo of its own, kept in its state from an earlier trial,
        # would be pushed to the receiver at every link-up and muddy the photo counters.
        say("A's own photo cleared", reply=self.a.command(cmd="avatar", clear=True, timeout=30))
        WATCHED.update({self.a.node_id, self.b.node_id})
        self.fence_b = Fence(self.b, "b")
        say("set up", receiver=self.receiver.label, receiverId=self.receiver.node_id, a=self.a.node_id, b=self.b.node_id, out=str(self.out))
        say("receiver links at the start", links=sorted(self.receiver.linked()))

    def start_a(self) -> None:
        if self.fence_a:
            self.fence_a.stop()
        self.a.start()
        self.fence_a = Fence(self.a, "a")

    def restart_a(self) -> None:
        """A afresh: knit-peer keeps blobs in memory, so a restarted A holds no photo it ever took."""
        self.a.stop()
        self.start_a()

    def stop(self) -> None:
        for fence in (self.fence_a, self.fence_b):
            if fence:
                fence.stop()
        for peer in (self.a, self.b):
            peer.stop()
        try:
            self.ios.command(cmd="allow-link", peer=self.android_id)
        except Exception as error:  # noqa: BLE001 - a best-effort undo, reported
            say("allow-link failed", error=str(error))
        self.receiver.stop()
        self.ios.stop()

    # Steps every case shares

    def isolate(self) -> None:
        """Nobody linked to anybody among A, B and the receiver."""
        assert self.fence_a and self.fence_b
        self.fence_a.allow(set())
        self.fence_b.allow(set())
        interop.poll(lambda: not (self.fence_a.links() | self.fence_b.links()) or None, 120, 5)

    def fresh_photo(self, case: str) -> str:
        """B takes a picture no node holds yet, and its hash."""
        jpeg = interop._noise_jpeg(f"door-cap {case} {time.time()}")
        self.b.command(cmd="avatar", jpeg=base64.b64encode(jpeg).decode(), timeout=60)
        photo = self.b.command(cmd="status")["avatarHash"]
        say("B's photo", case=case, hash=photo, bytes=len(jpeg))
        self.photo_bytes = len(jpeg)
        return photo

    def link(self, fence: Fence, node: str, timeout: float = 300) -> bool:
        try:
            interop.poll(lambda: node in fence.links() or None, timeout, 5)
            return True
        except TimeoutError:
            return False

    def a_knows_bs_photo(self, photo: str, timeout: float = 300) -> bool:
        def holds() -> bool | None:
            for row in self.a.command(cmd="peers").get("peers", []):
                if row.get("peer") == self.b.node_id and row.get("advertisedAvatarHash") == photo:
                    return True
            return None

        try:
            interop.poll(holds, timeout, 5)
            return True
        except TimeoutError:
            return False

    def lying(self) -> dict:
        return self.a.command(cmd="status").get("lying") or {}

    def asks_seen(self, peer: interop.Peer, mark: int, photo: str) -> dict:
        """What `peer` saw the receiver ask of it since `mark`: its blob query answers, the asks naming the photo, and
        A's lies told."""
        lines = peer.log_since(mark)
        receiver = self.receiver.node_id
        short = photo[:12]
        return {
            "queriesAnswered": sum(1 for line in lines if line.startswith("mesh blob has →") and receiver in line),
            # Queries naming the photo: an answer lists a held hash by its first 8 characters, as junk and the real photo
            # both are; one A does not hold is answered without it, and the lie's own line counts that one.
            "queriesForPhoto": sum(1 for line in lines if line.startswith("mesh blob has →") and receiver in line and photo[:8] in line),
            "asksForPhoto": [line for line in lines if line.startswith("mesh blobreq") and short in line and receiver in line],
            "lies": [line for line in lines if line.startswith("lying:") and (short in line or photo[:8] in line)],
        }

    def pass_over_signal(self, a_saw: dict) -> dict:
        """Which signal passed A over: its `blobhas` size claim, or the header of a stream an ask that crossed the lie made
        A send. No ask for the photo reaching A means the claim alone; with one, the receiver met both, and the counter's
        move says whether it counted them once."""
        counts = self.lying().get("counts", {})
        crossed = bool(a_saw["asksForPhoto"])
        return {
            "signal": "blobhas size claim, and a crossing stream's header after it" if crossed else "blobhas size claim alone",
            "asksForPhotoReachingA": len(a_saw["asksForPhoto"]),
            "junkHeadersWritten": counts.get("junkHeadersRewritten"),
            "blobhasLiesWritten": counts.get("blobhasRewritten"),
        }

    def passed_over_lines(self, photo: str) -> list[str]:
        return [line for line in self.receiver.log_lines() if photo[:8] in line and ("passed over" in line or "over its limit" in line or "ceiling" in line)]

    def wait_counter(self, before: dict, name: str, timeout: float) -> dict:
        try:
            return interop.poll(lambda: (now := self.receiver.counters())[name] != before[name] and now or None, timeout, 10)
        except TimeoutError:
            return self.receiver.counters()

    def face(self, node: str, photo: str, timeout: float) -> dict | None:
        """The receiver's row for `node` once it shows `photo`, or the last row read."""
        if self.receiver.label != "iphone":
            return None
        last: dict = {}

        def shows() -> dict | None:
            nonlocal last
            last = self.receiver.peer(node) or {}
            return last if last.get("avatarHash") == photo else None

        try:
            return interop.poll(shows, timeout, 10)
        except TimeoutError:
            return last

    def android_received(self, photo: str, sender: str) -> list[str]:
        if self.receiver.label != "android":
            return []
        return [line for line in self.receiver.log_lines() if photo[:12] in line and sender in line]

    def record(self, case: str, passed: bool, **evidence) -> None:
        result = {"case": case, "receiver": self.receiver.label, "result": "PASS" if passed else "FAIL", **evidence}
        self.results.append(result)
        print(("PASS " if passed else "FAIL ") + json.dumps(result), flush=True)

    # The cases

    def stage_liar(self, case: str, junk: bool = False) -> tuple[str, dict]:
        """Cases 1, 2 and 5 up to the pass-over: B on a fresh photo, A holding it (or junk under it), A lying, and A
        alone on the receiver. Answers the photo and the counters from before A linked the receiver."""
        assert self.fence_a and self.fence_b
        self.isolate()
        photo = self.fresh_photo(case)
        # Junk under the photo before A links B, so A never holds a servable copy (the contract's "without holding H"):
        # its engine counts the hash held, never asks anyone for it, and an ask that crosses a lie on air gets junk, never
        # the real bytes (2026-10-31, the first pass's case 1). Cases 1 and 5 claim the lied size and declare it in the
        # header, which the receiver cuts; case 2 claims the photo's real size and streams junk past the ceiling with a
        # header that declares no size, so the cut lands on a chunk.
        if junk:
            say("junk", reply=self.a.command(cmd="junk", hash=photo, bytes=JUNK_BYTES))
            say("lie-blobhas", reply=self.a.command(cmd="lie-blobhas", hash=photo, size=self.photo_bytes))
        else:
            say("junk", reply=self.a.command(cmd="junk", hash=photo, bytes=LIED_SIZE, declare=LIED_SIZE))
        self.fence_a.allow({self.b.node_id})
        self.fence_b.allow({self.a.node_id})
        if not self.link(self.fence_a, self.b.node_id):
            raise RuntimeError("A and B never linked")
        # A must have B's profile naming the photo before it links the receiver, or the receiver never learns of it.
        if not self.a_knows_bs_photo(photo):
            raise RuntimeError("A never took B's profile naming the photo")
        before = self.receiver.counters()
        self.fence_a.allow({self.b.node_id, self.receiver.node_id})
        if not self.link(self.fence_a, self.receiver.node_id, self.receiver.link_seconds):
            raise RuntimeError("A never linked the receiver")
        return photo, before

    def finish_with_b(self, photo: str, timeout: float = 420) -> dict:
        """B on the receiver: the photo must come from B and show as B's face."""
        assert self.fence_b
        mark_b = self.b.log_mark()
        self.fence_b.allow({self.a.node_id, self.receiver.node_id})
        linked = self.link(self.fence_b, self.receiver.node_id, self.receiver.link_seconds)
        face = self.face(self.b.node_id, photo, timeout) if linked else None
        if self.receiver.label == "android" and linked:
            try:
                interop.poll(lambda: self.android_received(photo, self.b.node_id) or None, timeout, 10)
            except TimeoutError:
                pass
        return {
            "bLinked": linked,
            "bFace": face,
            "androidLinesFromB": self.android_received(photo, self.b.node_id)[-5:],
            "bSaw": self.asks_seen(self.b, mark_b, photo),
        }

    def case_1(self) -> None:
        photo, before = self.stage_liar("case 1")
        mark = self.a.log_mark()
        passed_over = self.wait_counter(before, "photosOverCeiling", 300)
        # "Never asked again" counts from the pass-over on: an ask that crossed the lie on air, sent before its answer
        # landed (a blind ask after the receiver's query wait), is evidence of the race, not of a re-ask (2026-10-31).
        after_mark = self.a.log_mark()
        rewritten = self.lying().get("counts", {}).get("blobhasRewritten")
        time.sleep(REWANT_SECONDS)
        after_rewants = self.receiver.counters()
        rewritten_after = self.lying().get("counts", {}).get("blobhasRewritten")
        a_saw = self.asks_seen(self.a, mark, photo)
        a_after = self.asks_seen(self.a, after_mark, photo)
        signal = self.pass_over_signal(a_saw)
        b = self.finish_with_b(photo)
        after = self.receiver.counters()
        a_links = self.fence_a.links() if self.fence_a else set()
        self.a.command(cmd="junk", hash=photo, clear=True)
        once = (passed_over["photosOverCeiling"] or 0) - (before["photosOverCeiling"] or 0) == 1
        quiet = (
            rewritten == rewritten_after
            and not a_after["asksForPhoto"]
            and not a_after["queriesForPhoto"]
            and after_rewants["photosOverCeiling"] == passed_over["photosOverCeiling"]
        )
        shown = b["bLinked"] and (b["bFace"] is None or (b["bFace"] or {}).get("avatarHash") == photo)
        held = self.receiver.node_id in a_links
        self.record(
            "1 lying size",
            once and quiet and shown and held,
            note="A holds junk under the photo at the lied size, never the real bytes, so its blobhas claims that size",
            photo=photo,
            before=before,
            afterPassOver=passed_over,
            after=after,
            passedOverOnce=once,
            passOver=signal,
            neverAskedAgain=quiet,
            aSawAfterPassOver=a_after,
            fromB=shown,
            linkToAHeld=held,
            aSaw=a_saw,
            lies=self.lying(),
            receiverLines=self.passed_over_lines(photo)[-10:],
            **b,
        )

    def case_5(self) -> None:
        photo, before = self.stage_liar("case 5")
        passed_over = self.wait_counter(before, "photosOverCeiling", 300)
        mark = self.a.log_mark()
        rewritten = self.lying().get("counts", {}).get("blobhasRewritten")
        asks_before = self.lying().get("counts", {}).get("blobAsksSent", {}).get(self.receiver.node_id, 0)
        ask = self.a.command(cmd="ask-blob", hash=photo, peer=self.receiver.node_id)
        say("ask-blob", reply=ask)
        time.sleep(REWANT_SECONDS)
        a_saw = self.asks_seen(self.a, mark, photo)
        signal = self.pass_over_signal(a_saw)
        rewritten_after = self.lying().get("counts", {}).get("blobhasRewritten")
        after_ask = self.receiver.counters()
        # The reply's `sent` says the ask was queued; the count says it went out on a ready link.
        asks_sent = self.lying().get("counts", {}).get("blobAsksSent", {}).get(self.receiver.node_id, 0) - asks_before
        b = self.finish_with_b(photo)
        self.a.command(cmd="junk", hash=photo, clear=True)
        kept = rewritten == rewritten_after and not a_saw["asksForPhoto"]
        self.record(
            "5 passed-over liar asks",
            asks_sent == 1 and kept,
            expected="PASS on both: knit-ios main with ios-photo-ask-ceiling keeps the ceiling on an ask, as Android does; 54ba068 failed it",
            photo=photo,
            before=before,
            afterPassOver=passed_over,
            afterAsk=after_ask,
            passOver=signal,
            askQueued=ask.get("sent"),
            asksWritten=asks_sent,
            blobhasRewrittenBefore=rewritten,
            blobhasRewrittenAfter=rewritten_after,
            aSaw=a_saw,
            receiverLines=self.passed_over_lines(photo)[-10:],
            **b,
        )

    def case_3(self) -> None:
        assert self.fence_b
        self.isolate()
        self.restart_a()
        assert self.fence_a
        photo = self.fresh_photo("case 3")
        say("advertise-photo", reply=self.a.command(cmd="advertise-photo", hash=photo))
        say("lie-blobhas", reply=self.a.command(cmd="lie-blobhas", hash=photo, size=LIED_SIZE))
        before = self.receiver.counters()
        mark = self.a.log_mark()
        self.fence_a.allow({self.receiver.node_id})
        if not self.link(self.fence_a, self.receiver.node_id, self.receiver.link_seconds):
            raise RuntimeError("A never linked the receiver")
        passed_over = self.wait_counter(before, "photosOverCeiling", 300)
        after_mark = self.a.log_mark()
        time.sleep(REWANT_SECONDS)
        a_saw = self.asks_seen(self.a, mark, photo)
        a_after = self.asks_seen(self.a, after_mark, photo)
        b = self.finish_with_b(photo)
        a_row = self.receiver.peer(self.a.node_id)
        lies = self.lying()
        after = self.receiver.counters()
        self.a.command(cmd="advertise-photo", clear=True)
        self.a.command(cmd="lie-blobhas", hash=photo, clear=True)
        once = (passed_over["photosOverCeiling"] or 0) - (before["photosOverCeiling"] or 0) == 1
        pushed = lies.get("counts", {}).get("advertisedPhotoPushed")
        shown = b["bLinked"] and (b["bFace"] is None or (b["bFace"] or {}).get("avatarHash") == photo)
        self.record(
            "3 fake advertiser",
            once and not a_after["asksForPhoto"] and shown and not pushed,
            photo=photo,
            before=before,
            afterPassOver=passed_over,
            after=after,
            passedOverOnce=once,
            advertisedPhotoPushed=pushed,
            aSawAfterPassOver=a_after,
            aRowOnceHeld=a_row,
            aSaw=a_saw,
            receiverLines=self.passed_over_lines(photo)[-10:],
            **b,
        )

    def case_4(self) -> None:
        assert self.fence_a and self.fence_b
        self.isolate()
        self.fence_a.allow({self.receiver.node_id})
        if not self.link(self.fence_a, self.receiver.node_id, self.receiver.link_seconds):
            raise RuntimeError("A never linked the receiver")
        row_before = self.receiver.peer(self.a.node_id)
        before = self.receiver.counters()
        over = self.a.command(cmd="pad-profile", signedBytes=8193, timeout=30)
        say("pad-profile 8193", reply=over)
        after_over = self.wait_counter(before, "profileOversizeRefused", 120)
        row_over = self.receiver.peer(self.a.node_id)
        written_over = self.lying().get("counts", {}).get("forgedProfilesWritten", {}).get(self.receiver.node_id)
        self.a.command(cmd="pad-profile", clear=True, timeout=30)
        time.sleep(20)
        at_cap = self.a.command(cmd="pad-profile", signedBytes=8192, timeout=30)
        say("pad-profile 8192", reply=at_cap)
        time.sleep(60)
        row_at_cap = self.receiver.peer(self.a.node_id)
        after_at_cap = self.receiver.counters()
        self.a.command(cmd="pad-profile", clear=True, timeout=30)
        time.sleep(60)
        row_after = self.receiver.peer(self.a.node_id)
        after = self.receiver.counters()
        held = self.receiver.node_id in self.fence_a.links()
        refused = (after_over["profileOversizeRefused"] or 0) - (before["profileOversizeRefused"] or 0)
        pinned = (
            after_at_cap["profileOversizeRefused"] == after_over["profileOversizeRefused"]
            if row_at_cap is None
            else (row_at_cap.get("status") or "") != (row_before or {}).get("status")
        )
        unchanged_by_over = row_over is None or row_over == row_before
        self.record(
            "4 over-cap profile",
            bool(over.get("ok")) and bool(at_cap.get("ok")) and refused >= 1 and unchanged_by_over and pinned and held,
            before=before,
            afterOverCap=after_over,
            afterAtCap=after_at_cap,
            after=after,
            refusedCount=refused,
            forgedWrittenToReceiver=written_over,
            rowBefore=row_before,
            rowAfterOverCap=row_over,
            rowAtCap=row_at_cap,
            rowAfterClear=row_after,
            linkToAHeld=held,
            note="Android shows no peer row: a pin there is read as the counter not moving for 8,192",
        )

    def case_2(self) -> None:
        photo, before = self.stage_liar("case 2", junk=True)
        mark = self.a.log_mark()
        passed_over = self.wait_counter(before, "photosOverCeiling", 420)
        after_mark = self.a.log_mark()
        time.sleep(REWANT_SECONDS)
        a_saw = self.asks_seen(self.a, mark, photo)
        a_after = self.asks_seen(self.a, after_mark, photo)
        lies = self.lying()
        b = self.finish_with_b(photo)
        after = self.receiver.counters()
        held = self.receiver.node_id in (self.fence_a.links() if self.fence_a else set())
        self.a.command(cmd="junk", hash=photo, clear=True)
        self.a.command(cmd="lie-blobhas", hash=photo, clear=True)
        once = (passed_over["photosOverCeiling"] or 0) - (before["photosOverCeiling"] or 0) == 1
        served = lies.get("counts", {}).get("junkBytesServed") or 0
        shown = b["bLinked"] and (b["bFace"] is None or (b["bFace"] or {}).get("avatarHash") == photo)
        self.record(
            "2 junk under the hash",
            once and served > 0 and not a_after["asksForPhoto"] and shown and held,
            photo=photo,
            before=before,
            afterPassOver=passed_over,
            after=after,
            passedOverOnce=once,
            junkBytesServed=served,
            aSawAfterPassOver=a_after,
            junkHeadersRewritten=lies.get("counts", {}).get("junkHeadersRewritten"),
            linkToAHeld=held,
            aSaw=a_saw,
            receiverLines=self.passed_over_lines(photo)[-10:],
            **b,
        )


CASES = {"1": "case_1", "5": "case_5", "3": "case_3", "4": "case_4", "2": "case_2"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", required=True, help="the receiver: `iphone`, or an approved Android phone's adb serial")
    parser.add_argument("--other", required=True, help="the other phone, kept off the receiver: `iphone` or an adb serial")
    parser.add_argument("--iphone-host", default=None, help="reach the iPhone's bridge over Wi-Fi at this address")
    parser.add_argument("--cases", default="1,5,3,4,2", help="which cases to run, in this order")
    arguments = parser.parse_args()
    if "iphone" not in (arguments.device, arguments.other) or arguments.device == arguments.other:
        parser.error("one of --device and --other is `iphone`, and the other an adb serial")
    if not interop.PEER.exists():
        sys.exit(f"build knit-peer first: swift build --product knit-peer ({interop.PEER} is missing)")
    trial = Trial(arguments)
    try:
        trial.start()
        for case in arguments.cases.split(","):
            try:
                getattr(trial, CASES[case.strip()])()
            except (RuntimeError, TimeoutError) as error:
                trial.record(case.strip(), False, error=str(error))
    finally:
        trial.stop()
        (trial.out / "results.json").write_text(json.dumps(trial.results, indent=2) + "\n")
    failed = [result["case"] for result in trial.results if result["result"] == "FAIL"]
    say("done", failed=failed, out=str(trial.out))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
