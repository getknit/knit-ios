#!/usr/bin/env python3
"""Symbolicates a Knit for iOS crash or hang report (ADR 2026-10.qhsv), on the Mac.

A report the iPhone saves holds its frames as MetricKit gives them: binary, address, the binary's UUID and the offset
into its text segment. This script finds each UUID's dSYM, asks `atos` what each address is, and prints the report with
the symbol after each frame it could name. Frames in Apple's own binaries resolve only when this Mac has their symbols,
so most stay as they are; Knit's own frames resolve against the dSYM of the build that crashed.

    scripts/symbolicate.py report.txt                     # dSYMs found by Spotlight or in Xcode's archives
    scripts/symbolicate.py report.txt --dsym Knit.xcarchive --dsym ~/Downloads/Knit.app.dSYM
    scripts/symbolicate.py report.txt --dsym ~/Downloads/knit-ios-1.0.0-5-dSYMs.zip   # as CI's release:testflight keeps them
    pbpaste | scripts/symbolicate.py -                     # a report copied from the iPhone

It needs `atos`, `dwarfdump` and `mdfind`, so it runs on the Mac: from here, copy the report into the tree and use
`scripts/mac.sh run scripts/symbolicate.py <path>`.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

# One frame line, as KnitAppCore's CrashReport writes it: `<indent><depth> <binary> 0x<16 hex> <UUID> + <offset>`, then
# ` [<samples>]` in a hang. A binary's name may hold spaces, so it is everything between the depth and the address.
FRAME = re.compile(
    r"^(?P<indent>\s*)(?P<depth>\d+) (?P<binary>.+?) 0x(?P<address>[0-9a-f]{16}) "
    r"(?P<uuid>[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) \+ (?P<offset>\d+)"
    r"(?P<rest>.*)$"
)
# `dwarfdump --uuid`'s line for each slice: `UUID: <UUID> (<arch>) <path>`.
DWARFDUMP_UUID = re.compile(r"^UUID: (?P<uuid>[0-9A-Fa-f-]{36}) \((?P<arch>[^)]+)\) (?P<path>.+)$")
SYMBOLS_LINE = "symbols: "
SEPARATOR = "----"

Runner = Callable[[Sequence[str]], str]


def run(command: Sequence[str]) -> str:
    """Runs `command` and returns its standard output, or nothing when it fails."""
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""


class Frame:
    """One frame line of a report."""

    def __init__(self, index: int, match: re.Match[str]) -> None:
        self.index = index
        self.match = match
        self.uuid = match.group("uuid").upper()
        self.address = int(match.group("address"), 16)
        self.offset = int(match.group("offset"))

    @property
    def load_address(self) -> int:
        """Where the binary's text segment was loaded: the address less its offset into it."""
        return self.address - self.offset


def frames(lines: Sequence[str]) -> List[Frame]:
    """The frame lines after the header's separator."""
    found: List[Frame] = []
    body = False
    for index, line in enumerate(lines):
        if line == SEPARATOR:
            body = True
            continue
        match = FRAME.match(line) if body else None
        if match:
            found.append(Frame(index, match))
    return found


def dwarf_files(path: str) -> List[str]:
    """The DWARF files under `path`: a dSYM bundle, an archive or a folder holding them, or a DWARF file itself."""
    if os.path.isfile(path):
        return [path]
    files: List[str] = []
    for root, _, names in os.walk(path):
        if os.path.basename(os.path.dirname(root)) == "Resources" and os.path.basename(root) == "DWARF":
            files.extend(os.path.join(root, name) for name in sorted(names))
    return files


def uuids(dwarf: str, runner: Runner) -> Dict[str, Tuple[str, str]]:
    """Each UUID in `dwarf`, with the slice's architecture and the file."""
    found: Dict[str, Tuple[str, str]] = {}
    for line in runner(["dwarfdump", "--uuid", dwarf]).splitlines():
        match = DWARFDUMP_UUID.match(line.strip())
        if match:
            found[match.group("uuid").upper()] = (match.group("arch"), match.group("path"))
    return found


def locate(wanted: Iterable[str], dsyms: Sequence[str], runner: Runner) -> Dict[str, Tuple[str, str]]:
    """The architecture and DWARF file for each wanted UUID that can be found: in `dsyms` first, then by Spotlight,
    then in Xcode's archives."""
    wanted = {uuid.upper() for uuid in wanted}
    found: Dict[str, Tuple[str, str]] = {}

    def scan(paths: Iterable[str]) -> None:
        for path in paths:
            for dwarf in dwarf_files(path):
                for uuid, slice_ in uuids(dwarf, runner).items():
                    if uuid in wanted:
                        found.setdefault(uuid, slice_)

    scan(dsyms)
    for uuid in sorted(wanted - found.keys()):
        scan(line for line in runner(["mdfind", f"com_apple_xcode_dsym_uuids == {uuid}"]).splitlines() if line)
    if wanted - found.keys():
        scan([os.path.expanduser("~/Library/Developer/Xcode/Archives")])
    return found


def symbols(frames_: Sequence[Frame], slices: Dict[str, Tuple[str, str]], runner: Runner) -> Dict[int, str]:
    """What `atos` names each frame it can, by line index: one `atos` call per binary and load address."""
    named: Dict[int, str] = {}
    groups: Dict[Tuple[str, int], List[Frame]] = {}
    for frame in frames_:
        if frame.uuid in slices:
            groups.setdefault((frame.uuid, frame.load_address), []).append(frame)
    for (uuid, load), members in groups.items():
        arch, dwarf = slices[uuid]
        command = ["atos", "-arch", arch, "-o", dwarf, "-l", hex(load)] + [hex(frame.address) for frame in members]
        answers = runner(command).splitlines()
        for frame, answer in zip(members, answers):
            answer = answer.strip()
            # atos answers an address it cannot name with the address itself.
            if answer and not answer.startswith("0x"):
                named[frame.index] = answer
    return named


def unpacked(paths: Sequence[str], into: str) -> List[str]:
    """`paths` with each zip among them, `check.sh archive`'s and CI's `knit-ios-<version>-<build>-dSYMs.zip`, extracted
    into a folder of its own under `into`. `extractall` keeps every member inside that folder."""
    result: List[str] = []
    for index, path in enumerate(paths):
        if path.endswith(".zip") and os.path.isfile(path):
            target = os.path.join(into, str(index))
            with zipfile.ZipFile(path) as archive:
                archive.extractall(target)
            result.append(target)
        else:
            result.append(path)
    return result


def symbolicate(text: str, dsyms: Sequence[str] = (), runner: Runner = run) -> Tuple[str, int, int]:
    """`text` with each frame that could be named followed by its symbol, and the header's symbols line saying how many
    were. Returns the text, how many frames were named, and how many there were."""
    lines = text.split("\n")
    found = frames(lines)
    with tempfile.TemporaryDirectory(prefix="symbolicate-") as scratch:
        slices = locate({frame.uuid for frame in found}, unpacked(dsyms, scratch), runner)
        named = symbols(found, slices, runner)
    for index, symbol in named.items():
        lines[index] = f"{lines[index]}  {symbol}"
    for index, line in enumerate(lines):
        if line == SEPARATOR:
            break
        if line.startswith(SYMBOLS_LINE):
            lines[index] = f"{SYMBOLS_LINE}symbolicated by scripts/symbolicate.py, {len(named)} of {len(found)} frames named"
    return "\n".join(lines), len(named), len(found)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("report", help="the report's file, or - for standard input")
    parser.add_argument(
        "--dsym",
        action="append",
        default=[],
        help="a dSYM bundle, an .xcarchive, a folder or zip of dSYMs, or a DWARF file to look in first (repeatable)",
    )
    parser.add_argument("-o", "--output", help="where to write the report (default: standard output)")
    args = parser.parse_args(argv)
    missing = [tool for tool in ("atos", "dwarfdump", "mdfind") if shutil.which(tool) is None]
    if missing:
        print(
            f"symbolicate.py: {', '.join(missing)} not found; run it on the Mac (scripts/mac.sh run scripts/symbolicate.py)",
            file=sys.stderr,
        )
        return 2
    text = sys.stdin.read() if args.report == "-" else open(args.report, encoding="utf-8").read()
    result, named, total = symbolicate(text, [os.path.expanduser(path) for path in args.dsym])
    if args.output:
        with open(args.output, "w", encoding="utf-8") as out:
            out.write(result)
    else:
        sys.stdout.write(result)
    print(f"symbolicate.py: named {named} of {total} frames", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
