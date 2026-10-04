#!/usr/bin/env python3
"""Convert the SavedModel `fetch.py` unpacked into `App/Models/NSFW.mlpackage`, a Core ML ML program.

    uv run python convert.py           # write the package
    uv run python convert.py --check   # exit 1 unless the committed package is what this recipe writes

The input is `image`, `[1, 224, 224, 3]` float32 RGB divided by 255, the same tensor Android's
`NsfwImageModerator.toInputBuffer` fills. The output is `scores`, `[1, 5]` softmax probabilities in `CLASSES` order.
Weights and arithmetic are float16, which the Neural Engine runs; `parity.py` measures what that costs.

coremltools names a package's parts with random UUIDs, so the manifest is rewritten with ids derived from each part's
path. The rest of its output is already the same on every run, which is what lets `--check` compare bytes.
"""

from __future__ import annotations

import argparse
import filecmp
import json
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

from common import CLASSES, PACKAGE, SIDE, SOURCE, THRESHOLD, UNSAFE, quiet_tensorflow

quiet_tensorflow()

import coremltools as ct  # noqa: E402
import numpy as np  # noqa: E402

LICENSE = "MIT. Copyright (c) 2020 The nsfw_model Developers. https://github.com/GantMan/nsfw_model"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with the committed package instead of writing it")
    args = parser.parse_args()
    if not SOURCE.exists():
        print("run fetch.py first", file=sys.stderr)
        return 1
    if not args.check:
        write(PACKAGE)
        print(f"wrote {PACKAGE}")
        return 0
    with tempfile.TemporaryDirectory() as scratch:
        fresh = Path(scratch) / PACKAGE.name
        write(fresh)
        differ = differences(fresh, PACKAGE)
    for path in differ:
        print(f"{PACKAGE.name}/{path}: differs from what convert.py writes", file=sys.stderr)
    return 1 if differ else 0


def write(package: Path) -> None:
    """Convert the SavedModel into `package`, replacing whatever is there."""
    model = ct.convert(
        str(SOURCE),
        source="tensorflow",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="input", shape=(1, SIDE, SIDE, 3), dtype=np.float32)],
    )
    spec = model.get_spec()
    ct.utils.rename_feature(spec, "input", "image")
    ct.utils.rename_feature(spec, spec.description.output[0].name, "scores")
    model = ct.models.MLModel(spec, weights_dir=model.weights_dir)

    model.author = "GantMan nsfw_model 1.2.0 (MobileNetV2 140/224), converted for Knit"
    model.license = LICENSE
    model.short_description = (
        "Scores a photo against five classes. Knit flags it when "
        + " + ".join(CLASSES[i] for i in UNSAFE)
        + f" >= {THRESHOLD}."
    )
    model.version = "1.2.0"
    model.input_description["image"] = f"[1, {SIDE}, {SIDE}, 3] float32: RGB / 255, stretched to {SIDE} x {SIDE}"
    model.output_description["scores"] = "[1, 5] softmax: " + ", ".join(CLASSES)
    model.user_defined_metadata["classes"] = ",".join(CLASSES)

    if package.exists():
        shutil.rmtree(package)
    package.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(package))
    stable_manifest(package / "Manifest.json")


def stable_manifest(manifest: Path) -> None:
    """`manifest` with each part's UUID derived from its path, in the repository's JSON style."""
    contents = json.loads(manifest.read_text())
    renamed = {old: str(uuid.uuid5(uuid.NAMESPACE_URL, "knit:" + entry["path"])) for old, entry in contents["itemInfoEntries"].items()}
    contents["itemInfoEntries"] = {renamed[old]: entry for old, entry in contents["itemInfoEntries"].items()}
    contents["rootModelIdentifier"] = renamed[contents["rootModelIdentifier"]]
    manifest.write_text(json.dumps(contents, indent=2, sort_keys=True) + "\n")


def differences(fresh: Path, committed: Path) -> list[str]:
    """The files that differ between two packages, or that only one of them has."""
    found = []
    names = {p.relative_to(fresh) for p in fresh.rglob("*") if p.is_file()}
    names |= {p.relative_to(committed) for p in committed.rglob("*") if p.is_file()}
    for name in sorted(names):
        left, right = fresh / name, committed / name
        if not (left.is_file() and right.is_file() and filecmp.cmp(left, right, shallow=False)):
            found.append(str(name))
    return found


if __name__ == "__main__":
    sys.exit(main())
