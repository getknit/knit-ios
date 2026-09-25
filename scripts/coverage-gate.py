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


def measure(scratch: Path) -> dict[str, tuple[int, int]]:
    profile, binaries = find_inputs(scratch)
    command = [*llvm_cov(), "export", "-summary-only", "-instr-profile", str(profile), str(binaries[0])]
    for binary in binaries[1:]:
        command += ["-object", str(binary)]
    report = json.loads(subprocess.check_output(command))
    sources = f"{ROOT}{os.sep}Sources{os.sep}"
    totals: dict[str, tuple[int, int]] = {}
    for entry in report["data"][0]["files"]:
        name = entry["filename"]
        if not name.startswith(sources):
            continue
        target = name[len(sources):].split(os.sep, 1)[0]
        lines = entry["summary"]["lines"]
        covered, count = totals.get(target, (0, 0))
        totals[target] = (covered + lines["covered"], count + lines["count"])
    return totals


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scratch-path", default=".build-cov", type=Path)
    parser.add_argument("--floors", default=DEFAULT_FLOORS, type=Path)
    parser.add_argument("--ratchet", action="store_true", help="raise floors to the measured figures")
    args = parser.parse_args()

    floors: dict[str, int] = json.loads(args.floors.read_text()) if args.floors.exists() else {}
    totals = measure(args.scratch_path)
    failures = []
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
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
