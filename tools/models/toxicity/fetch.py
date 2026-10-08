#!/usr/bin/env python3
"""Download Detoxify's unbiased-small checkpoint into `.cache/`, and check it and Android's files.

    uv run python fetch.py

Three pins guard the provenance: the checkpoint's SHA-256, which detoxify-mobile pins too, and the SHA-256s of the
tokenizer and the word list in `App/Models/`, which must be knit-next's files byte for byte.
"""

from __future__ import annotations

import sys
import urllib.request

from common import (
    ANDROID_PROFANITY_SHA256,
    ANDROID_SLURS_SHA256,
    ANDROID_TOKENIZER_SHA256,
    CACHE,
    CHECKPOINT,
    CHECKPOINT_SHA256,
    CHECKPOINT_URL,
    PROFANITY,
    SLURS,
    TOKENIZER,
    sha256,
)


def main() -> int:
    CACHE.mkdir(exist_ok=True)
    if not CHECKPOINT.exists():
        print(f"downloading {CHECKPOINT_URL}")
        partial = CHECKPOINT.with_suffix(".part")
        urllib.request.urlretrieve(CHECKPOINT_URL, partial)
        partial.rename(CHECKPOINT)
    failed = False
    for path, expected, whose in (
        (CHECKPOINT, CHECKPOINT_SHA256, "Detoxify's v0.1.2 release"),
        (TOKENIZER, ANDROID_TOKENIZER_SHA256, "knit-next's tokenizer.json"),
        (PROFANITY, ANDROID_PROFANITY_SHA256, "knit-next's profanity_en.txt"),
        (SLURS, ANDROID_SLURS_SHA256, "knit-next's slurs_en.txt"),
    ):
        if (found := sha256(path)) != expected:
            print(f"{path.name}: sha256 {found} is not {whose} ({expected})", file=sys.stderr)
            failed = True
    if not failed:
        print(f"{CHECKPOINT.name}, {TOKENIZER.name}, {PROFANITY.name} and {SLURS.name}: what knit-next's toxicity screening is built from")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
