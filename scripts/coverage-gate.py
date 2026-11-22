#!/usr/bin/env python3
"""Fail when a target's line coverage drops below its floor in scripts/coverage-floors.json.

    python3 scripts/coverage-gate.py --scratch-path .build-cov            # gate (CI, check.sh coverage)
    python3 scripts/coverage-gate.py --scratch-path .build-cov --ratchet  # raise floors to today's figures

Run `swift test --enable-code-coverage --scratch-path .build-cov` first.

Floors only move up. `--ratchet` never lowers one, and a phase closes by ratcheting its targets toward the
figures in `.agents/context/testing.md`. A target with no executable lines yet (a stub) passes, and a target
with lines but no floor fails, so a new target gets a floor on purpose rather than by accident.

Swift Build runs every test target as its own binary, and `swift test --show-codecov-path` exports coverage
for only some of them. So this script runs `llvm-cov export` itself, over every test binary at once.
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
DEFAULT_FLOORS = ROOT / "scripts" / "coverage-floors.json"


def llvm_cov() -> list[str]:
    if platform.system() == "Darwin":
        return ["xcrun", "llvm-cov"]
    info = json.loads(subprocess.check_output(["swift", "-print-target-info"], text=True))
    resources = Path(info["paths"]["runtimeResourcePath"])
    return [str((resources / ".." / ".." / "bin" / "llvm-cov").resolve())]


def find_inputs(scratch: Path) -> tuple[Path, list[Path]]:
    profiles = sorted(glob.glob(str(scratch / "**" / "codecov" / "default.profdata"), recursive=True))
    if not profiles:
        sys.exit(f"coverage-gate: no default.profdata under {scratch}; run swift test --enable-code-coverage first")
    products = Path(profiles[0]).parent.parent
    binaries = sorted(products.glob("*Tests.so")) or sorted(products.glob("*.xctest/Contents/MacOS/*"))
    if not binaries:
        sys.exit(f"coverage-gate: no test binaries beside {profiles[0]}")
    return Path(profiles[0]), binaries


def objects(binaries: list[Path]) -> list[str]:
    """llvm-cov's arguments for every test binary: the first bare, the rest after -object."""
    arguments = [str(binaries[0])]
    for binary in binaries[1:]:
        arguments += ["-object", str(binary)]
    return arguments


def measure(scratch: Path, threads: int) -> tuple[dict[str, tuple[int, int]], dict[str, dict[str, int]]]:
    """Each target's covered and counted lines, and each target's files with the lines they miss."""
    profile, binaries = find_inputs(scratch)
    command = [*llvm_cov(), "export", "-summary-only", "-instr-profile", str(profile), *objects(binaries)]
    if threads:
        command.append(f"--num-threads={threads}")
    report = json.loads(subprocess.check_output(command))
    sources = f"{ROOT}{os.sep}Sources{os.sep}"
    totals: dict[str, tuple[int, int]] = {}
    missed: dict[str, dict[str, int]] = {}
    for entry in report["data"][0]["files"]:
        name = entry["filename"]
        if not name.startswith(sources):
            continue
        target = name[len(sources):].split(os.sep, 1)[0]
        lines = entry["summary"]["lines"]
        covered, count = totals.get(target, (0, 0))
        totals[target] = (covered + lines["covered"], count + lines["count"])
        if lines["covered"] < lines["count"]:
            missed.setdefault(target, {})[name] = lines["count"] - lines["covered"]
    return totals, missed


def demangler() -> list[str]:
    """llvm-cov's flag for swift-demangle, which sits beside it; none when it is missing."""
    if platform.system() == "Darwin":
        return ["-Xdemangler", "xcrun", "-Xdemangler", "swift-demangle"]
    tool = Path(llvm_cov()[0]).with_name("swift-demangle")
    return ["-Xdemangler", str(tool)] if tool.exists() else []


def explain(scratch: Path, files: dict[str, int], limit: int = 10) -> list[str]:
    """The functions in `files` that miss lines, so a failure on one runner names them. The export's line counts take each
    implicit closure as a line, the never-run right side of a `??` among them, and `report -show-functions` lists those
    closures too, where `show` and lcov call the line hit."""
    worst = sorted(files.items(), key=lambda item: (-item[1], item[0]))[:limit]
    profile, binaries = find_inputs(scratch)
    command = [*llvm_cov(), "report", "-show-functions", *demangler(), "-instr-profile", str(profile), *objects(binaries)]
    report = subprocess.run([*command, *(name for name, _ in worst)], capture_output=True, text=True)
    out = []
    current = ""
    for row in report.stdout.splitlines():
        if row.startswith("File '"):
            current = row[len("File '"):].rstrip("':")
            out.append(f"  {os.path.relpath(current, ROOT)}: {files.get(current, '?')} missed")
            continue
        # Name, then regions, miss and cover, lines, miss and cover, branches, miss and cover, apart by two spaces or more.
        columns = re.split(r"\s{2,}", row.strip())
        if current and len(columns) == 10 and columns[0] != "TOTAL" and columns[5].isdigit() and int(columns[5]) > 0:
            out.append(f"    {columns[5]} in {columns[0]}")
    if len(files) > limit:
        out.append(f"  and {len(files) - limit} more files")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scratch-path", default=".build-cov", type=Path)
    parser.add_argument("--floors", default=DEFAULT_FLOORS, type=Path)
    parser.add_argument("--ratchet", action="store_true", help="raise floors to the measured figures")
    parser.add_argument("--threads", default=0, type=int, help="llvm-cov's threads (default: one per core)")
    args = parser.parse_args()

    floors: dict[str, int] = json.loads(args.floors.read_text()) if args.floors.exists() else {}
    totals, missed = measure(args.scratch_path, args.threads)
    failures = []
    short = []
    for target in sorted(set(floors) | set(totals)):
        covered, count = totals.get(target, (0, 0))
        percent = 100.0 * covered / count if count else None
        floor = floors.get(target)
        shown = "no lines yet" if percent is None else f"{percent:5.1f}% ({covered}/{count})"
        print(f"{target:18s} {shown:>22s}   floor {floor if floor is not None else '-'}")
        if percent is None:
            continue
        if floor is None:
            failures.append(f"{target} has {count} lines but no floor in {args.floors.name}")
        elif percent < floor:
            failures.append(f"{target} is at {percent:.1f}%, under its floor of {floor}%")
            short.append(target)
        if args.ratchet:
            floors[target] = max(floor or 0, math.floor(percent))

    covered_all = sum(covered for covered, _ in totals.values())
    count_all = sum(count for _, count in totals.values())
    if count_all:
        # test:coverage's `coverage:` regex reads this line for the MR widget and the project's coverage badge.
        print(f"coverage-gate: total line coverage {100.0 * covered_all / count_all:.1f}% ({covered_all}/{count_all})")

    if args.ratchet:
        args.floors.write_text(json.dumps(dict(sorted(floors.items())), indent=2) + "\n")
        print(f"coverage-gate: floors written to {args.floors}")
        return 0
    for failure in failures:
        print(f"coverage-gate: {failure}", file=sys.stderr)
    for target in short:
        print(f"coverage-gate: what {target} misses, by file and function:", file=sys.stderr)
        for line in explain(args.scratch_path, missed.get(target, {})):
            print(line, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
