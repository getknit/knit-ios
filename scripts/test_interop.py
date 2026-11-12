"""Tests for interop.py's pure parts: the parsers that read a resumed photo's lines on Android and the iPhone, the checks
built on them, and the noise picture's size. Run anywhere with `python3 -m unittest discover -s scripts -p 'test_*.py'`,
as `scripts/check.sh scripts` does: nothing here touches a phone, an adapter or adb, and the picture's test skips
without Pillow."""

from __future__ import annotations

import ast
import collections
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import interop  # noqa: E402

# A photo's blob, the iPhone and an Android phone, shaped as the lines print them: 64 lowercase hex characters, and
# node ids of 26 base32 characters.
HASH = "82c382d1" + "3f" * 28
H12 = HASH[:12]
IPHONE = "dlrr2hznq7xk4mbvw3cfeta5ue"
PHONE = "24sd5jd4ojw6rkhnm2qyx7vb3a"


class AndroidReceiveLinesTest(unittest.TestCase):
    def test_a_whole_start_declares_the_whole(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} 701744B ← {IPHONE}")
        self.assertEqual(
            rx and (rx["phase"], rx["kind"], rx["hash"], rx["bytes"], rx["peer"], rx["offset"]), ("start", "ATTACHMENT", HASH, 701744, IPHONE, 0)
        )

    def test_a_start_without_a_size_reads_as_none(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} ?B ← {IPHONE}")
        self.assertEqual(rx and (rx["phase"], rx["bytes"], rx["offset"]), ("start", None, 0))

    def test_a_resumed_start_declares_the_tail_and_its_offset(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} 668948B ← {IPHONE} from 32768")
        self.assertEqual(rx and (rx["phase"], rx["bytes"], rx["peer"], rx["offset"]), ("start", 668948, IPHONE, 32768))

    def test_a_whole_end(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} 701744B in 23335ms ← {IPHONE}")
        self.assertEqual(rx and (rx["phase"], rx["bytes"], rx["ms"], rx["peer"], rx["offset"]), ("end", 701744, 23335, IPHONE, 0))

    def test_a_resumed_end_counts_the_tail_on_air(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} 668948B in 60012ms ← {IPHONE} from 32768")
        self.assertEqual(rx and (rx["phase"], rx["bytes"], rx["ms"], rx["peer"], rx["offset"]), ("end", 668948, 60012, IPHONE, 32768))

    def test_a_refused_resume_keeps_its_reason(self) -> None:
        rx = interop.parse_android_rx(f"rx ATTACHMENT/{HASH} refused ← {IPHONE} from 32768: resumed 1200ms ago")
        self.assertEqual(rx and (rx["phase"], rx["offset"], rx["reason"], rx["bytes"]), ("refused", 32768, "resumed 1200ms ago", None))

    def test_an_avatar_keeps_its_kind(self) -> None:
        rx = interop.parse_android_rx(f"rx AVATAR/{HASH} 41000B in 900ms ← {IPHONE}")
        self.assertEqual(rx and rx["kind"], "AVATAR")

    def test_other_lines_are_none(self) -> None:
        for line in (
            f"bt link up: {IPHONE} (client)",
            f"file ATTACHMENT/{HASH} 668948B in 23335ms @28672 → {IPHONE}",
            f"rx ATTACHMENT/{H12} 701744B ← {IPHONE}",
            f"rx ATTACHMENT/<bad key> 701744B ← {IPHONE}",
        ):
            self.assertIsNone(interop.parse_android_rx(line), line)


class AndroidHolderLinesTest(unittest.TestCase):
    def test_a_whole_serve(self) -> None:
        sent = interop.parse_android_file_sent(f"file ATTACHMENT/{HASH} 701744B in 23335ms @28672 → {IPHONE}")
        self.assertEqual(
            sent and (sent["hash"], sent["bytes"], sent["ms"], sent["rate"], sent["node"], sent["offset"], sent["windowed"]),
            (HASH, 701744, 23335, 28672, IPHONE, 0, False),
        )

    def test_a_resumed_serve_names_its_offset(self) -> None:
        sent = interop.parse_android_file_sent(f"file ATTACHMENT/{HASH} 668948B in 23335ms @28672 → {IPHONE} from 32768")
        self.assertEqual(sent and (sent["bytes"], sent["offset"], sent["windowed"]), (668948, 32768, False))

    def test_a_windowed_feed_says_so_after_the_offset(self) -> None:
        sent = interop.parse_android_file_sent(f"file ATTACHMENT/{HASH} 668948B in 23335ms @31000 → {IPHONE} from 32768 window")
        self.assertEqual(sent and (sent["rate"], sent["offset"], sent["windowed"]), (31000, 32768, True))
        whole = interop.parse_android_file_sent(f"file ATTACHMENT/{HASH} 701744B in 23335ms @0 → {IPHONE} window")
        self.assertEqual(whole and (whole["rate"], whole["offset"], whole["windowed"]), (0, 0, True))

    def test_a_receive_line_is_none(self) -> None:
        self.assertIsNone(interop.parse_android_file_sent(f"rx ATTACHMENT/{HASH} 701744B in 23335ms ← {IPHONE}"))


class KeptPrefixLinesTest(unittest.TestCase):
    def test_both_stores_keep_in_the_same_words(self) -> None:
        android = interop.parse_partial(f"partial {H12} kept 32768B")
        iphone = interop.parse_partial(f"mesh partial {H12} kept 32768B")
        self.assertEqual(android, {"hash": H12, "event": "kept", "bytes": 32768})
        self.assertEqual(iphone, android)

    def test_the_other_events(self) -> None:
        for words, event in (("dropped", "dropped"), ("evicted", "evicted"), ("stale, not kept", "stale")):
            line = interop.parse_partial(f"partial {H12} {words}")
            self.assertEqual(line, {"hash": H12, "event": event, "bytes": None}, words)

    def test_a_hash_of_another_width_is_none(self) -> None:
        self.assertIsNone(interop.parse_partial(f"partial {HASH} kept 32768B"))
        self.assertIsNone(interop.parse_partial(f"partial {H12[:8]} kept 32768B"))

    def test_the_last_kept_line_of_the_photo_wins(self) -> None:
        other = "ab" * 32
        messages = [f"partial {H12} kept 16384B", f"partial {other[:12]} kept 99999B", f"mesh partial {H12} kept 32768B", "bt state"]
        self.assertEqual(interop._kept_in(messages, HASH), 32768)
        self.assertIsNone(interop._kept_in(messages[3:], HASH))


class IPhoneFileLinesTest(unittest.TestCase):
    def test_a_resumed_arrival_names_the_tail_and_its_offset(self) -> None:
        line = interop.parse_ios_file(f"link file ATTACHMENT {H12} from {PHONE}: 668948 bytes resumed at 32768")
        self.assertEqual(line and (line["direction"], line["hash"], line["peer"], line["bytes"], line["offset"]), ("in", H12, PHONE, 668948, 32768))

    def test_a_whole_arrival(self) -> None:
        line = interop.parse_ios_file(f"link file ATTACHMENT {H12} from {PHONE}: 701744 bytes")
        self.assertEqual(line and (line["direction"], line["bytes"], line["offset"]), ("in", 701744, 0))

    def test_a_resumed_windowed_send(self) -> None:
        line = interop.parse_ios_file(f"link file ATTACHMENT {H12} to {PHONE}: 668948 bytes in 23335 ms @28672 window resumed at 32768")
        self.assertEqual(
            line and (line["direction"], line["peer"], line["bytes"], line["ms"], line["rate"], line["windowed"], line["offset"]),
            ("out", PHONE, 668948, 23335, 28672, True, 32768),
        )

    def test_a_send_at_a_pace_or_at_no_rate(self) -> None:
        paced = interop.parse_ios_file(f"link file ATTACHMENT {H12} to {PHONE}: 701744 bytes in 23335 ms @20000")
        self.assertEqual(paced and (paced["rate"], paced["windowed"], paced["offset"]), (20000, False, 0))
        bare = interop.parse_ios_file(f"link file ATTACHMENT {H12} to {PHONE}: 668948 bytes in 23335 ms resumed at 32768")
        self.assertEqual(bare and (bare["rate"], bare["windowed"], bare["offset"]), (None, False, 32768))

    def test_the_intakes_own_lines_are_none(self) -> None:
        for line in (
            f"link 7 file {H12} resumed at 32768",
            f"link 7 file {H12} refused resumed at 32768: resumed 1200ms ago",
            f"mesh partial {H12} kept 32768B",
        ):
            self.assertIsNone(interop.parse_ios_file(line), line)

    def test_lines_are_picked_by_direction_hash_and_peer(self) -> None:
        messages = [
            f"link file ATTACHMENT {H12} to {PHONE}: 701744 bytes in 20000 ms @28672",
            f"link file ATTACHMENT {H12} to {IPHONE}: 701744 bytes in 20000 ms @28672",
            f"link file ATTACHMENT {'ab' * 6} to {PHONE}: 1 bytes in 1 ms",
            f"link file ATTACHMENT {H12} to {PHONE}: 668948 bytes in 23335 ms @28672 resumed at 32768",
            f"link file ATTACHMENT {H12} from {PHONE}: 701744 bytes",
        ]
        picked = interop._ios_file_lines(messages, "out", HASH, PHONE)
        self.assertEqual([line["offset"] for line in picked], [0, 32768])


class SizesTest(unittest.TestCase):
    def test_the_prefix_and_the_tail_make_the_whole(self) -> None:
        self.assertEqual(interop._sizes_add_up(32768, 668948, 701716, "a test")["whole"], 701716)

    def test_a_mismatch_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            interop._sizes_add_up(32768, 668948, 701744, "a test")

    def test_no_whole_passes_with_a_note(self) -> None:
        self.assertIn("note", interop._sizes_add_up(32768, 668948, None, "a test"))


class FakePhone:
    """Answers `logcat -d` with the lines given, as `adb shell` prints them in logcat's threadtime form."""

    def __init__(self, messages: list[str]) -> None:
        self.serial = "fake"
        self.messages = messages

    def shell(self, command: str, timeout: float = 30) -> str:
        tag = command.split("-s ", 1)[1].split(":", 1)[0]
        lines = ["--------- beginning of main"]
        lines += [f"10-25 14:03:07.123  4321  4400 D {tag}: {message}" for message in self.messages]
        return "\n".join(lines) + "\n"


class WholeFileChecksTest(unittest.TestCase):
    def test_a_whole_end_line_passes(self) -> None:
        phone = FakePhone([f"rx ATTACHMENT/{HASH} 701744B ← {IPHONE}", f"rx ATTACHMENT/{HASH} 701744B in 23335ms ← {IPHONE}"])
        self.assertEqual(interop._phone_got_file(phone, HASH, IPHONE), {"kind": "ATTACHMENT", "bytes": 701744, "ms": 23335})

    def test_a_resumed_end_line_is_resumed_not_whole(self) -> None:
        phone = FakePhone([f"rx ATTACHMENT/{HASH} 668948B in 60012ms ← {IPHONE} from 32768"])
        with self.assertRaisesRegex(RuntimeError, "resumed, not whole"):
            interop._phone_got_file(phone, HASH, IPHONE)

    def test_another_senders_line_is_not_the_one(self) -> None:
        phone = FakePhone([f"rx ATTACHMENT/{HASH} 701744B in 23335ms ← {PHONE}"])
        self.assertIsNone(interop._phone_got_file(phone, HASH, IPHONE))

    def test_resumed_counts_are_read_against_the_start(self) -> None:
        before = {"sent": 1, "resumedOut": 0, "resumedIn": 2}
        self.assertEqual(interop._resumed_since({"sent": 3, "resumedOut": 1, "resumedIn": 2}, before, "resumedOut"), 1)
        self.assertEqual(interop._resumed_since({"sent": 3}, {}, "resumedIn"), 0)


FAR = "kdlj2wquj6kcfzo6ykciiyuviy"
GROUP = "g-cb9d8ca1db033848ec74d40f"


class FakeNode:
    """Answers a node's `custody`, `groups` and `ratchet` control commands with one carried frame, one group and a
    `groupSeedsSent` count, as `ControlLines` shapes them."""

    def __init__(self, frame: dict, members: list[str], seeds: int = 0) -> None:
        self.node_id = IPHONE
        self.frame = {"id": "m1", "type": "chat", "from": IPHONE, "group": GROUP, **frame}
        self.members = members
        self.seeds = seeds

    def command(self, **command: str) -> dict:
        return {
            "custody": {"frames": [self.frame]},
            "groups": {"groups": [{"id": GROUP, "members": self.members, "departed": []}]},
            "ratchet": {"groups": {"groupSeedsSent": self.seeds}},
        }[command["cmd"]]


class SealedToTest(unittest.TestCase):
    def test_a_v1_frame_is_read_by_its_wrapped_keys(self) -> None:
        node = FakeNode({"v": 1, "groupForm": False, "wrappedTo": [PHONE, FAR]}, [IPHONE, PHONE, FAR])
        self.assertEqual(interop._sealed_to(node, "m1", {PHONE, FAR}), {"wrappedTo": 2})
        with self.assertRaisesRegex(RuntimeError, "wrapped to"):
            interop._sealed_to(node, "m1", {PHONE})

    def test_a_group_form_frame_is_read_by_the_roster_and_the_seeds_since(self) -> None:
        node = FakeNode({"v": 2, "groupForm": True, "wrappedTo": []}, [IPHONE, PHONE, FAR], seeds=6)
        self.assertEqual(interop._sealed_to(node, "m1", {PHONE, FAR}, 4), {"groupForm": True, "roster": 2, "seeds": 2})
        self.assertEqual(interop._sealed_to(node, "m1", {PHONE, FAR}), {"groupForm": True, "roster": 2})
        with self.assertRaisesRegex(RuntimeError, "1 seeds sent since, not 2"):
            interop._sealed_to(node, "m1", {PHONE, FAR}, 5)

    def test_a_group_form_frame_under_another_roster_or_with_a_wrap_fails(self) -> None:
        after_a_leave = FakeNode({"v": 2, "groupForm": True, "wrappedTo": []}, [IPHONE, PHONE, FAR])
        with self.assertRaisesRegex(RuntimeError, "under roster"):
            interop._sealed_to(after_a_leave, "m1", {PHONE})
        wrapped = FakeNode({"v": 2, "groupForm": True, "wrappedTo": [PHONE]}, [IPHONE, PHONE])
        with self.assertRaisesRegex(RuntimeError, "group form wrapped to"):
            interop._sealed_to(wrapped, "m1", {PHONE})


class RunTest(unittest.TestCase):
    def test_an_inconclusive_step_is_no_failure(self) -> None:
        run = interop.Run()
        out = io.StringIO()
        stdout, sys.stdout = sys.stdout, out
        try:

            def no_cut() -> dict:
                raise interop.Inconclusive("no cut: nothing kept")

            self.assertIsNone(run.step("kept", no_cut))
            self.assertIsNone(run.step("broken", lambda: interop._fail("broken")))
        finally:
            sys.stdout = stdout
        self.assertEqual((run.steps, run.failed, run.inconclusive), (2, 1, 1))
        self.assertEqual((run.results[0]["ok"], run.results[0]["inconclusive"], run.results[0]["reason"]), (None, True, "no cut: nothing kept"))
        self.assertIs(run.results[1]["ok"], False)


class FakeAdvertPhone:
    """A phone's `ADVERT` bridge action: `replies` answers each call in turn, and `calls` keeps the extras each sent."""

    def __init__(self, serial: str, replies: list[dict | None]) -> None:
        self.serial = serial
        self.replies = replies
        self.calls: list[dict] = []

    def advert(self, **extras: bool) -> dict | None:
        self.calls.append(extras)
        return self.replies.pop(0)


def advert(stored: bool | None, blinding: bool) -> dict:
    """An `ADVERT` read, as knit-next's `DebugBridgeReceiver` shapes the fields the guard reads."""
    return {"switch": {"value": blinding, "stored": stored}, "blinding": blinding, "form": "tag" if blinding else "clear"}


class AdvertReadTest(unittest.TestCase):
    def phone(self, error: str) -> interop.Phone:
        phone = interop.Phone("p9")
        phone.bridge = mock.Mock(side_effect=RuntimeError(error))
        return phone

    def test_a_build_without_the_action_reads_as_none_and_a_silent_phone_raises(self) -> None:
        old_build = "no bridge reply to ADVERT: Broadcasting: Intent { … }\nBroadcast completed: result=0"
        self.assertIsNone(self.phone(old_build).advert())
        with self.assertRaises(RuntimeError):
            self.phone("no bridge reply to ADVERT: ").advert()


class ClearAdvertsTest(unittest.TestCase):
    def run_guard(self, phones: list[FakeAdvertPhone], body=None, keep: bool = False) -> None:
        quiet = contextlib.redirect_stdout(io.StringIO())
        with quiet, mock.patch.object(interop.time, "sleep"), interop.ClearAdverts(phones, keep=keep):
            if body:
                body()

    def test_a_default_switch_goes_off_for_the_run_and_back_to_the_default(self) -> None:
        phone = FakeAdvertPhone("p9", [advert(None, True), {"applied": True}, {"applied": True}])
        self.run_guard([phone])
        self.assertEqual(phone.calls, [{}, {"blind": False}, {"clear": True}])

    def test_a_switch_stored_on_is_stored_on_again(self) -> None:
        phone = FakeAdvertPhone("p9", [advert(True, True), {"applied": True}, {"applied": True}])
        self.run_guard([phone])
        self.assertEqual(phone.calls[-1], {"blind": True})

    def test_a_switch_already_off_and_a_build_without_the_action_are_left_alone(self) -> None:
        off = FakeAdvertPhone("p3", [advert(False, False)])
        old = FakeAdvertPhone("p7", [None])
        self.run_guard([off, old])
        self.assertEqual(off.calls, [{}])
        self.assertEqual(old.calls, [{}])

    def test_a_failing_run_still_puts_the_switch_back(self) -> None:
        phone = FakeAdvertPhone("p9", [advert(None, True), {"applied": True}, {"applied": True}])

        def fails() -> None:
            raise RuntimeError("a step blew up")

        with self.assertRaises(RuntimeError):
            self.run_guard([phone], fails)
        self.assertEqual(phone.calls[-1], {"clear": True})

    def test_a_phone_that_will_not_go_clear_ends_the_run_with_the_earlier_phones_put_back(self) -> None:
        first = FakeAdvertPhone("p8", [advert(None, True), {"applied": True}, {"applied": True}])
        timeout = {"applied": False, "why": "timeout"}
        stuck = FakeAdvertPhone("p9", [advert(None, True), timeout, timeout, {"applied": True}])
        with self.assertRaises(RuntimeError):
            self.run_guard([first, stuck])
        self.assertEqual(first.calls[-1], {"clear": True})
        self.assertEqual(stuck.calls[-1], {"clear": True})

    def test_a_pending_rotation_is_waited_out_once_and_a_stopped_transport_only_stores(self) -> None:
        held = {"applied": False, "why": "pending"}
        pending = FakeAdvertPhone("p8", [advert(None, True), held, {"applied": True}, {"applied": True}])
        stopped = FakeAdvertPhone("p9", [advert(None, True), {"applied": False, "why": "transport not running"}, {"applied": True}])
        self.run_guard([pending, stopped])
        self.assertEqual(pending.calls, [{}, {"blind": False}, {"blind": False}, {"clear": True}])
        self.assertEqual(stopped.calls, [{}, {"blind": False}, {"clear": True}])

    def test_keep_blind_reads_nothing_and_changes_nothing(self) -> None:
        phone = FakeAdvertPhone("p9", [])
        self.run_guard([phone], keep=True)
        self.assertEqual(phone.calls, [])


class FakeKnitLog:
    """Knit's log over USB as `IPhoneLog` leaves it: a file of JSON lines, each with its wall-clock `ms`."""

    def __init__(self, messages: list[str], ago: float = 0) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "knit.log"
        ms = int((time.time() - ago) * 1000)
        self.path.write_text("".join(f'syslog: {{"ms": {ms}, "message": "{line}"}}\n' for line in messages))
        self.file = mock.Mock()

    def close(self) -> None:
        self.directory.cleanup()


class BlindDialedByTest(unittest.TestCase):
    """`iphone --keep-blind`'s dialer check, read off a blinding phone's `ADVERT` and its log, and the iPhone's own log."""

    ios = mock.Mock(node_id=IPHONE)
    refused = f"bt refused client {IPHONE} (sighted=true codedOnly=false heldAgeMs=null atCap=false blind=legacy)"
    accepted = f"bt accepted client {IPHONE} (sighted=true)"
    proved = f"link ~zzzz…7 proved {PHONE} on ch12"

    def judge(self, reply: dict, lines: list[str], reader: bool = False, knit: list[str] | None = None, ago: float = 0) -> dict:
        phone = FakeAdvertPhone("p9", [reply])
        log = FakeKnitLog(knit, ago=ago) if knit is not None else None
        if log:
            self.addCleanup(log.close)
        with mock.patch.object(interop, "_phone_lines", return_value=lines):
            return interop._blind_dialed_by(phone, self.ios, phone_id=PHONE, knit=log, since=time.time() - 60, reader=reader)

    def blinding(self, i_dial: bool, dialed_by_me: bool, tag_aware: bool = False) -> dict:
        return {
            "blinding": True,
            "peers": [{"peer": IPHONE, "iDial": i_dial}],
            "links": [{"nodeId": IPHONE, "dialedByMe": dialed_by_me, "tagAware": tag_aware}],
        }

    def test_a_reader_dialed_by_the_phone_passes_with_the_bit_and_no_refusal(self) -> None:
        result = self.judge(self.blinding(i_dial=True, dialed_by_me=True, tag_aware=True), ["bt state links=1"], reader=True)
        self.assertEqual((result["dialer"], result["legacyRefusals"], result["tagAware"]), ("phone", 0, True))

    def test_a_reader_fails_on_one_legacy_refusal_or_a_hello_without_the_bit(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge(self.blinding(i_dial=True, dialed_by_me=True, tag_aware=True), [self.refused], reader=True)
        with self.assertRaises(RuntimeError):
            self.judge(self.blinding(i_dial=True, dialed_by_me=True, tag_aware=False), [], reader=True)

    def test_a_readers_own_dial_is_a_tag_dial_with_its_proved_line(self) -> None:
        reply = self.blinding(i_dial=True, dialed_by_me=False, tag_aware=True)
        result = self.judge(reply, [self.accepted], reader=True, knit=["link head start over for ~zzzz…7 (dwell=12000ms)", self.proved])
        self.assertEqual((result["dialer"], result["outcome"], result["line"]), ("iphone", "tag dial", self.proved))

    @mock.patch.object(interop, "PROVED_LINE_WAIT", 0)
    def test_a_fresh_tag_dial_without_its_proved_line_fails_and_one_from_before_the_log_is_reported(self) -> None:
        reply = self.blinding(i_dial=True, dialed_by_me=False, tag_aware=True)
        with self.assertRaises(RuntimeError):
            self.judge(reply, [self.accepted], reader=True, knit=[f"link ~zzzz…7 proved {IPHONE} on ch3"])
        result = self.judge(reply, [], reader=True, knit=[])
        self.assertEqual((result["outcome"], result["line"]), ("tag dial", None))

    @mock.patch.object(interop, "PROVED_LINE_WAIT", 0)
    def test_a_relinks_tag_dial_cannot_borrow_the_first_links_proved_line(self) -> None:
        # The line came 120 s ago, before the relink's clear 60 s ago.
        with self.assertRaises(RuntimeError):
            reply = self.blinding(i_dial=True, dialed_by_me=False, tag_aware=True)
            self.judge(reply, [self.accepted], reader=True, knit=[self.proved], ago=120)

    def test_a_build_before_the_reader_never_links_by_its_own_dial(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge(self.blinding(i_dial=True, dialed_by_me=False), [self.accepted], knit=[self.proved])

    def test_the_phone_dials_as_its_order_says_and_the_iphones_refused_dials_are_counted(self) -> None:
        result = self.judge(self.blinding(i_dial=True, dialed_by_me=True), [self.refused, self.refused, "bt state links=1"])
        self.assertEqual(result["dialer"], "phone")
        self.assertEqual(result["legacyRefusals"], 2)

    def test_a_link_the_order_did_not_call_for_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge(self.blinding(i_dial=True, dialed_by_me=False), [])

    def test_no_link_fails_and_a_phone_gone_clear_is_inconclusive(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge({"blinding": True, "peers": [], "links": []}, [])
        with self.assertRaises(interop.Inconclusive):
            self.judge({"blinding": False, "form": "clear"}, [])


class HeadStartLineTest(unittest.TestCase):
    """The iPhone's head-start line toward a phone, by its id or, toward a tag, by a handle a proved line ties to it."""

    def line(self, messages: list[str], blinded: bool) -> str | None:
        log = FakeKnitLog(messages)
        self.addCleanup(log.close)
        return interop._head_start_line(log, PHONE, time.time() - 60, blinded=blinded)

    def test_a_clear_or_resolved_peers_line_names_its_id(self) -> None:
        line = f"link head start over for {PHONE} (dwell=12000ms rssi=-60dBm)"
        self.assertEqual(self.line([line], blinded=False), line)
        self.assertEqual(self.line([line], blinded=True), line)

    def test_a_tags_line_is_found_by_the_handle_its_proved_line_names(self) -> None:
        start = "link head start over for ~zzzz…12 (dwell=12000ms rssi=-60dBm)"
        other = "link head start over for ~zzzz…1 (dwell=12000ms rssi=-60dBm)"
        self.assertEqual(self.line([other, start, f"link ~zzzz…12 proved {PHONE} on ch4"], blinded=True), start)
        self.assertIsNone(self.line([start, f"link ~zzzz…12 proved {IPHONE} on ch4"], blinded=True))
        self.assertIsNone(self.line([start, f"link ~zzzz…12 proved {PHONE} on ch4"], blinded=False))


class ScanIdsTest(unittest.TestCase):
    def test_a_blinded_advert_is_counted_and_left_out(self) -> None:
        nodes = [{"peer": PHONE, "flags": 0x02}, {"peer": "zzzz" + "a" * 22, "flags": interop.BLINDED | 0x02}, {"peer": IPHONE}]
        heard, blinded = interop.ids_heard(nodes)
        self.assertEqual(set(heard), {PHONE, IPHONE})
        self.assertEqual(blinded, 1)


@unittest.skipUnless(importlib.util.find_spec("PIL"), "the noise picture needs Pillow")
class NoisePictureTest(unittest.TestCase):
    def test_a_sized_picture_lands_near_its_size_and_within_androids_side(self) -> None:
        from PIL import Image  # noqa: PLC0415 - only this test needs it

        picture = interop._noise_jpeg("test-resume", interop.RESUME_PHOTO_BYTES)
        width, height = Image.open(io.BytesIO(picture)).size
        self.assertLessEqual(abs(len(picture) - interop.RESUME_PHOTO_BYTES), interop.RESUME_PHOTO_BYTES // 20)
        self.assertEqual(width, height)
        self.assertLessEqual(width, interop.NOISE_MAX_SIDE)
        self.assertEqual(picture, interop._noise_jpeg("test-resume", interop.RESUME_PHOTO_BYTES))

    def test_the_default_picture_is_the_small_one(self) -> None:
        from PIL import Image  # noqa: PLC0415 - only this test needs it

        self.assertEqual(Image.open(io.BytesIO(interop._noise_jpeg("test"))).size, (320, 240))


class FakeAdvertIPhone:
    """The iPhone's bridge as `IPhoneAdvert` and the rotation helpers use it: `replies` answers each `advert` call in turn,
    `rotations` each `advert-rotate`, and `calls` keeps what each asked."""

    node_id = IPHONE

    def __init__(self, replies: list[dict | None], rotations: list[dict] | None = None) -> None:
        self.replies = replies
        self.rotations = rotations or []
        self.calls: list[dict] = []
        self.stops = 0

    def advert(self, blind: bool | None = None, clear: bool = False) -> dict | None:
        self.calls.append({"clear": True} if clear else {} if blind is None else {"blind": blind})
        return self.replies.pop(0)

    def advert_rotate(self) -> dict:
        self.calls.append({"rotate": True})
        return self.rotations.pop(0)

    def stop(self) -> None:
        self.stops += 1


def ios_advert(stored: bool | None, value: bool, blinding: bool) -> dict:
    """An `advert` read, as `MeshControl+Advert.swift` shapes the fields the guard reads."""
    return {"switch": {"value": value, "stored": stored, "default": False}, "blinding": blinding, "form": "tag" if blinding else "clear"}


class IPhoneAdvertTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.left = Path(self.directory.name) / "left.json"
        self.fronts = 0

    def front(self) -> dict:
        self.fronts += 1
        return {"opened": "knit"}

    def guard(self, ios: FakeAdvertIPhone, want: bool = False, connect=None) -> interop.IPhoneAdvert:
        return interop.IPhoneAdvert(connect or (lambda: ios), want=want, front=self.front, left=self.left)

    def run_guard(self, ios: FakeAdvertIPhone, want: bool = False, body=None, connect=None) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(interop.time, "sleep"), self.guard(ios, want, connect):
            if body:
                body()
        return out.getvalue()

    def test_a_switch_stored_on_goes_off_for_the_run_and_on_again_with_knit_brought_forward(self) -> None:
        ios = FakeAdvertIPhone([ios_advert(True, True, True), {"applied": True}, {"applied": True}])

        def noted() -> None:
            self.assertEqual(json.loads(self.left.read_text())["stored"], True, "noted before the run")

        self.run_guard(ios, body=noted)
        self.assertEqual(ios.calls, [{}, {"blind": False}, {"blind": True}])
        self.assertEqual(self.fronts, 2, "brought forward before the flip and before the restore")
        self.assertFalse(self.left.exists(), "forgotten once put back")

    def test_a_bridge_that_does_not_answer_brings_knit_forward_once_and_connects_again(self) -> None:
        ios = FakeAdvertIPhone([ios_advert(None, False, False)])
        tries: list[int] = []

        def connect() -> FakeAdvertIPhone:
            tries.append(self.fronts)
            if self.fronts == 0:
                raise TimeoutError("a suspended Knit answers nothing")
            return ios

        self.run_guard(ios, connect=connect)
        self.assertEqual((tries, ios.calls), ([0, 1], [{}]))

    def test_the_default_switch_off_and_a_build_without_advert_are_left_alone(self) -> None:
        off = FakeAdvertIPhone([ios_advert(None, False, False)])
        self.run_guard(off)
        old = FakeAdvertIPhone([None])
        self.run_guard(old)
        self.assertEqual((off.calls, old.calls, self.fronts), ([{}], [{}], 0))
        self.assertFalse(self.left.exists())

    def test_iphone_rotate_turns_the_default_on_and_clears_it_after(self) -> None:
        ios = FakeAdvertIPhone([ios_advert(None, False, False), {"applied": True}, {"applied": True}])
        self.run_guard(ios, want=True)
        self.assertEqual(ios.calls, [{}, {"blind": True}, {"clear": True}])

    def test_a_restore_that_cannot_reach_the_bridge_prints_the_line_and_the_next_run_restores_first(self) -> None:
        ios = FakeAdvertIPhone([ios_advert(False, True, True), {"applied": True}])
        connects = [ios]

        def connect() -> FakeAdvertIPhone:
            if not connects:
                raise ConnectionError("nothing answers at the bridge")
            return connects.pop(0)

        out = self.run_guard(ios, connect=connect)
        lines = [json.loads(line) for line in out.splitlines()]
        self.assertIn("""scripts/interop.py bridge '{"cmd":"advert","blind":"off"}'""", [line.get("byHand") for line in lines])
        self.assertTrue(self.left.exists(), "kept for the next run")
        later = FakeAdvertIPhone([{"applied": True}, ios_advert(False, False, False)])
        self.run_guard(later)
        self.assertEqual(later.calls, [{"blind": False}, {}], "the leftover first, then the read")
        self.assertFalse(self.left.exists())

    def test_another_iphones_note_waits_for_that_phone(self) -> None:
        self.left.write_text(json.dumps({"stored": True, "nodeId": PHONE}))
        ios = FakeAdvertIPhone([ios_advert(None, False, False)])
        self.run_guard(ios)
        self.assertEqual(ios.calls, [{}])
        self.assertTrue(self.left.exists())

    def test_a_switch_that_will_not_follow_ends_the_run_with_the_switch_put_back(self) -> None:
        timeout = {"applied": False, "why": "timeout"}
        ios = FakeAdvertIPhone([ios_advert(None, True, True), timeout, timeout, {"applied": True}])
        with self.assertRaises(RuntimeError):
            self.run_guard(ios)
        self.assertEqual(ios.calls[-1], {"clear": True})

    def test_a_stopped_mesh_only_stores(self) -> None:
        ios = FakeAdvertIPhone([ios_advert(True, True, True), {"applied": False, "why": "transport not running"}, {"applied": True}])
        self.run_guard(ios)
        self.assertEqual(ios.calls, [{}, {"blind": False}, {"blind": True}])

    def test_the_guard_holds_only_the_runs_that_drive_the_iphone_and_judge_ids(self) -> None:
        def arguments(command: str, keep: bool = False) -> mock.Mock:
            return mock.Mock(command=command, keep_blind=keep, udid=None, host=None)

        self.assertIsInstance(interop.iphone_advert_guard(arguments("iphone")), interop.IPhoneAdvert)
        for left_alone in (arguments("iphone", keep=True), arguments("check"), arguments("bridge"), arguments("iphone-rotate")):
            self.assertNotIsInstance(interop.iphone_advert_guard(left_alone), interop.IPhoneAdvert)


class IPhoneAdvertCommandTest(unittest.TestCase):
    def ios(self, reply: dict) -> interop.IPhone:
        ios = interop.IPhone("udid")
        ios.command = mock.Mock(return_value=reply)
        return ios

    def test_the_switch_words_and_a_build_before_the_command(self) -> None:
        ios = self.ios({"ok": True, "reply": "advert"})
        ios.advert(blind=True)
        ios.advert(blind=False)
        ios.advert(clear=True)
        self.assertEqual([call.kwargs.get("blind") for call in ios.command.call_args_list], ["on", "off", "clear"])
        self.assertIsNone(self.ios({"ok": False, "error": "unknown command advert"}).advert())
        with self.assertRaises(RuntimeError):
            self.ios({"ok": False, "error": "this node has no blinded advert"}).advert()


class IPhoneRotateTest(unittest.TestCase):
    def settled(self, payload: int, resolvable: bool = True) -> dict:
        gatt = {"appliedTag": True, "pendingAdd": None, "doorbell": 1, "payload": payload}
        return {"form": "tag", "epoch": payload, "resolvable": resolvable, "source": "slotted", "restartsLeft": 2, "gatt": gatt}

    def test_a_refusal_time_ends_is_waited_out_and_the_rotation_recorded(self) -> None:
        ios = FakeAdvertIPhone([self.settled(5, resolvable=False)], [{"rotated": False, "why": "throttled"}, {"rotated": True}])
        with mock.patch.object(interop.time, "sleep"):
            record = interop._rotate_once(ios, 300)
        self.assertEqual((record["payload"], record["random"], record["waited"]), (5, True, {"throttled": 1}))

    def test_a_refusal_no_wait_ends_fails(self) -> None:
        ios = FakeAdvertIPhone([], [{"rotated": False, "why": "clear"}])
        with self.assertRaises(RuntimeError):
            interop._rotate_once(ios, 300)

    def test_the_doorbell_keeps_its_service_and_each_payload_is_new(self) -> None:
        first = {"doorbell": 1, "payload": 2}
        self.assertEqual(interop._doorbell_kept(first, [{"doorbell": 1, "payload": 4}])["payloads"], [2, 4])
        with self.assertRaises(RuntimeError):
            interop._doorbell_kept(first, [{"doorbell": 3, "payload": 4}])
        with self.assertRaises(RuntimeError):
            interop._doorbell_kept(first, [{"doorbell": 1, "payload": 2}])

    def test_the_logs_lines_are_read_as_frozen(self) -> None:
        entries = [
            {"message": "ble serving the payload's service 4"},
            {"message": "ble removed the payload's service 2"},
            {"message": "ble looks again at the services of 6F1E: they changed mid-search"},
            {"message": "ble rung by 6F1E"},
            {"message": "ble rung by 9A0C"},
        ]
        self.assertEqual(interop._payloads_turned(entries, [{"payload": 4}]), {"served": 1, "removed": 1})
        with self.assertRaises(RuntimeError):
            interop._payloads_turned(entries, [{"payload": 6}])
        self.assertEqual(interop._no_match_by_order(entries), {"looksAgain": 1})
        with self.assertRaises(RuntimeError):
            interop._no_match_by_order([{"message": "ble matched an added service by order, not identity: 3"}])
        phone = mock.Mock()
        with mock.patch.object(interop, "_phone_log", side_effect=lambda _, needle: [needle] if needle.startswith("bt ring") else []):
            self.assertEqual(interop._rings_heard(lambda: entries, phone, IPHONE, 1, 1)["heard"], 2)
            with self.assertRaises(RuntimeError):
                interop._rings_heard(lambda: entries, phone, IPHONE, 2, 2)
            # Two rings decided while the doorbell lookup ran went as one write: heard.
            self.assertEqual(interop._rings_heard(lambda: entries, phone, IPHONE, 1, 2)["peerRings"], 2)
            # Rings decided but no write logged: the peer is not at debug, or the line moved.
            with self.assertRaises(RuntimeError):
                interop._rings_heard(lambda: entries, phone, IPHONE, 0, 1)
        with mock.patch.object(interop, "_phone_log", return_value=[]), self.assertRaises(interop.Inconclusive):
            interop._rings_heard(lambda: entries, phone, IPHONE, 0, 0)

    def test_a_head_start_dial_to_a_linked_node_is_a_redial(self) -> None:
        node = "dlrr2hznxypyove635fmd56xvy"
        unlinked = [f"link down {node} on ch3", f"link head start over for {node} (dwell=24000ms rssi=-28dBm)", f"link up {node} on ch5"]
        self.assertEqual(interop._redials_while_linked(unlinked, node), {})
        # The handle of a tag nobody resolved is not the node.
        self.assertEqual(interop._redials_while_linked(["link head start over for ~zzzz…3 (dwell=24000ms rssi=-28dBm)"], node), {})
        relinked = [*unlinked, f"link head start over for {node} (dwell=24000ms rssi=-28dBm)", "link dialing ~zzzz…3 on ch6"]
        with self.assertRaises(RuntimeError):
            interop._redials_while_linked(relinked, node)
        # Held from the start: a crossing link that ends leaves the first one held.
        crossing = [f"link up {node} on ch5", f"link down {node} on ch5", f"link head start over for {node} (dwell=24000ms rssi=-28dBm)"]
        with self.assertRaises(RuntimeError):
            interop._redials_while_linked(crossing, node)

    def test_the_peers_doorbell_writes_are_its_ringing_lines_less_its_failures(self) -> None:
        messages = ["bluez ringing dev_42_AC", "bluez rung by dev_42_AC", "bluez ringing dev_42_AC", "bluez could not ring dev_42_AC: gone"]
        self.assertEqual(interop._doorbell_writes(messages), 1)

    def test_the_flip_line_is_no_fault_of_ours(self) -> None:
        message = "link ch4 closed: the advert flipped to a tag"
        reasons = [describe(match) for pattern, describe in interop.IOS_CHANNEL_ENDINGS if (match := pattern.match(message))]
        self.assertEqual(reasons, ["flipped: the advert's switch"])


class BlindingIPhoneTest(unittest.TestCase):
    """`iphone --keep-blind` with an iPhone whose own switch is on, toward a phone that airs its id."""

    def reply(self, dialed_by_me: bool, i_dial: bool = True, blinding: bool = True) -> dict:
        return {
            "blinding": blinding,
            "peers": [{"peer": PHONE, "iDial": i_dial}],
            "links": [{"nodeId": PHONE, "dialedByMe": dialed_by_me, "tagAware": True}],
        }

    def test_the_blinding_iphone_dials_a_clear_phone(self) -> None:
        ios = FakeAdvertIPhone([self.reply(dialed_by_me=True)])
        self.assertEqual(interop._ios_blind_dialed_by(ios, PHONE)["dialer"], "iphone")
        for reply in (self.reply(dialed_by_me=False), self.reply(dialed_by_me=True, i_dial=False)):
            with self.assertRaises(RuntimeError):
                interop._ios_blind_dialed_by(FakeAdvertIPhone([reply]), PHONE)
        with self.assertRaises(interop.Inconclusive):
            interop._ios_blind_dialed_by(FakeAdvertIPhone([self.reply(True, blinding=False)]), PHONE)

    def test_an_edge_past_the_wait_is_inconclusive_and_one_within_it_is_judged(self) -> None:
        far = {"nextEdgeAtMs": int((time.time() + 900) * 1000)}
        with self.assertRaises(interop.Inconclusive):
            interop._tag_next_across_edge(FakeAdvertIPhone([far]), mock.Mock(), PHONE, 60)
        near = {"nextEdgeAtMs": int(time.time() * 1000), "counters": {"tagNextAnnounced": 0, "rotationsBySlot": 0}}
        after = {"counters": {"tagNextAnnounced": 1, "rotationsBySlot": 1}, "links": [{"nodeId": PHONE}]}
        phone = mock.Mock()
        phone.advert.return_value = {"links": [{"nodeId": IPHONE, "blinded": True}]}
        with mock.patch.object(interop.time, "sleep"):
            judged = interop._tag_next_across_edge(FakeAdvertIPhone([near, after]), phone, PHONE, 60)
        self.assertEqual(judged, {"tagNextAnnounced": 1, "rotationsBySlot": 1, "phoneKnowsTag": True})
        phone.advert.return_value = {"links": [{"nodeId": IPHONE, "blinded": None}]}
        with mock.patch.object(interop.time, "sleep"), self.assertRaises(RuntimeError):
            interop._tag_next_across_edge(FakeAdvertIPhone([near, after]), phone, PHONE, 60)


# A slot edge on the wall clock (1 800 000 000 is a multiple of 900 s), and an iPhone's address.
EDGE = 1_800_000_000.0
ADDRESS = "4D:93:1A:2B:3C:4D"
HANDLE = "~zzzz…3"


def capture(*lines: tuple[float, str], end: float | None = None) -> list[tuple[float, str]]:
    """A phone's capture as `LogcatCapture.lines` gives it, ending at `end` with a state line."""
    return [*lines, *([(end, "bt state links=[] gattBudget=0/12")] if end is not None else [])]


def blinded_read(at: float, address: str = ADDRESS) -> tuple[float, str]:
    return (at, f"bt gatt read {address} blinded (psm 192)")


def link(up: float, down: float | None, dialer: str = "phone") -> list[tuple[float, str]]:
    opened = f"bt connect ok {IPHONE} durMs=700 sealed=true" if dialer == "phone" else f"bt accepted client {IPHONE} (accept, sighted=true)"
    lines = [(up - 0.5, opened), (up, f"bt link up: {IPHONE} (2 live)")]
    return lines + ([(down, f"bt link down: {IPHONE} (closed)")] if down is not None else [])


class BlindedGattLinesTest(unittest.TestCase):
    """The harness's reading of Android's blinded GATT lines (the `blind-gatt-reads` contract, §9, at knit-next `ee8609502`)."""

    def test_a_blinded_read_ends_a_read_and_names_no_node(self) -> None:
        blinded = interop.GATT_READ_END.match(f"bt gatt read {ADDRESS} blinded (psm 192)")
        clear = interop.GATT_READ_END.match(f"bt gatt read {ADDRESS} → {IPHONE} (psm 192)")
        self.assertEqual(blinded and (blinded.group(1), blinded.group(2), blinded.group(3)), (ADDRESS, None, "blinded"))
        self.assertEqual(clear and (clear.group(2), clear.group(3)), (IPHONE, None))
        for line in (f"bt gatt read {ADDRESS} failed (connect)", f"bt gatt read {ADDRESS} stranger (malformed-blinded)"):
            self.assertIsNotNone(interop.GATT_READ_END.match(line))

    def test_the_refunds_keep_apart(self) -> None:
        tagged = f"bt gatt confirmed {ADDRESS} (tag) → {IPHONE}"
        self.assertIsNone(interop.GATT_CONFIRMED.match(tagged))
        self.assertIsNotNone(interop.GATT_CONFIRMED_TAG.match(tagged))
        lines = [blinded_read(EDGE), (EDGE + 1, f"bt gatt confirmed {ADDRESS} → {IPHONE}")]
        self.assertEqual(len(interop._charged_reads(lines)), 1, "a clear refund never takes a blinded charge")
        self.assertEqual(interop._charged_reads([*lines, (EDGE + 2, tagged)]), [])
        clear = [(EDGE, f"bt gatt read {ADDRESS} → {IPHONE} (psm 192)"), (EDGE + 1, tagged)]
        self.assertEqual(len(interop._charged_reads(clear)), 1, "a tag refund never takes a clear charge")

    def test_a_blinded_read_holds_its_address(self) -> None:
        phone = mock.Mock()
        lines = [f"bt gatt read {ADDRESS} blinded (psm 192)"]
        with mock.patch.object(interop, "_phone_log", return_value=lines), mock.patch.object(interop.time, "sleep"):
            with self.assertRaises(TimeoutError):
                interop._address_released(phone, ADDRESS, 0)
            lines.append(f"bt gatt forget {ADDRESS} (edge)")
            interop._address_released(phone, ADDRESS, 0)

    def test_the_payloads_held_for_the_iphone(self) -> None:
        lines = [
            f"bt gatt read {ADDRESS} blinded (psm 192)",
            f"bt gatt read 11:22:33:44:55:66 → {IPHONE} (psm 192)",
            "bt gatt read 77:88:99:AA:BB:CC blinded (psm 193)",
            "bt gatt forget 77:88:99:AA:BB:CC (dial)",
            f"bt gatt read 11:22:33:44:55:66 → {PHONE} (psm 131)",
        ]
        self.assertEqual(interop._ios_payloads_held(lines, IPHONE), {ADDRESS})


class EdgeForgetsTest(unittest.TestCase):
    """Rule 4 judged from a phone's capture: 35 to 65 s past the first edge after the read."""

    def judge(self, *lines: tuple[float, str], end: float = EDGE + 2000) -> dict:
        return interop._edge_forgets(capture(*lines, end=end), IPHONE)

    def forget(self, past: float) -> tuple[float, str]:
        return (EDGE + 900 + past, f"bt gatt forget {ADDRESS} (edge)")

    def test_a_forget_inside_the_window_is_on_time(self) -> None:
        self.assertEqual(self.judge(blinded_read(EDGE + 100), self.forget(50))["onTime"], 1)

    def test_an_early_a_late_and_a_second_forget_fail(self) -> None:
        for lines in ((self.forget(20),), (self.forget(100),), (self.forget(40), self.forget(50))):
            with self.subTest(lines=lines), self.assertRaises(RuntimeError):
                self.judge(blinded_read(EDGE + 100), *lines)

    def test_a_late_forget_a_link_spared_passes(self) -> None:
        detail = self.judge(blinded_read(EDGE + 100), *link(EDGE + 200, EDGE + 900 + 110), self.forget(115))
        self.assertEqual(detail["spared"], 1)

    def test_a_payload_never_forgotten_past_its_window_fails_unless_read_again_or_spared(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge(blinded_read(EDGE + 100), end=EDGE + 900 + 100)
        again = self.judge(blinded_read(EDGE + 100), blinded_read(EDGE + 960), self.forget(900 + 50), end=EDGE + 2000)
        self.assertEqual(again["onTime"], 1)
        spared = self.judge(blinded_read(EDGE + 100), *link(EDGE + 200, None), self.forget(300), end=EDGE + 1300)
        self.assertEqual(spared["spared"], 1)

    def test_nothing_to_judge_is_inconclusive(self) -> None:
        with self.assertRaises(interop.Inconclusive):
            self.judge(blinded_read(EDGE + 100), end=EDGE + 300)


class BlindedRefundsTest(unittest.TestCase):
    def judge(self, *lines: tuple[float, str]) -> dict:
        return interop._blinded_refunds(capture(*lines, end=EDGE + 800), IPHONE)

    def refund(self, at: float) -> tuple[float, str]:
        return (at, f"bt gatt confirmed {ADDRESS} (tag) → {IPHONE}")

    def test_a_link_refunds_its_slots_read(self) -> None:
        self.assertEqual(self.judge(blinded_read(EDGE + 100), *link(EDGE + 130, None), self.refund(EDGE + 130.2))["refunded"], 1)

    def test_a_link_that_leaves_its_read_charged_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            self.judge(blinded_read(EDGE + 100), *link(EDGE + 130, None))

    def test_a_read_at_the_slots_start_is_excused_and_a_relink_from_a_refunded_read_skipped(self) -> None:
        with self.assertRaises(interop.Inconclusive):
            self.judge(blinded_read(EDGE + 20), *link(EDGE + 60, None))
        detail = self.judge(blinded_read(EDGE + 100), *link(EDGE + 130, EDGE + 200), self.refund(EDGE + 130.2), *link(EDGE + 260, None))
        self.assertEqual(detail["refunded"], 1)


class BudgetAgreesTest(unittest.TestCase):
    def state(self, at: float, used: int) -> tuple[float, str]:
        return (at, f"bt state links=[] gattReads=3 gattBudget={used}/12")

    def test_the_budget_counts_charges_less_refunds(self) -> None:
        lines = [
            (EDGE, "bt state links=[] gattBudget=0/12"),
            blinded_read(EDGE + 10),
            (EDGE + 11, f"bt gatt confirmed {ADDRESS} (tag) → {IPHONE}"),
            (EDGE + 20, "bt gatt read 01:02:03:04:05:06 stranger (no-service)"),
            self.state(EDGE + 300, 1),
            self.state(EDGE + 700, 0),
        ]
        self.assertEqual(interop._budget_agrees(lines)["checked"], 3)

    def test_a_budget_that_disagrees_fails_and_reads_before_the_capture_may_add(self) -> None:
        with self.assertRaises(RuntimeError):
            interop._budget_agrees([(EDGE, "bt state x"), blinded_read(EDGE + 10), self.state(EDGE + 300, 0)])
        self.assertEqual(interop._budget_agrees([self.state(EDGE, 4)])["mostUsed"], 4)


class BlindResolutionsTest(unittest.TestCase):
    def resolved(self, at: float, key: str, how: str) -> tuple[float, str]:
        return (at, f"bt gatt blinded {ADDRESS} → {key} ({how})")

    def test_the_contact_resolves_by_key_alone(self) -> None:
        self.assertEqual(interop._contact_resolves(interop._gatt_resolutions([self.resolved(EDGE, IPHONE, "key")]), IPHONE, False)["resolutions"], {"key": 1})
        held = interop._gatt_resolutions([self.resolved(EDGE, IPHONE, "key"), self.resolved(EDGE + 1, HANDLE, "handle")])
        with self.assertRaises(RuntimeError):
            interop._contact_resolves(held, IPHONE, False)
        self.assertEqual(interop._contact_resolves(held, IPHONE, True)["resolutions"], {"key": 1, "handle": 1})

    def test_the_stranger_holds_a_handle_until_its_first_link_and_never_resolves_by_key(self) -> None:
        good = interop._gatt_resolutions([self.resolved(EDGE, HANDLE, "handle"), self.resolved(EDGE + 500, IPHONE, "claim")])
        self.assertEqual(interop._stranger_resolves(good, IPHONE, EDGE + 100)["laterByClaimOrHint"], 1)
        for lines, first in (
            ([self.resolved(EDGE, IPHONE, "key")], None),
            ([self.resolved(EDGE, IPHONE, "claim")], EDGE + 100),
            ([self.resolved(EDGE, HANDLE, "handle"), self.resolved(EDGE + 500, PHONE, "hint")], EDGE + 100),
        ):
            with self.subTest(lines=lines), self.assertRaises(RuntimeError):
                interop._stranger_resolves(interop._gatt_resolutions(lines), IPHONE, first)


class BlindLinksTest(unittest.TestCase):
    def test_each_link_and_its_dialer(self) -> None:
        links = interop._ios_links([*link(EDGE, EDGE + 10), *link(EDGE + 20, None, dialer="iphone")], IPHONE)
        self.assertEqual([(entry["dialer"], entry["why"]) for entry in links], [("phone", "closed"), ("iphone", None)])

    def test_a_link_held_across_an_edge_and_one_dropped_there(self) -> None:
        held = capture(*link(EDGE - 600, None), end=EDGE + 900 + 100)
        self.assertEqual(interop._held_across_edges(interop._ios_links(held, IPHONE), held, 2)["edgesHeld"], 2)
        dropped = capture(*link(EDGE - 600, EDGE + 30), end=EDGE + 100)
        with self.assertRaises(RuntimeError):
            interop._held_across_edges(interop._ios_links(dropped, IPHONE), dropped, 1)
        with self.assertRaises(interop.Inconclusive):
            interop._held_across_edges(interop._ios_links(held, IPHONE), held, 3)

    def test_a_dial_to_the_linked_iphone_by_id_or_handle_is_a_redial(self) -> None:
        resolved = (EDGE - 10, f"bt gatt blinded {ADDRESS} → {HANDLE} (handle)")
        crossing = (EDGE - 1, f"bt initiating to {HANDLE} (psm 192 rssi=-60 a2dp=false links=1)")
        self.assertEqual(interop._no_android_redials([resolved, crossing, *link(EDGE, None)], IPHONE), {"keys": 2})
        for key in (IPHONE, HANDLE):
            dial = (EDGE + 5, f"bt initiating to {key} (psm 192 rssi=-60 a2dp=false links=1)")
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                interop._no_android_redials([resolved, *link(EDGE, None), dial], IPHONE)

    def test_both_orders_wants_a_dial_each_way_by_the_order(self) -> None:
        self.assertEqual(interop._both_orders([{"dialer": "phone"}, {"dialer": "iphone"}])["headStarts"], 0)
        with self.assertRaises(interop.Inconclusive):
            interop._both_orders([{"dialer": "phone"}, {"dialer": "iphone", "outcome": "tag dial"}])


class BlindDoorbellAndSealTest(unittest.TestCase):
    def test_a_settle_must_find_the_doorbell(self) -> None:
        settle = (EDGE, f"bt doorbell settling {IPHONE} (3100ms since link up)")
        found = (EDGE + 7, f"bt doorbell found {IPHONE} ({ADDRESS})")
        self.assertEqual(interop._doorbell_settles([settle, found], IPHONE), {"settles": 1})
        with self.assertRaises(RuntimeError):
            interop._doorbell_settles([settle], IPHONE)
        with self.assertRaises(RuntimeError):
            interop._doorbell_settles([settle, (EDGE + 10, f"bt doorbell absent {IPHONE}")], IPHONE)
        with self.assertRaises(interop.Inconclusive):
            interop._doorbell_settles([found], IPHONE)

    def test_every_phone_ring_is_heard(self) -> None:
        rings = {"contact": [(EDGE, f"bt ring {IPHONE}")] * 3, "stranger": [(EDGE, f"bt ring {IPHONE}")]}
        self.assertEqual(interop._blind_rings_heard(rings, IPHONE, 5)["heard"], 5)
        with self.assertRaises(RuntimeError):
            interop._blind_rings_heard(rings, IPHONE, 3)

    def test_the_seal_on_both_ends(self) -> None:
        before = {"linksSealed": 2, "linkSealFailed": 0, "linkSealRefused": 0}
        after = {"linksSealed": 5, "linkSealFailed": 0, "linkSealRefused": 0}
        self.assertEqual(interop._ios_sealed(after, before, 3)["linkUps"], 3)
        with self.assertRaises(RuntimeError):
            interop._ios_sealed(after, before, 4)
        with self.assertRaises(RuntimeError):
            interop._ios_sealed({**after, "linkSealRefused": 1}, before, 3)
        plain = [(EDGE, f"bt connect ok {IPHONE} durMs=500 sealed=false")]
        with self.assertRaises(RuntimeError):
            interop._phone_sealed(after, before, plain, IPHONE)
        self.assertEqual(interop._phone_sealed(after, before, [], IPHONE)["linksSealed"], 3)

    def test_a_legacy_refusal_on_either_side_fails(self) -> None:
        refused = {"contact": [(EDGE, f"bt refused client {IPHONE} (refuse, blind=legacy)")]}
        with self.assertRaises(RuntimeError):
            interop._no_legacy(refused, IPHONE, {}, {})
        with self.assertRaises(RuntimeError):
            interop._no_legacy({"contact": []}, IPHONE, {"refusedLegacy": 1}, {"refusedLegacy": 2})
        self.assertEqual(interop._no_legacy({"contact": []}, IPHONE, {}, {}), {})


class BlindingAdvertsTest(unittest.TestCase):
    """`ClearAdverts` with `blind`, as `iphone-blind-reads` holds both its phones."""

    def test_a_clear_phone_blinds_for_the_run_and_a_blinding_one_is_left_alone(self) -> None:
        clear = FakeAdvertPhone("p3", [advert(False, False), {"applied": True}, {"applied": True}])
        blinding = FakeAdvertPhone("p9", [advert(None, True)])
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(interop.time, "sleep"), interop.ClearAdverts([clear, blinding], blind=True):
            pass
        self.assertEqual(clear.calls, [{}, {"blind": True}, {"blind": False}])
        self.assertEqual(blinding.calls, [{}])

    def test_the_run_holds_its_own_iphone_switch(self) -> None:
        self.assertIn("iphone-blind-reads", interop.BLINDING_RUNS)
        self.assertNotIn("iphone-blind-reads", interop.IPHONE_LEGACY_RUNS)


class TopLevelNamesTest(unittest.TestCase):
    """A second `def` of a module-level name silently replaces the first for every caller, as the ratchet's `_counted`
    once replaced the link counter and crashed every `--links` run."""

    def test_no_script_defines_a_top_level_name_twice(self) -> None:
        for script in sorted(Path(interop.__file__).parent.glob("*.py")):
            tree = ast.parse(script.read_text(encoding="utf-8"))
            kinds = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
            names = collections.Counter(node.name for node in tree.body if isinstance(node, kinds))
            with self.subTest(script=script.name):
                self.assertEqual({name: count for name, count in names.items() if count > 1}, {})

    def test_doorbell_links_counts_found_links_the_phone_took(self) -> None:
        tally = [
            {"doorbellFound": True, "accepted": None},
            {"doorbellFound": True, "accepted": False},
            {"doorbellFound": False, "accepted": True},
            {"doorbellFound": True, "accepted": True},
        ]
        self.assertEqual(interop._doorbell_links(tally), 2)


if __name__ == "__main__":
    unittest.main()
