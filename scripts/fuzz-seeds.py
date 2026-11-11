#!/usr/bin/env python3
"""Write a seed corpus for each harness in Fuzz/ from knit-next's golden vectors.

    python3 scripts/fuzz-seeds.py <directory>

FuzzCBOR gets every golden CBOR item, FuzzLinkRecords gets the same items framed as link records (a chunk-size
byte, then a FRAME record), whole files as Android streams them (a FILE_HEADER, chunks and a FILE_END), and a file cut
by a KEEPALIVE, the harness's cut, then resumed from its offset under a header whose size is Int64's largest, and
FuzzAdvert gets a pinned advert and a node id, FuzzContactCard knit-next's two contact card vectors in their link forms
and a verify code (docs/CONTACT_CARD.md §5), and FuzzExiflessJPEG small JPEGs carrying an orientation in a little-endian
(II) and a big-endian (MM) EXIF, the two real EXIF blocks from knit-ios #12 (Knit for Android's and the one Photos wrote
over it, as KnitTestSupport's JPEGFixture pins them), an XMP APP1 alone, and a trailer after EOI. FuzzLinkPreview gets
knit-next's two link-preview card vectors and a few addresses a card's check must judge. `scripts/fuzz.sh` calls
this into a scratch directory; the committed Fuzz/Corpus/ holds only inputs that once found a bug.
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAME_TAG = 1
FILE_HEADER_TAG, FILE_CHUNK_TAG, FILE_END_TAG, KEEPALIVE_TAG = 2, 3, 4, 5
CHUNK_BYTE = 7
ADVERT = "ff294213fa67091e03c2f2ae8d071b9d6700000000008100"
# keyed-v1.json's blind.advert.blinded: a tag in bytes 1-16 and FLAG_BLINDED (knit-next ADR 2026-11.xp6d).
BLINDED_ADVERT = "09ce739614ce56f79934b596a624f70cf00000000000830c"
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
# The EXIF APP1 segments from knit-ios #12, from their FF E1 (Tests/KnitTestSupport/JPEGFixture.swift).
ANDROID_EXIF = "ffe100344578696600004d4d002a00000008000187690004000000010000001a00000000000190000007000000043032333200000000"
APPLE_EXIF = (
    "ffe1012c4578696600004d4d002a000000080006011200030000000100010000011a00050000000100000056011b0005000000010000005e"
    "012800030000000100020000021300030000000100010000876900040000000100000066000000c00000004800000001000000480000"
    "00010007900000070000000430323332910100070000000401020300a00000070000000430313030a00100030000000100010000a002"
    "000400000001000003c3a00300040000000100000500a40600030000000100000000000000000006010300030000000100060000011a"
    "0005000000010000010e011b0005000000010000011601280003000000010002000002010004000000010000011e02020004000000"
    "01000000040000000000000048000000010000004800000001ffd8ffd90000"
)
MINIMAL_CARD = (
    "omRib2R5WGijYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
    "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmNz"
    "aWdYQLL2FdNZ6dxdvl8HfEBnbj8yNsSoGoCPELMEIXuO6kA04Ra6SeNRPkpg1UGmp1ZQgU3qjVOp"
    "M6JdH3puOvfihQA"
)


# Pages a sender's fetch might read, for FuzzOpenGraph: Open Graph tags with a relative picture, Twitter's alone, a title
# alone in a script-laden head, a Latin-1 page that says so, and a redirect pair (a base, a newline, a reference).
PAGES = {
    "page-og": b"<html><head><meta property='og:title' content='A &amp; B'><meta property=og:description "
    b"content=\"Desc\"><meta property='og:image' content='../img/a.jpg'></head></html>",
    "page-twitter": b"<meta name=twitter:title content='T'><meta name='twitter:image' content='//cdn.example.com/x.png'>",
    "page-title": b"<head><script>var s = '<title>no</title>';</script><!-- <meta property=og:title content=x> -->"
    b"<title>  The &#8220;real&#x201D; one </title></head>",
    "page-latin1": b"<meta charset=iso-8859-1><title>Caf\xe9</title>",
    "page-bom": b"\xef\xbb\xbf<title>BOM</title>",
    "redirect-pair": b"https://example.com/a/b/c?q\n../../d;p?y#f",
}

def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    vectors = json.loads((ROOT / "Tests" / "Vectors" / "wire-v1.json").read_text(encoding="utf-8"))["vectors"]
    for harness in (
        "FuzzCBOR", "FuzzLinkRecords", "FuzzAdvert", "FuzzContactCard", "FuzzExiflessJPEG", "FuzzLinkPreview", "FuzzOpenGraph"
    ):
        (out / harness).mkdir(parents=True, exist_ok=True)
    for name, hexed in vectors.items():
        item = bytes.fromhex(hexed)
        (out / "FuzzCBOR" / name).write_bytes(item)
        record = bytes([CHUNK_BYTE, FRAME_TAG]) + struct.pack(">I", len(item)) + item
        (out / "FuzzLinkRecords" / name).write_bytes(record)
    for kind, size in (("AVATAR", 300), ("ATTACHMENT", 5000)):
        (out / "FuzzLinkRecords" / f"file-{kind.lower()}").write_bytes(bytes([CHUNK_BYTE]) + file_records(kind, size))
    (out / "FuzzLinkRecords" / "file-resumed").write_bytes(bytes([CHUNK_BYTE]) + resumed_records(6000, 4096))
    (out / "FuzzAdvert" / "advert").write_bytes(bytes.fromhex(ADVERT))
    (out / "FuzzAdvert" / "advert-blinded").write_bytes(bytes.fromhex(BLINDED_ADVERT))
    (out / "FuzzAdvert" / "node-id").write_bytes(NODE_ID)
    cards = {
        "card-full": FULL_CARD,
        "card-minimal-link": "https://getknit.app/c#" + MINIMAL_CARD,
        "card-in-text": "Add me on Knit: knit://c/" + FULL_CARD + " thanks",
        "verify-code": "knit-id:v1:" + CARD_ID + ":" + CARD_BUNDLE,
    }
    for name, text in cards.items():
        (out / "FuzzContactCard" / name).write_bytes(text.encode())
    pictures = {
        "jpeg-ii-orientation": jpeg([exif(orientation_tiff(6, little=True))]),
        "jpeg-mm-orientation": jpeg([exif(orientation_tiff(8, little=False))]),
        "jpeg-android-exif": jpeg([bytes.fromhex(ANDROID_EXIF)]),
        "jpeg-apple-exif": jpeg([bytes.fromhex(APPLE_EXIF)]),
        "jpeg-xmp": jpeg([]),
        "jpeg-trailer": jpeg([exif(orientation_tiff(1, little=False))], trailer=b"\xff\xd8a gain map\xff\xd9"),
    }
    for name, picture in pictures.items():
        (out / "FuzzExiflessJPEG" / name).write_bytes(picture)
    for name in ("linkPreviewBlob", "linkPreviewBlobTextOnly"):
        (out / "FuzzLinkPreview" / name).write_bytes(bytes.fromhex(vectors[name]))
    addresses = {
        "url-plain": "https://example.com/a?b=c#d",
        "url-user-info": "https://bank.example@evil.example/",
        "url-ipv4": "https://1.2.3.4:443/x",
        "url-registry": "https://b\u00fccher.de/",
        "url-escape": "https://example.com/a%2Fb?q=%zz",
    }
    for name, address in addresses.items():
        (out / "FuzzLinkPreview" / name).write_bytes(address.encode())
    for name, page in PAGES.items():
        (out / "FuzzOpenGraph" / name).write_bytes(page)
    return 0


def segment(marker: int, payload: bytes) -> bytes:
    """A JPEG segment: FF, its marker, its big-endian length counting itself, then its payload."""
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload


def exif(tiff: bytes) -> bytes:
    return segment(0xE1, b"Exif\0\0" + tiff)


def orientation_tiff(orientation: int, little: bool) -> bytes:
    """A TIFF whose IFD0 holds one entry, the orientation as one SHORT."""
    order = "<" if little else ">"
    header = b"II*\0" if little else b"MM\0*"
    entry = struct.pack(order + "HHIH", 0x0112, 3, 1, orientation) + b"\0\0"
    return header + struct.pack(order + "IH", 8, 1) + entry + struct.pack(order + "I", 0)


def jpeg(exifs: list[bytes], trailer: bytes = b"") -> bytes:
    """A small baseline JPEG, as JPEGFixture.jpeg builds one: SOI, APP0, the EXIF segments, an XMP APP1, the tables, a
    frame, a scan with a stuffed FF 00 and a restart marker, EOI, then the trailer."""
    xmp = segment(0xE1, b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>")
    tables = segment(0xDB, bytes(65)) + segment(0xC0, bytes([8, 0, 16, 0, 16, 1, 1, 0x11, 0])) + segment(0xC4, bytes(20))
    scan = segment(0xDA, bytes([1, 1, 0, 0, 0x3F, 0])) + bytes([0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56])
    app0 = segment(0xE0, b"JFIF\0" + bytes([1, 1, 0, 0, 1, 0, 1, 0, 0]))
    return b"\xff\xd8" + app0 + b"".join(exifs) + xmp + tables + scan + b"\xff\xd9" + trailer


def record(tag: int, payload: bytes) -> bytes:
    return bytes([tag]) + struct.pack(">I", len(payload)) + payload


def file_records(kind: str, size: int) -> bytes:
    """A whole file, as Android streams one: its header, 2 KiB chunks and its end (`FramedLink.streamFile`)."""
    body = bytes((7 * i + 1) & 0xFF for i in range(size))
    key = hashlib.sha256(body).hexdigest()
    header = json.dumps({"kind": kind, "key": key, "mime": "image/jpeg"}, separators=(",", ":")).encode()
    chunks = b"".join(record(FILE_CHUNK_TAG, body[i : i + 2048]) for i in range(0, size, 2048))
    return record(FILE_HEADER_TAG, header) + chunks + record(FILE_END_TAG, b"")


def resumed_records(size: int, cut: int) -> bytes:
    """A file cut after `cut` bytes, then its tail under a resumed header (`FileHeaderWire`'s `offset`, knit-ios #2) whose
    size is the largest a Kotlin Long holds, which no sum may trap on. The body is picked so the harness keeps its key."""
    seed = 1
    while True:
        body = bytes((seed * i + 1) & 0xFF for i in range(size))
        key = hashlib.sha256(body).hexdigest()
        if key[0] < "8":
            break
        seed += 2
    whole = json.dumps({"kind": "ATTACHMENT", "key": key, "mime": "image/jpeg", "size": size}, separators=(",", ":"))
    resumed = json.dumps(
        {"kind": "ATTACHMENT", "key": key, "mime": "image/jpeg", "size": 2**63 - 1, "offset": cut}, separators=(",", ":")
    )
    head = b"".join(record(FILE_CHUNK_TAG, body[i : min(i + 2048, cut)]) for i in range(0, cut, 2048))
    tail = b"".join(record(FILE_CHUNK_TAG, body[i : i + 2048]) for i in range(cut, size, 2048))
    return (
        record(FILE_HEADER_TAG, whole.encode())
        + head
        + record(KEEPALIVE_TAG, b"")
        + record(FILE_HEADER_TAG, resumed.encode())
        + tail
        + record(FILE_END_TAG, b"")
    )


if __name__ == "__main__":
    sys.exit(main())
