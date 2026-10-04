#!/usr/bin/env python3
"""Score messages as the iPhone's model should, to hold its debug bridge's `screen-text` replies to.

    uv run python score.py "a message" "another"            # the checkpoint, in float32
    uv run python score.py --android PATH "a message" ...   # and knit-next's toxicity.tflite beside it

Each text is tokenized by Android's tokenizer.json, as `SentencePieceTokenizer` does it on both phones, and scored by
Detoxify's checkpoint rebuilt in PyTorch: what `Toxicity.mlpackage` approximates in float16. `--android` adds the scores
of Android's int8 TFLite. The enforced labels print with the label that blocks, if any.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

from common import LABELS, THRESHOLDS, blocked, encode, padded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("texts", nargs="+", help="the messages to score")
    parser.add_argument("--android", type=Path, help="knit-next's toxicity.tflite, to score beside the checkpoint")
    args = parser.parse_args()

    import torch

    from common import load_model, tokenizer
    from parity import android_scores

    torch.set_num_threads(4)
    model = load_model()
    words = tokenizer()
    encoded = [encode(words, text) for text in args.texts]
    android = android_scores(args.android, encoded) if args.android else None
    print("labels: " + ", ".join(THRESHOLDS))
    for i, (text, ids) in enumerate(zip(args.texts, encoded)):
        tokens, mask = padded(ids)
        with torch.no_grad():
            scores = torch.sigmoid(model(input_ids=torch.from_numpy(tokens).long(), attention_mask=torch.from_numpy(mask).long()).logits)
        rows = [("checkpoint", scores[0].tolist())] + ([("android", android[i])] if android else [])
        print(repr(text))
        for name, row in rows:
            enforced = " ".join(f"{row[LABELS.index(label)]:.4f}" for label in THRESHOLDS)
            print(f"  {name:10s} {enforced}  blocks {blocked(row) or 'nothing'}  (all: {np.round(row, 4).tolist()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
