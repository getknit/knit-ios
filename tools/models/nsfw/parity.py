#!/usr/bin/env python3
"""Check that the Core ML package scores what Android's TFLite scores.

    uv run python parity.py --reference   # on Linux: build the corpus, score it with the TFLite, write parity/reference.json
    uv run python parity.py --coreml      # on the Mac: score the same corpus with App/Models/NSFW.mlpackage and compare

The corpus is synthetic, so nothing in the repository is a photo of anything:

- seeded inputs (noise, blocks, flat colours, gradients), which numpy rebuilds from their seeds;
- probes, GRID × GRID pictures that gradient ascent through the SavedModel pushed toward each class and onto
    THRESHOLD, so the check covers the scores where a verdict turns. Their pixels are committed.

Every input is scored by the TFLite knit-next ships. A verdict reads only the unsafe sum, so that is what `--coreml`
holds to TOLERANCE, on the Neural Engine and on the CPU Core ML falls back to; verdicts must agree wherever the
reference lies further than TOLERANCE from THRESHOLD. Each class is held only to CLASS_TOLERANCE, which a broken
conversion would miss by far.

The package is float16 by the maintainer's choice (2026-10-04): it is half the size of float32, which matched the
TFLite exactly. Measured over this corpus, float16 moved a class by 0.027 at most on the Neural Engine and 0.080 on
the CPU, both on a flat colour, and the unsafe sum by 0.006 and 0.016.
"""

from __future__ import annotations

import argparse
import base64
import json
import platform
import sys

import numpy as np

from common import CLASSES, GRID, PACKAGE, REFERENCE, SIDE, THRESHOLD, TFLITE, UNSAFE, blow_up, quiet_tensorflow, tensor, unsafe

TOLERANCE = 0.02
CLASS_TOLERANCE = 0.1
THREADS = 4

SEEDED = (
    [{"kind": "noise", "seed": seed} for seed in (1, 2, 3)]
    + [{"kind": "blocky", "cells": cells, "seed": 10 + cells} for cells in (4, 8, 16, 32)]
    + [{"kind": "flat", "seed": seed} for seed in (20, 21, 22)]
    + [{"kind": "gradient", "seed": seed, "axis": seed % 2} for seed in (30, 31, 32, 33)]
)
CLASS_PROBES = [(c, seed) for c in range(len(CLASSES)) for seed in (40, 41)]
BOUNDARY_PROBES = [(target, 50 + i) for i, target in enumerate((0.80, 0.85, 0.88, 0.90, 0.92, 0.95))]


def reference() -> int:
    quiet_tensorflow()
    import tensorflow as tf

    # A shared machine: four threads are plenty for one small model.
    tf.config.threading.set_intra_op_parallelism_threads(THREADS)
    tf.config.threading.set_inter_op_parallelism_threads(THREADS)
    interpreter = tf.lite.Interpreter(model_path=str(TFLITE), num_threads=THREADS)
    interpreter.allocate_tensors()
    feed, fetch = interpreter.get_input_details()[0]["index"], interpreter.get_output_details()[0]["index"]

    def tflite(x: np.ndarray) -> list[float]:
        interpreter.set_tensor(feed, x[None].astype(np.float32))
        interpreter.invoke()
        return [float(s) for s in interpreter.get_tensor(fetch)[0]]

    # The loaded module owns the signature's variables, so it has to outlive every call.
    saved = tf.saved_model.load(str(TFLITE.parent))
    serving = saved.signatures["serving_default"]
    probes = [
        {"name": f"probe-{CLASSES[c]}-{seed}", "kind": "probe", "pixels": probe(serving, seed, lambda p, c=c: -tf.math.log(p[c] + 1e-7))}
        for c, seed in CLASS_PROBES
    ] + [
        {"name": f"probe-boundary-{target:.2f}", "kind": "probe", "pixels": probe(serving, seed, lambda p, t=target: 100 * (unsafe_tf(p) - t) ** 2)}
        for target, seed in BOUNDARY_PROBES
    ]
    seeded = [{"name": "-".join(str(v) for v in item.values()), **item} for item in SEEDED]

    items, drift = [], 0.0
    for item in seeded + probes:
        x = tensor(item)
        scores = tflite(x)
        drift = max(drift, float(np.max(np.abs(serving(input=tf.constant(x[None]))["prediction"].numpy()[0] - scores))))
        items.append({**item, "scores": [round(s, 6) for s in scores]})
    REFERENCE.parent.mkdir(exist_ok=True)
    REFERENCE.write_text(json.dumps({"tolerance": TOLERANCE, "threshold": THRESHOLD, "items": items}, indent=2) + "\n")
    print(f"wrote {len(items)} items to {REFERENCE.name}; SavedModel and TFLite differ by at most {drift:.2e}")
    for item in items:
        print(f"  {item['name']:28s} unsafe {unsafe(item['scores']):.4f}")
    return 0


def unsafe_tf(p):
    return sum(p[i] for i in UNSAFE)


def probe(serving, seed: int, loss, steps: int = 200, rate: float = 0.05) -> str:
    """A GRID × GRID picture that minimises `loss` over the SavedModel's scores, as base64 bytes."""
    import tensorflow as tf

    rng = np.random.default_rng(seed)
    logits = tf.Variable(rng.normal(0, 0.5, (GRID, GRID, 3)).astype(np.float32))
    optimiser = tf.keras.optimizers.Adam(rate)
    for _ in range(steps):
        with tf.GradientTape() as tape:
            x = tf.sigmoid(logits)
            x = tf.repeat(tf.repeat(x, SIDE // GRID, axis=0), SIDE // GRID, axis=1)
            cost = loss(serving(input=x[None])["prediction"][0])
        optimiser.apply_gradients([(tape.gradient(cost, logits), logits)])
    pixels = np.round(tf.sigmoid(logits).numpy() * 255).astype(np.uint8)
    assert blow_up(pixels).shape == (SIDE, SIDE, 3)
    return base64.b64encode(pixels.tobytes()).decode()


def coreml() -> int:
    if platform.system() != "Darwin":
        print("--coreml runs Core ML, which only macOS has", file=sys.stderr)
        return 2
    import coremltools as ct

    corpus = json.loads(REFERENCE.read_text())
    failed = False
    for units in (ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY):
        model = ct.models.MLModel(str(PACKAGE), compute_units=units)
        worst_class, worst_sum, turned = 0.0, 0.0, []
        for item in corpus["items"]:
            expected = np.array(item["scores"])
            found = model.predict({"image": tensor(item)[None]})["scores"][0]
            by_class, by_sum = float(np.max(np.abs(found - expected))), abs(unsafe(found) - unsafe(expected))
            worst_class, worst_sum = max(worst_class, by_class), max(worst_sum, by_sum)
            if by_class > CLASS_TOLERANCE or by_sum > TOLERANCE:
                failed = True
                print(f"{units.name}: {item['name']} scores {np.round(found, 4)} against {np.round(expected, 4)}", file=sys.stderr)
            if (unsafe(found) >= THRESHOLD) != (unsafe(expected) >= THRESHOLD):
                turned.append(item["name"])
                if abs(unsafe(expected) - THRESHOLD) > TOLERANCE:
                    failed = True
                    print(f"{units.name}: {item['name']}'s verdict turned: {unsafe(found):.4f} against {unsafe(expected):.4f}", file=sys.stderr)
        print(
            f"{units.name}: {len(corpus['items'])} items; worst class {worst_class:.4f}, worst unsafe sum {worst_sum:.4f}; "
            f"verdicts turned within {TOLERANCE} of {THRESHOLD}: {turned or 'none'}"
        )
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--reference", action="store_true", help="score the corpus with the TFLite (Linux)")
    mode.add_argument("--coreml", action="store_true", help="compare the Core ML package with the reference (macOS)")
    args = parser.parse_args()
    return reference() if args.reference else coreml()


if __name__ == "__main__":
    sys.exit(main())
