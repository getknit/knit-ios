#!/usr/bin/env python3
"""Download GantMan's nsfw_model 1.2.0, check it, and unpack its SavedModel into `.cache/src/`.

    uv run python fetch.py

Two pins guard the provenance: the zip's own SHA-256, and the SHA-256 of the TFLite inside it, which must be
knit-next's `nsfw.tflite`. The second is the proof that the SavedModel `convert.py` reads holds Android's weights.
"""

from __future__ import annotations

import hashlib
import sys
import urllib.request
import zipfile

from common import ANDROID_TFLITE_SHA256, CACHE, RELEASE_URL, SOURCE, TFLITE, ZIP, ZIP_SHA256


def sha256(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    CACHE.mkdir(exist_ok=True)
    if not ZIP.exists():
        print(f"downloading {RELEASE_URL}")
        partial = ZIP.with_suffix(".part")
        urllib.request.urlretrieve(RELEASE_URL, partial)
        partial.rename(ZIP)
    if (found := sha256(ZIP)) != ZIP_SHA256:
        print(f"{ZIP.name}: sha256 {found}, expected {ZIP_SHA256}", file=sys.stderr)
        return 1
    if not TFLITE.exists():
        with zipfile.ZipFile(ZIP) as archive:
            archive.extractall(SOURCE.parent)
    if (found := sha256(TFLITE)) != ANDROID_TFLITE_SHA256:
        print(f"{TFLITE.name}: sha256 {found} is not knit-next's nsfw.tflite ({ANDROID_TFLITE_SHA256})", file=sys.stderr)
        return 1
    print(f"{SOURCE.relative_to(CACHE.parent)}: the SavedModel behind knit-next's nsfw.tflite")
    return 0


if __name__ == "__main__":
    sys.exit(main())
