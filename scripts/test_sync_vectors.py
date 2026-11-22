"""Tests for sync-vectors.py's reading of the spool's vectors out of knit-next's prose (ADR 2026-11.adrq), on documents
cut down to the shapes §13 of `SPOOL_PROTOCOL.md` and §5 of `RELAY_INVITE.md` use, so they run without a checkout:
`python3 -m unittest discover -s scripts -p 'test_*.py'`, as `scripts/check.sh scripts` does."""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("sync_vectors", os.path.join(HERE, "sync-vectors.py"))
sync_vectors = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_vectors)

FENCE = "```"

SPOOL = f"""# The spool protocol

## 13. Test vectors [Both]

Inputs:

{FENCE}
nodeIdA      = "aaaaabbbbbcccccdddddeeeeef"          nodeIdB = "zzzzzyyyyyxxxxxwwwwwvvvvvu"
pairwiseRoot = fixture(32, 1)  = 0108
sig          = fixture(64, 4)  = 040b
                                    e4eb
{FENCE}

Derivations (§3):

{FENCE}
dmScopeId       = aeced0ad
groupScopeId v2 = 8ea040bc   // rotation pin
{FENCE}

Pair scope (§3.5; appended — the rows above did not move):

{FENCE}
pairScopeId     = bf46c96f
{FENCE}

Commons (§7.4):

{FENCE}
commonsScopeId  = a081eddb
{FENCE}

Seal (§4; keys and scopeId are the DM values above; deterministic, so sealing twice is
byte-identical):

{FENCE}
blob   = 01e6
            844e
blobId = 8e5c
{FENCE}

Digest (§6.3):

{FENCE}
digest(∅) = 0000000000000000
{FENCE}

PoW (§8):

{FENCE}
scopeId = fixture(32, 9) = 0910
day = 20680, powBits = 8  →  smallest n = 8
SHA-256(input) = 00b7
{FENCE}

Records (§7; whole-record CBOR):

{FENCE}
helloClient  = a261746568656c6c6f617601
blob         = a461
                7464
{FENCE}

Signals (§7.8): a HELLO with a capability a text client ignores.

{FENCE}
helloSpoolSig = a661
sigRecord     = a361
{FENCE}

## Appendix A. Implementation status
"""

INVITE = f"""# Relay invites

## 5. Golden vectors

{FENCE}
fullInvite = u "wss://home.example.org/spool/v1?k=fixture-token", c fixture(32, 10), n "Home":
                pGF2AWF1
bareInvite = u "wss://lax.spool.getknit.app/spool/v1", no c, no n:
                omF2AWF1
ticketInvite = u "wss://lab.example.org/spool/v1?k=fixture-token", no c, no n,
                i "https://anywhere.example.org", k "kak1_" + base64url(fixture(32, 20))
                = "kak1_FBsi":
                pGF2AWF1eC53
{FENCE}

## 6. Out of repo
"""


@unittest.skipUnless(shutil.which("git"), "the fixture is a git repository, and the CI image for script tests has no git")
class SpoolVectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        (root / "docs").mkdir()
        (root / "docs" / "SPOOL_PROTOCOL.md").write_text(SPOOL, encoding="utf-8")
        (root / "docs" / "RELAY_INVITE.md").write_text(INVITE, encoding="utf-8")
        for command in (["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "t"]):
            subprocess.run(["git", "-C", str(root), *command], check=True)
        self.vectors = sync_vectors.spool_vectors(root)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_rows_run_on_over_indented_lines_and_comments_are_dropped(self) -> None:
        scope = self.vectors["scope"]
        self.assertEqual(scope["Inputs"]["sig"], "040be4eb")
        self.assertEqual(scope["Inputs"]["pairwiseRoot"], "0108")
        self.assertEqual(scope["Inputs"]["nodeIdB"], "zzzzzyyyyyxxxxxwwwwwvvvvvu")
        self.assertEqual(scope["Derivations"]["groupScopeId v2"], "8ea040bc")
        self.assertEqual(scope["Seal"]["blob"], "01e6844e")

    def test_a_section_keeps_its_own_names(self) -> None:
        scope = self.vectors["scope"]
        self.assertEqual(scope["Records"]["blob"], "a4617464")
        self.assertEqual(scope["PoW"], {"scopeId": "0910", "SHA-256(input)": "00b7"})

    def test_sections_a_text_client_never_reads_are_left_out_but_their_hellos_kept(self) -> None:
        self.assertNotIn("Commons", self.vectors["scope"])
        self.assertNotIn("Signals", self.vectors["scope"])
        self.assertEqual(self.vectors["helloVariants"], {"helloSpoolSig": "a661"})

    def test_invites_read_what_the_link_holds(self) -> None:
        invites = self.vectors["relayInvite"]
        self.assertEqual(
            invites["fullInvite"],
            {"link": "pGF2AWF1", "u": "wss://home.example.org/spool/v1?k=fixture-token", "c": True, "n": "Home",
                "i": False, "k": False},
        )
        self.assertEqual(invites["bareInvite"]["c"], False)
        self.assertEqual(invites["ticketInvite"]["link"], "pGF2AWF1eC53")
        self.assertEqual((invites["ticketInvite"]["i"], invites["ticketInvite"]["k"]), (True, True))

    def test_both_documents_are_named_with_their_commit(self) -> None:
        paths = [source["path"] for source in self.vectors["source"]]
        self.assertEqual(paths, ["docs/SPOOL_PROTOCOL.md", "docs/RELAY_INVITE.md"])
        self.assertFalse(any(source["uncommitted"] for source in self.vectors["source"]))


if __name__ == "__main__":
    unittest.main()
