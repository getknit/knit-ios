"""What the NSFW model's scripts share: where things live, the pins that prove provenance, and the parity corpus.

The model is GantMan's `nsfw_model` MobileNetV2 140/224 from release 1.2.0, the one knit-next ships as
`app/src/main/assets/moderation/nsfw.tflite`. The release zip carries the TFLite and the SavedModel it was exported
from, so `fetch.py` checks that the zip's TFLite is byte for byte Android's before anything converts the SavedModel.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
CACHE = ROOT / ".cache"

RELEASE_URL = "https://github.com/GantMan/nsfw_model/releases/download/1.2.0/mobilenet_v2_140_224.1.zip"
ZIP = CACHE / "mobilenet_v2_140_224.1.zip"
ZIP_SHA256 = "22c0892695929639c16ea302996b8f64df9c52e7a6c1d874c1de1047bfe109f7"
SOURCE = CACHE / "src" / "mobilenet_v2_140_224"
TFLITE = SOURCE / "saved_model.tflite"
# knit-next's `app/src/main/assets/moderation/nsfw.tflite`.
ANDROID_TFLITE_SHA256 = "380f98f7685f9d8a386f8cc595b6dfcb972989aae3d1b8b270d3a4a5b96fab40"

PACKAGE = REPO / "App" / "Models" / "NSFW.mlpackage"
REFERENCE = ROOT / "parity" / "reference.json"

# The model's classes, in output order, and Android's policy over them (`NsfwImageModerator.kt`): an image is
# flagged when the scores of hentai, porn and sexy sum to at least 0.9.
CLASSES = ["drawings", "hentai", "neutral", "porn", "sexy"]
UNSAFE = (1, 3, 4)
THRESHOLD = 0.9

SIDE = 224
# A probe is a GRID × GRID picture blown up to SIDE × SIDE, so the committed corpus stays small.
GRID = 28


def quiet_tensorflow() -> None:
    """Keep TensorFlow's C++ logging to errors. Call before importing it."""
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")


def unsafe(scores) -> float:
    """The summed scores Android compares with THRESHOLD."""
    return float(sum(scores[i] for i in UNSAFE))


def tensor(item: dict) -> np.ndarray:
    """The `[SIDE, SIDE, 3]` float32 input in [0, 1] that a corpus item describes.

    Seeded items are rebuilt from numpy's PCG64 stream, which gives the same numbers everywhere for one numpy release
    (pinned in `pyproject.toml`). A probe carries its pixels, base64 of GRID × GRID × 3 bytes.
    """
    kind = item["kind"]
    if kind == "probe":
        grid = np.frombuffer(base64.b64decode(item["pixels"]), dtype=np.uint8).reshape(GRID, GRID, 3)
        return blow_up(grid.astype(np.float32) / 255)
    rng = np.random.default_rng(item["seed"])
    if kind == "noise":
        return rng.random((SIDE, SIDE, 3), dtype=np.float32)
    if kind == "blocky":
        cells = item["cells"]
        return np.kron(rng.random((cells, cells, 3), dtype=np.float32), np.ones((SIDE // cells, SIDE // cells, 1), np.float32))
    if kind == "flat":
        return np.broadcast_to(rng.random(3, dtype=np.float32), (SIDE, SIDE, 3)).copy()
    if kind == "gradient":
        start, end = rng.random(3, dtype=np.float32), rng.random(3, dtype=np.float32)
        ramp = np.linspace(0, 1, SIDE, dtype=np.float32)[:, None, None]
        across = np.broadcast_to(start + (end - start) * ramp, (SIDE, SIDE, 3))
        return (across.transpose(1, 0, 2) if item.get("axis") == 1 else across).copy()
    raise ValueError(f"unknown corpus item kind {kind!r}")


def blow_up(grid: np.ndarray) -> np.ndarray:
    """`grid` repeated to SIDE × SIDE, each cell a block of pixels."""
    scale = SIDE // grid.shape[0]
    return np.repeat(np.repeat(grid, scale, axis=0), scale, axis=1)
