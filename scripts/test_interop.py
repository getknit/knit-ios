"""Tests for interop.py's pure parts: the parsers that read a resumed photo's lines on Android and the iPhone, the checks
built on them, and the noise picture's size. Run anywhere with `python3 -m unittest discover -s scripts -p 'test_*.py'`,
as `scripts/check.sh scripts` does: nothing here touches a phone, an adapter or adb, and the picture's test skips
without Pillow."""

from __future__ import annotations

import importlib.util
import io
import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
