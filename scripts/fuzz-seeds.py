#!/usr/bin/env python3
"""Write a seed corpus for each harness in Fuzz/ from knit-next's golden vectors.

    python3 scripts/fuzz-seeds.py <directory>

FuzzCBOR gets every golden CBOR item, FuzzLinkRecords gets the same items framed as link records (a chunk-size
byte, then a FRAME record) and whole files as Android streams them (a FILE_HEADER, chunks and a FILE_END), and
FuzzAdvert gets a pinned advert and a node id, and FuzzContactCard knit-next's two contact card vectors in their link forms
and a verify code (docs/CONTACT_CARD.md §5). `scripts/fuzz.sh` calls this into a scratch directory; the committed
Fuzz/Corpus/ holds only inputs that once found a bug.
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAME_TAG = 1
FILE_HEADER_TAG, FILE_CHUNK_TAG, FILE_END_TAG = 2, 3, 4
CHUNK_BYTE = 7
ADVERT = "ff294213fa67091e03c2f2ae8d071b9d6700000000008100"
NODE_ID = b"ffbbh6thbepahqxsv2gqog45m4"
CARD_ID = "4cgq2pnhh6p3j3afwsue3chrpi"
CARD_BUNDLE = "omZzaWdQdWJYIOQDCZjP1a0XI8Fp+VaqC564YZtZkr1hLCr0KOvHn43wZ2hwa2VQdWJYIHPnmXHJEQApcjYyqAtwe/T2LBJXYzRuHocY1sDcw6o6"
FULL_CARD = (
    "omRib2R5WKimYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
    "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmRu"
    "YW1lY0FubmJzcIF4JHdzczovL2xheC5zcG9vbC5nZXRrbml0LmFwcC9zcG9vbC92MWNpYXQbAAAB"
    "mN-3eQBjc2lnWECn4VUyYreXsIMy1qJZ0Lan7cjpXGgbCijTCfSD68vSkGUrLis_L5ybjYzE86B8"
    "AR6MbQdZ3f6f62UsQPQyRPoH"
)
MINIMAL_CARD = (
    "omRib2R5WGijYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
    "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmNz"
    "aWdYQLL2FdNZ6dxdvl8HfEBnbj8yNsSoGoCPELMEIXuO6kA04Ra6SeNRPkpg1UGmp1ZQgU3qjVOp"
    "M6JdH3puOvfihQA"
)


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    vectors = json.loads((ROOT / "Tests" / "Vectors" / "wire-v1.json").read_text(encoding="utf-8"))["vectors"]
    for harness in ("FuzzCBOR", "FuzzLinkRecords", "FuzzAdvert", "FuzzContactCard"):
        (out / harness).mkdir(parents=True, exist_ok=True)
    for name, hexed in vectors.items():
        item = bytes.fromhex(hexed)
        (out / "FuzzCBOR" / name).write_bytes(item)
        record = bytes([CHUNK_BYTE, FRAME_TAG]) + struct.pack(">I", len(item)) + item
        (out / "FuzzLinkRecords" / name).write_bytes(record)
    for kind, size in (("AVATAR", 300), ("ATTACHMENT", 5000)):
        (out / "FuzzLinkRecords" / f"file-{kind.lower()}").write_bytes(bytes([CHUNK_BYTE]) + file_records(kind, size))
    (out / "FuzzAdvert" / "advert").write_bytes(bytes.fromhex(ADVERT))
    (out / "FuzzAdvert" / "node-id").write_bytes(NODE_ID)
    cards = {
        "card-full": FULL_CARD,
        "card-minimal-link": "https://getknit.app/c#" + MINIMAL_CARD,
        "card-in-text": "Add me on Knit: knit://c/" + FULL_CARD + " thanks",
        "verify-code": "knit-id:v1:" + CARD_ID + ":" + CARD_BUNDLE,
    }
    for name, text in cards.items():
        (out / "FuzzContactCard" / name).write_bytes(text.encode())
    return 0


def record(tag: int, payload: bytes) -> bytes:
    return bytes([tag]) + struct.pack(">I", len(payload)) + payload


def file_records(kind: str, size: int) -> bytes:
    """A whole file, as Android streams one: its header, 2 KiB chunks and its end (`FramedLink.streamFile`)."""
    body = bytes((7 * i + 1) & 0xFF for i in range(size))
    key = hashlib.sha256(body).hexdigest()
    header = json.dumps({"kind": kind, "key": key, "mime": "image/jpeg"}, separators=(",", ":")).encode()
    chunks = b"".join(record(FILE_CHUNK_TAG, body[i : i + 2048]) for i in range(0, size, 2048))
    return record(FILE_HEADER_TAG, header) + chunks + record(FILE_END_TAG, b"")


if __name__ == "__main__":
    sys.exit(main())
