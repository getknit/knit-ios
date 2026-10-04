#!/usr/bin/env python3
"""Score photos the way Knit for Android does, for comparing with what an iPhone's debug bridge reports.

    uv run python score.py PHOTO...          # one line per photo
    uv run python score.py --json PHOTO...   # the same as JSON lines

This runs Android's TFLite on Linux, after preprocessing that follows `ImageDecode.decodeBoundedFromBytes` and
`NsfwImageModerator.infer`:

1. Decode the first frame, without applying EXIF orientation, at the largest power-of-two reduction that keeps
    both sides at least 512 pixels.
2. Scale the longer side down to 512, keeping the aspect ratio, bilinear.
3. Stretch to 224 × 224, bilinear, and divide RGB by 255. A fully transparent pixel reads as black, as Android's
    un-premultiplied pixels do. Alpha is otherwise dropped.

Pillow reduces with a box filter where Android's JPEG decoder scales in the DCT, and it ignores embedded colour
profiles, so expect small differences from a phone. Keep the photos you score outside the repository.
"""

from __future__ import annotations

import argparse
import json
import sys

from common import CLASSES, SIDE, THRESHOLD, TFLITE, quiet_tensorflow, unsafe

BOUND = 512


def preprocess(path: str):
    import numpy as np
    from PIL import Image

    with Image.open(path) as source:
        source.seek(0)
        image = source.convert("RGBA")
    width, height = image.size
    sample = 1
    while width // (sample * 2) >= BOUND and height // (sample * 2) >= BOUND:
        sample *= 2
    if sample > 1:
        image = image.reduce(sample)
    width, height = image.size
    if max(width, height) > BOUND:
        scale = BOUND / max(width, height)
        image = image.resize((max(1, int(width * scale)), max(1, int(height * scale))), Image.BILINEAR)
    pixels = np.asarray(image.resize((SIDE, SIDE), Image.BILINEAR), dtype=np.float32)
    rgb = np.where(pixels[..., 3:4] == 0, 0, pixels[..., :3])
    return (rgb / 255)[None]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--json", action="store_true", help="print JSON lines")
    parser.add_argument("photos", nargs="+")
    args = parser.parse_args()

    quiet_tensorflow()
    import tensorflow as tf

    interpreter = tf.lite.Interpreter(model_path=str(TFLITE), num_threads=4)
    interpreter.allocate_tensors()
    feed, fetch = interpreter.get_input_details()[0]["index"], interpreter.get_output_details()[0]["index"]
    for photo in args.photos:
        interpreter.set_tensor(feed, preprocess(photo))
        interpreter.invoke()
        scores = [float(s) for s in interpreter.get_tensor(fetch)[0]]
        flagged = unsafe(scores) >= THRESHOLD
        if args.json:
            print(json.dumps({"photo": photo, "scores": scores, "unsafe": unsafe(scores), "flagged": flagged}))
        else:
            named = "  ".join(f"{name} {score:.4f}" for name, score in zip(CLASSES, scores))
            print(f"{photo}: {named}  unsafe {unsafe(scores):.4f}{'  FLAGGED' if flagged else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
