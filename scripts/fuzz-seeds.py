#!/usr/bin/env python3
"""Write a seed corpus for each harness in Fuzz/ from knit-next's golden vectors.

    python3 scripts/fuzz-seeds.py <directory>

FuzzCBOR gets every golden CBOR item, FuzzLinkRecords gets the same items framed as link records (a chunk-size
byte, then a FRAME record), and FuzzAdvert gets a pinned advert and a node id. `scripts/fuzz.sh` calls this
into a scratch directory; the committed Fuzz/Corpus/ holds only inputs that once found a bug.
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAME_TAG = 1
CHUNK_BYTE = 7
ADVERT = "ff294213fa67091e03c2f2ae8d071b9d6700000000008100"
NODE_ID = b"ffbbh6thbepahqxsv2gqog45m4"


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    vectors = json.loads((ROOT / "Tests" / "Vectors" / "wire-v1.json").read_text(encoding="utf-8"))["vectors"]
    for harness in ("FuzzCBOR", "FuzzLinkRecords", "FuzzAdvert"):
        (out / harness).mkdir(parents=True, exist_ok=True)
    for name, hexed in vectors.items():
        item = bytes.fromhex(hexed)
        (out / "FuzzCBOR" / name).write_bytes(item)
        record = bytes([CHUNK_BYTE, FRAME_TAG]) + struct.pack(">I", len(item)) + item
        (out / "FuzzLinkRecords" / name).write_bytes(record)
    (out / "FuzzAdvert" / "advert").write_bytes(bytes.fromhex(ADVERT))
    (out / "FuzzAdvert" / "node-id").write_bytes(NODE_ID)
    return 0


if __name__ == "__main__":
    sys.exit(main())
