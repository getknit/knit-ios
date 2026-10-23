"""Tests for symbolicate.py, with `atos`, `dwarfdump` and `mdfind` stubbed: run anywhere with
`python3 -m unittest discover -s scripts -p 'test_*.py'`, as `scripts/check.sh scripts` does."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
import zipfile
from typing import Dict, List, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import symbolicate  # noqa: E402

APP = "5F2C1D3A-8B41-3E77-9A0C-6D2E4F1B7C90"
UIKIT = "9C04A2E1-7D3B-35F8-B612-4E8A0F1C6D27"

# A crash and a hang as KnitAppCore's CrashReport writes them (DemoCrash's, cut down).
CRASH = f"""Knit for iOS crash report - redacted on the iPhone. Nothing was uploaded.
summary: EXC_BREAKPOINT (SIGTRAP) in Knit +0x12c2f0
app: 1.0.0 (4) TestFlight
arch: arm64e
symbols: unsymbolicated - scripts/symbolicate.py resolves the frames with the dSYM of 1.0.0 (4)
----
Thread 0 (crashed)
0 libswiftCore.dylib 0x000000019d0cb664 1B7E3F55-0C2A-3D91-8E64-AF0B9C2D4E18 + 1253476
1 Knit 0x0000000104a162f0 {APP} + 1229552
2 Knit 0x0000000104a13500 {APP} + 1217792
3 UIKitCore 0x0000000197d26a80 {UIKIT} + 2398336
"""

# A hang's branches are indented two spaces, which the report's lines are built with here.
BRANCH = "  "
HANG = "\n".join([
    "Knit for iOS hang report (Knit stopped responding) - redacted on the iPhone. Nothing was uploaded.",
    "symbols: unsymbolicated - scripts/symbolicate.py resolves the frames with the dSYM of 1.0.0 (4)",
    "----",
    "Thread 0 (hung)",
    "0 libsystem_kernel.dylib 0x00000001c734f8f4 E3A91B07-4F6C-3A2D-8B15-70D2C9E6F4A3 + 2804 [24]",
    f"{BRANCH}1 Knit 0x0000000104a22000 {APP} + 1277952 [18]",
    f"{BRANCH}1 Knit 0x0000000104a23000 {APP} + 1282048 [6]",
    "",
])


class Stub:
    """Answers each tool as the Mac would, and records what it was asked."""

    def __init__(self, dwarf: Dict[str, str], spotlight: Dict[str, List[str]], atos: Dict[str, str]) -> None:
        self.dwarf = dwarf
        self.spotlight = spotlight
        self.atos = atos
        self.calls: List[List[str]] = []

    def __call__(self, command: Sequence[str]) -> str:
        self.calls.append(list(command))
        if command[0] == "dwarfdump":
            return self.dwarf.get(command[2], "")
        if command[0] == "mdfind":
            return "\n".join(self.spotlight.get(command[1].split(" == ")[1], []))
        if command[0] == "atos":
            return "\n".join(self.atos.get(address, address) for address in command[7:])
        return ""


class SymbolicateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        # Xcode's archives are found under ~, so ~ is a folder of the test's own.
        self.addCleanup(os.environ.__setitem__, "HOME", os.environ["HOME"])
        os.environ["HOME"] = self.home.name
        self.bundle = os.path.join(self.home.name, "Knit.app.dSYM")
        self.dwarf = os.path.join(self.bundle, "Contents", "Resources", "DWARF", "Knit")
        os.makedirs(os.path.dirname(self.dwarf))
        open(self.dwarf, "w").close()

    def stub(self, spotlight: bool = True) -> Stub:
        return Stub(
            dwarf={self.dwarf: f"UUID: {APP} (arm64) {self.dwarf}\n"},
            spotlight={APP: [self.bundle]} if spotlight else {},
            atos={
                "0x104a162f0": "closure #1 in CrashCommand.answer(_:) (in Knit) (CrashCommand.swift:39)",
                "0x104a13500": "CrashCommand.answer(_:) (in Knit) (CrashCommand.swift:37)",
                "0x104a22000": "Lock.withLock<A>(_:) (in Knit) (Lock.swift:41)",
            },
        )

    def test_frames_are_read_with_their_load_address(self) -> None:
        found = symbolicate.frames(CRASH.split("\n"))
        self.assertEqual([frame.uuid for frame in found][1:3], [APP, APP])
        self.assertEqual(found[1].address, 0x104A162F0)
        self.assertEqual(found[1].load_address, 0x104A162F0 - 1229552)
        self.assertEqual(found[1].load_address, found[2].load_address)

    def test_knits_frames_are_named_and_the_rest_left_alone(self) -> None:
        stub = self.stub()
        text, named, total = symbolicate.symbolicate(CRASH, runner=stub)
        lines = text.split("\n")
        self.assertEqual((named, total), (2, 4))
        self.assertTrue(lines[8].endswith(f"{APP} + 1229552  closure #1 in CrashCommand.answer(_:) (in Knit) (CrashCommand.swift:39)"))
        self.assertTrue(lines[9].endswith("  CrashCommand.answer(_:) (in Knit) (CrashCommand.swift:37)"))
        self.assertEqual(lines[7], CRASH.split("\n")[7])
        self.assertEqual(lines[10], CRASH.split("\n")[10])
        self.assertEqual(lines[4], "symbols: symbolicated by scripts/symbolicate.py, 2 of 4 frames named")

    def test_one_atos_call_per_binary_and_load_address(self) -> None:
        stub = self.stub()
        symbolicate.symbolicate(CRASH, runner=stub)
        atos = [call for call in stub.calls if call[0] == "atos"]
        self.assertEqual(atos, [["atos", "-arch", "arm64", "-o", self.dwarf, "-l", hex(0x104A162F0 - 1229552), "0x104a162f0", "0x104a13500"]])

    def test_a_hang_keeps_its_indent_and_samples(self) -> None:
        text, named, _ = symbolicate.symbolicate(HANG, runner=self.stub())
        lines = text.split("\n")
        self.assertEqual(named, 1)
        self.assertEqual(lines[5], f"{BRANCH}1 Knit 0x0000000104a22000 {APP} + 1277952 [18]  Lock.withLock<A>(_:) (in Knit) (Lock.swift:41)")
        self.assertEqual(lines[6], HANG.split("\n")[6])

    def test_a_dsym_given_is_read_before_spotlight(self) -> None:
        stub = self.stub(spotlight=False)
        _, named, _ = symbolicate.symbolicate(CRASH, dsyms=[self.home.name], runner=stub)
        self.assertEqual(named, 2)
        self.assertNotIn(APP, " ".join(" ".join(call) for call in stub.calls if call[0] == "mdfind"))

    def test_a_zip_of_dsyms_is_read_as_ci_keeps_it(self) -> None:
        zipped = os.path.join(self.home.name, "knit-ios-1.0.0-5-dSYMs.zip")
        with zipfile.ZipFile(zipped, "w") as archive:
            archive.write(self.dwarf, "dSYMs/Knit.app.dSYM/Contents/Resources/DWARF/Knit")
        os.remove(self.dwarf)
        stub = self.stub(spotlight=False)
        # The extracted file's path is the run's own, so dwarfdump answers any Knit DWARF file.
        stub.dwarf = {}
        answer = stub.__call__

        def runner(command: Sequence[str]) -> str:
            if command[0] == "dwarfdump" and command[2].endswith(os.path.join("DWARF", "Knit")):
                return f"UUID: {APP} (arm64) {command[2]}\n"
            return answer(command)

        _, named, _ = symbolicate.symbolicate(CRASH, dsyms=[zipped], runner=runner)
        self.assertEqual(named, 2)

    def test_xcodes_archives_are_searched_last(self) -> None:
        archive = os.path.join(self.home.name, "Library", "Developer", "Xcode", "Archives", "2026-10-23", "Knit.xcarchive", "dSYMs")
        os.makedirs(archive)
        os.rename(self.bundle, os.path.join(archive, "Knit.app.dSYM"))
        moved = os.path.join(archive, "Knit.app.dSYM", "Contents", "Resources", "DWARF", "Knit")
        stub = Stub(dwarf={moved: f"UUID: {APP} (arm64) {moved}\n"}, spotlight={}, atos=self.stub().atos)
        _, named, _ = symbolicate.symbolicate(CRASH, runner=stub)
        self.assertEqual(named, 2)

    def test_no_dsym_leaves_the_report_as_it_was_but_for_its_count(self) -> None:
        text, named, total = symbolicate.symbolicate(CRASH, runner=Stub({}, {}, {}))
        self.assertEqual((named, total), (0, 4))
        self.assertEqual(text.split("\n")[5:], CRASH.split("\n")[5:])

    def test_a_frame_line_above_the_separator_is_not_a_frame(self) -> None:
        text = f"summary: 0 Knit 0x0000000104a162f0 {APP} + 1\n----\n"
        self.assertEqual(symbolicate.frames(text.split("\n")), [])


if __name__ == "__main__":
    unittest.main()
