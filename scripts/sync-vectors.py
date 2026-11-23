#!/usr/bin/env python3
"""Copy what this repo must match byte for byte out of knit-next, and hand back what it emits.

    python3 scripts/sync-vectors.py                  # copy from ~/source/knit-next
    python3 scripts/sync-vectors.py --check          # exit 1 if a committed copy is stale
    python3 scripts/sync-vectors.py --knit-next PATH # another checkout or worktree
    python3 scripts/sync-vectors.py --only NAME      # one vector file alone, from a checkout past the pin
    python3 scripts/sync-vectors.py --export         # copy Tests/Vectors/ios-emitted-v1.json into knit-next

knit-next keeps its vectors in `vectors/` (its ADR 2026-09.fzh7). `wire-v1.json` holds the codec fixtures and
the bundle probe, and `keyed-v1.json` holds fixed identities, their signed frames, a sealed DM, the safety
number, the link records and an advert. Both are copied into `Tests/Vectors/` under the same names.
`ratchet-v1.json` (companion change A9, ADR 2026-10.5sk9) holds the ratchet's known answers and transcripts, and
`custody-v1.json` (knit-next ADR 2026-10.7mqm) the custody contract: steps stored through one store and what each
must keep, evict and hold. `name-key-v1.json` (knit-next #228) holds the name key's lookalike fold and drop set, and
names with the key, the display blank and the cleaned text each must give, and `name-screen-v1.json` (knit-next ADR
2026-11.y4pc) the name screen's verdict on names over the shipped word lists, with each list's digest.
`mention-vouch-v1.json` (knit-next #247, knit-ios #36) holds directories with the label each id must get, and received
mentions with which entries a bubble keeps and the spans it lights. A checkout from before any of these changes has none
of that file, so each is copied and checked only where it exists.

`spool-v1.json` is not copied but read out of two documents, since knit-next pins the spool's vectors in prose: the
fenced blocks of `docs/SPOOL_PROTOCOL.md` §13 and of `docs/RELAY_INVITE.md` §5. It keeps what a text-only client
checks (the inputs, the DM and pair derivations, the seal, the digest, proof of work, the core records, every
HELLO variant and the invite links) and leaves out the commons, attachments, TURN, tickets, casts and signals.

`--only` copies or checks the files it names and nothing else, and leaves the alias words alone. It is for a
file that lands on a knit-next branch before the pin moves: the other copies keep the provenance they have.

`Sources/KnitCrypto/AliasWords.swift` is generated from `identity/AliasWords.kt`. If the lists differ by one
word, the two platforms show different names for the same person.

Every copy records the knit-next commit it came from, and whether its source file had uncommitted changes.
The Swift build and tests read the copies, never knit-next, so CI needs no knit-next checkout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

# The repository root, from this file rather than git, which the CI image for script tests lacks.
ROOT = Path(__file__).resolve().parent.parent
VECTORS = ROOT / "Tests" / "Vectors"
WIRE = "wire-v1.json"
KEYED = "keyed-v1.json"
EMITTED = "ios-emitted-v1.json"
RATCHET = "ratchet-v1.json"
CUSTODY = "custody-v1.json"
NAME_KEY = "name-key-v1.json"
NAME_SCREEN = "name-screen-v1.json"
MENTION_VOUCH = "mention-vouch-v1.json"
SPOOL = "spool-v1.json"
# Copied where the knit-next checkout has them; a checkout from before the change that added one has none.
OPTIONAL = (RATCHET, CUSTODY, NAME_KEY, NAME_SCREEN, MENTION_VOUCH, SPOOL)
SPOOL_SPEC = Path("docs/SPOOL_PROTOCOL.md")
RELAY_INVITE_SPEC = Path("docs/RELAY_INVITE.md")
# The §13 blocks a text-only client checks, by the label that opens the paragraph before each.
SPOOL_SECTIONS = ("Inputs", "Derivations", "Pair scope", "Seal", "Digest", "PoW", "Records")
SPOOL_HEX = re.compile(r"[0-9a-f]+")
ALIAS_OUTPUT = ROOT / "Sources" / "KnitCrypto" / "AliasWords.swift"
ALIAS_SOURCE = Path("app/src/main/java/app/getknit/knit/identity/AliasWords.kt")
ALIAS_LISTS = (("ALIAS_ADVERBS", "adverbs"), ("ALIAS_ADJECTIVES", "adjectives"), ("ALIAS_NOUNS", "nouns"))
LINE_LIMIT = 132

def git(knit_next: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(knit_next), *args], text=True).strip()


def provenance(knit_next: Path, path: Path) -> dict:
    return {
        "repository": "knit-next",
        "path": str(path),
        "commit": git(knit_next, "rev-parse", "HEAD"),
        "uncommitted": bool(git(knit_next, "status", "--porcelain", "--", str(path))),
        "sha256": hashlib.sha256((knit_next / path).read_bytes()).hexdigest(),
    }


def copied(knit_next: Path, name: str) -> dict:
    """A file from knit-next's `vectors/`, with its provenance first."""
    path = Path("vectors") / name
    if not (knit_next / path).is_file():
        sys.exit(f"sync-vectors: {knit_next / path} is missing; is {knit_next} a knit-next checkout from 1f3befcd on?")
    content = json.loads((knit_next / path).read_text(encoding="utf-8"))
    return {"source": provenance(knit_next, path), **content}


def copied_if_present(knit_next: Path, name: str) -> dict | None:
    """An optional file from knit-next's `vectors/`, or `None` when this checkout predates it."""
    if name == SPOOL:
        return spool_vectors(knit_next)
    if not (knit_next / "vectors" / name).is_file():
        return None
    return copied(knit_next, name)


def fenced_blocks(text: str) -> list[tuple[str, list[str]]]:
    """Each fenced block, with the first line of the paragraph before it, which names it in knit-next's docs."""
    lines = text.split("\n")
    blocks: list[tuple[str, list[str]]] = []
    label, previous_blank, index = "", True, 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("```"):
            end = index + 1
            while not lines[end].startswith("```"):
                end += 1
            blocks.append((label, lines[index + 1:end]))
            index, previous_blank = end + 1, False
            continue
        if line.strip():
            if previous_blank:
                label = line
            previous_blank = False
        else:
            previous_blank = True
        index += 1
    return blocks


def spool_entries(body: list[str]) -> dict[str, str]:
    """`name = value` rows: a quoted string, or hex that may run on over indented lines. Other rows are prose."""
    entries: dict[str, str] = {}
    current = None
    for raw in body:
        line = raw.split("//")[0].rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        if raw[:1].isspace() and current and SPOOL_HEX.fullmatch(stripped):
            entries[current] += stripped
            continue
        current = None
        quoted = re.findall(r'(\w+)\s*=\s*"([^"]*)"', line)
        if quoted:
            entries.update(quoted)
        elif "=" in line:
            parts = [part.strip() for part in line.split("=")]
            if SPOOL_HEX.fullmatch(parts[-1]) and len(parts[-1]) % 2 == 0:
                entries[parts[0]] = parts[-1]
                current = parts[0]
    return entries


def invite_entries(body: list[str]) -> dict[str, dict]:
    """RELAY_INVITE.md §5's rows: what the link holds, then the link itself on the row's last line."""
    rows: dict[str, list[str]] = {}
    current = None
    for raw in body:
        match = re.match(r"(\w+) = (.*)$", raw)
        if match:
            current = match.group(1)
            rows[current] = [match.group(2)]
        elif current:
            rows[current].append(raw.strip())
    invites = {}
    for name, lines in rows.items():
        held = " ".join(lines[:-1])
        found = re.search(r'\bu "([^"]+)"', held)
        title = re.search(r'\bn "([^"]+)"', held)
        if not found:
            sys.exit(f"sync-vectors: {RELAY_INVITE_SPEC} row {name} names no u")
        invites[name] = {
            "link": lines[-1],
            "u": found.group(1),
            "c": "no c" not in held,
            "n": title.group(1) if title else None,
            "i": bool(re.search(r'\bi "', held)),
            "k": bool(re.search(r'\bk "', held)),
        }
    return invites


def section(text: str, start: str, end: str, path: Path) -> str:
    if start not in text or end not in text[text.index(start):]:
        sys.exit(f"sync-vectors: {path} has no '{start}' section; has knit-next changed shape?")
    first = text.index(start)
    return text[first:text.index(end, first)]


def spool_vectors(knit_next: Path) -> dict | None:
    """The spool's vectors, read out of the spec's prose, or `None` when this checkout has no spool spec."""
    if not (knit_next / SPOOL_SPEC).is_file() or not (knit_next / RELAY_INVITE_SPEC).is_file():
        return None
    spec = (knit_next / SPOOL_SPEC).read_text(encoding="utf-8")
    scope: dict[str, dict[str, str]] = {}
    hellos: dict[str, str] = {}
    for label, body in fenced_blocks(section(spec, "## 13. Test vectors", "## Appendix A.", SPOOL_SPEC)):
        entries = spool_entries(body)
        name = re.match(r"([A-Za-z][A-Za-z -]*?)\s*[(:]", label)
        name = name.group(1).strip() if name else label.strip()
        if name in SPOOL_SECTIONS:
            scope.setdefault(name, {}).update(entries)
        else:
            hellos.update({key: value for key, value in entries.items() if key.startswith("hello")})
    missing = [name for name in SPOOL_SECTIONS if not scope.get(name)]
    if missing:
        sys.exit(f"sync-vectors: {SPOOL_SPEC} §13 has no {', '.join(missing)} block; has knit-next changed shape?")
    invite = (knit_next / RELAY_INVITE_SPEC).read_text(encoding="utf-8")
    blocks = fenced_blocks(section(invite, "## 5. Golden vectors", "## 6.", RELAY_INVITE_SPEC))
    if len(blocks) != 1:
        sys.exit(f"sync-vectors: {RELAY_INVITE_SPEC} §5 has {len(blocks)} blocks, not 1")
    return {
        "source": [provenance(knit_next, SPOOL_SPEC), provenance(knit_next, RELAY_INVITE_SPEC)],
        "fixture": "fixture(n, seed)[i] = (7 * i + seed) mod 256",
        "scope": scope,
        "helloVariants": hellos,
        "relayInvite": invite_entries(blocks[0][1]),
    }


def alias_words(knit_next: Path) -> str:
    kotlin = (knit_next / ALIAS_SOURCE).read_text(encoding="utf-8")
    commit = git(knit_next, "rev-parse", "HEAD")
    lines = [
        f"// Generated by scripts/sync-vectors.py from knit-next {commit[:8]}, {ALIAS_SOURCE}. Do not edit.",
        "//",
        "// The frozen alias vocabulary: three sorted, disjoint lists of exactly 256 words, so one digest byte is",
        "// one whole index. knit-next never reorders, replaces or removes an entry after release.",
        "",
        "/// The alias word lists, identical to knit-next's `AliasWords.kt`.",
        "public enum AliasWords {",
    ]
    for index, (kotlin_name, swift_name) in enumerate(ALIAS_LISTS):
        start = kotlin.index(f"val {kotlin_name}")
        body = kotlin[start:kotlin.index(")", kotlin.index("listOf(", start))]
        words = re.findall(r'"([^"]+)"', body)
        if len(words) != 256:
            sys.exit(f"sync-vectors: {kotlin_name} has {len(words)} words, not 256")
        if index:
            lines.append("")
        lines.append(f"    /// knit-next's `{kotlin_name}`.")
        lines.append(f"    public static let {swift_name}: [String] = [")
        row = ""
        for word in words:
            item = f'"{word}",'
            candidate = f"{row} {item}" if row else f"        {item}"
            if len(candidate) > LINE_LIMIT:
                lines.append(row)
                candidate = f"        {item}"
            row = candidate
        lines.append(row)
        lines.append("    ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


def without_source(content: dict) -> dict:
    return {key: value for key, value in content.items() if key != "source"}


def is_stale(name: str, fresh: dict) -> bool:
    committed = VECTORS / name
    if not committed.is_file():
        return True
    return without_source(json.loads(committed.read_text(encoding="utf-8"))) != without_source(fresh)


def render(content: dict) -> str:
    return json.dumps(content, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--knit-next", type=Path, default=Path.home() / "source" / "knit-next")
    parser.add_argument("--check", action="store_true", help="fail if a committed copy is stale")
    parser.add_argument("--export", action="store_true", help=f"copy Tests/Vectors/{EMITTED} into knit-next")
    parser.add_argument(
        "--only",
        action="append",
        choices=(WIRE, KEYED, RATCHET, CUSTODY, NAME_KEY, NAME_SCREEN, MENTION_VOUCH, SPOOL),
        help="copy or check only this vector file (repeatable); the alias words are left alone",
    )
    args = parser.parse_args()

    if args.export:
        target = args.knit_next / "vectors" / EMITTED
        if not target.parent.is_dir():
            sys.exit(f"sync-vectors: {target.parent} does not exist; that checkout predates companion change A2")
        shutil.copyfile(VECTORS / EMITTED, target)
        print(f"sync-vectors: copied {EMITTED} to {target}")
        return 0

    names = args.only or [WIRE, KEYED, RATCHET, CUSTODY, NAME_KEY, NAME_SCREEN, MENTION_VOUCH, SPOOL]
    files: dict[str, dict] = {}
    absent: list[str] = []
    for name in names:
        content = copied_if_present(args.knit_next, name) if name in OPTIONAL else copied(args.knit_next, name)
        if content is None:
            if args.only:
                sys.exit(f"sync-vectors: {name}'s source is missing from {args.knit_next}")
            absent.append(name)
        else:
            files[name] = content
    if WIRE in files and not files[WIRE]["vectors"]:
        sys.exit("sync-vectors: found no codec vectors; has knit-next changed shape?")
    words = None if args.only else alias_words(args.knit_next)
    commit = git(args.knit_next, "rev-parse", "HEAD")[:8]
    skipped = f"; {', '.join(absent)} not in that checkout, so not compared" if absent else ""

    if args.check:
        stale = [name for name, fresh in files.items() if is_stale(name, fresh)]
        # The generated header names a commit; compare the lists, not the stamp.
        if words is not None and ALIAS_OUTPUT.read_text(encoding="utf-8").split("\n", 1)[1] != words.split("\n", 1)[1]:
            stale.append(ALIAS_OUTPUT.name)
        if stale:
            print(f"sync-vectors: stale against knit-next {commit}: {', '.join(stale)}; rerun without --check", file=sys.stderr)
            return 1
        print(f"sync-vectors: every copy matches knit-next {commit}{skipped}")
        return 0

    VECTORS.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (VECTORS / name).write_text(render(content), encoding="utf-8")
    written = list(files)
    if words is not None:
        ALIAS_OUTPUT.write_text(words, encoding="utf-8")
        written.append(ALIAS_OUTPUT.name)
    uncommitted = [
        name
        for name, content in files.items()
        if any(source["uncommitted"] for source in (content["source"] if isinstance(content["source"], list) else [content["source"]]))
    ]
    note = f" (uncommitted there: {', '.join(uncommitted)})" if uncommitted else ""
    print(f"sync-vectors: wrote {', '.join(written)} from knit-next {commit}{note}{skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
