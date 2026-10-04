#!/usr/bin/env python3
"""Rebuild Detoxify's checkpoint and convert it into `App/Models/Toxicity.mlpackage`, a Core ML ML program.

    uv run python convert.py           # write the package
    uv run python convert.py --check   # exit 1 unless the committed package is what this recipe writes

The inputs are `input_ids` and `attention_mask`, `[1, 128]` int32 each: the ids Android's `SentencePieceTokenizer`
makes, [CLS] first and [SEP] last, padded with zeros, and ones over the real tokens. The output is `scores`, `[1, 16]`
sigmoid probabilities in `LABELS` order, as `MlTextModerator` reads them. Weights and arithmetic are float16, which
the Neural Engine runs; `parity.py` measures what that costs.

The graph is detoxify-mobile's `SigmoidWrapper` with one change: the mask turns into an additive -10000 where
transformers adds the lowest float32, which float16 cannot hold. A masked token's weight is e^-10000 either way, so
the scores are the same, and `--check` holds the rebuilt float32 graph to the stock model before anything converts.

coremltools names a package's parts with random UUIDs, stamps the day it converted, and writes maps in no set order.
So the manifest's ids are derived from each part's path, as `tools/models/nsfw/convert.py` does, the date is dropped,
and the spec is written again in key order. That is what lets `--check` compare bytes.
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

import coremltools as ct
import numpy as np
import torch

from common import CHECKPOINT, LABELS, LENGTH, PACKAGE, THRESHOLDS, load_model

LICENSE = (
    "Apache-2.0. Detoxify, copyright Unitary (https://github.com/unitaryai/detoxify), "
    "and ALBERT base v2 (https://huggingface.co/albert/albert-base-v2)."
)
MASKED = -10000.0
PRECISIONS = {"float16": ct.precision.FLOAT16, "float32": ct.precision.FLOAT32}


class Scores(torch.nn.Module):
    """`(input_ids, attention_mask) -> sigmoid scores`, through ALBERT's own layers."""

    def __init__(self, model):
        super().__init__()
        self.model = model.eval()

    def forward(self, input_ids, attention_mask):
        albert = self.model.albert
        hidden = albert.embeddings(input_ids=input_ids.long())
        mask = (1.0 - attention_mask.float())[:, None, None, :] * MASKED
        sequence = albert.encoder(hidden, mask)[0]
        pooled = albert.pooler_activation(albert.pooler(sequence[:, 0]))
        return torch.sigmoid(self.model.classifier(pooled))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with the committed package instead of writing it")
    parser.add_argument("--precision", choices=PRECISIONS, default="float16", help="weights and arithmetic")
    parser.add_argument("--weights", choices=["int8"], help="quantize the weights, for a size comparison")
    parser.add_argument("--out", type=Path, default=PACKAGE, help="where to write the package")
    args = parser.parse_args()
    if not CHECKPOINT.exists():
        print("run fetch.py first", file=sys.stderr)
        return 1
    torch.set_num_threads(4)
    if not args.check:
        write(args.out, args.precision, args.weights)
        print(f"wrote {args.out}")
        return 0
    with tempfile.TemporaryDirectory() as scratch:
        fresh = Path(scratch) / PACKAGE.name
        write(fresh, args.precision, args.weights)
        differ = differences(fresh, PACKAGE)
    for path in differ:
        print(f"{PACKAGE.name}/{path}: differs from what convert.py writes", file=sys.stderr)
    return 1 if differ else 0


def write(package: Path, precision: str, weights: str | None) -> None:
    """Convert the checkpoint into `package`, replacing whatever is there."""
    stock = load_model()
    graph = Scores(stock).eval()
    agree(stock, graph)
    example = (torch.zeros(1, LENGTH, dtype=torch.int32), torch.ones(1, LENGTH, dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(graph, example)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=PRECISIONS[precision],
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, LENGTH), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="scores", dtype=np.float32)],
    )
    if weights == "int8":
        config = ct.optimize.coreml.OptimizationConfig(
            global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"),
        )
        model = ct.optimize.coreml.linear_quantize_weights(model, config)

    model.author = "Detoxify unbiased-small (ALBERT base v2, unbiased-albert-c8519128), converted for Knit"
    model.license = LICENSE
    model.short_description = "Scores a message against Jigsaw's toxicity labels. Knit blocks it when " + ", ".join(
        f"{label} >= {line}" for label, line in THRESHOLDS.items()
    ) + "."
    model.version = "0.1.2"
    model.input_description["input_ids"] = f"[1, {LENGTH}] int32: [CLS], the message's SentencePiece ids, [SEP], zeros"
    model.input_description["attention_mask"] = f"[1, {LENGTH}] int32: 1 over the real tokens, 0 over the padding"
    model.output_description["scores"] = f"[1, {len(LABELS)}] sigmoid: " + ", ".join(LABELS)
    model.user_defined_metadata["labels"] = ",".join(LABELS)

    if package.exists():
        shutil.rmtree(package)
    package.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(package))
    stable_spec(package / "Data" / "com.apple.CoreML" / "model.mlmodel")
    stable_manifest(package / "Manifest.json")


def stable_spec(path: Path) -> None:
    """The spec at `path` without the day it was converted, its maps written in key order."""
    from coremltools.proto import Model_pb2

    spec = Model_pb2.Model()
    spec.ParseFromString(path.read_bytes())
    del spec.description.metadata.userDefined["com.github.apple.coremltools.conversion_date"]
    path.write_bytes(spec.SerializeToString(deterministic=True))


def agree(stock, graph) -> None:
    """Fail unless the graph scores what transformers' own forward pass scores, on padded and unpadded inputs."""
    generator = torch.Generator().manual_seed(1)
    for length in (2, 9, 40, LENGTH):
        ids = torch.zeros(1, LENGTH, dtype=torch.int32)
        mask = torch.zeros(1, LENGTH, dtype=torch.int32)
        ids[0, :length] = torch.randint(5, 30000, (length,), generator=generator, dtype=torch.int32)
        ids[0, 0], ids[0, length - 1] = 2, 3
        mask[0, :length] = 1
        with torch.no_grad():
            expected = torch.sigmoid(stock(input_ids=ids.long(), attention_mask=mask.long()).logits)
            found = graph(ids, mask)
        if (worst := float((expected - found).abs().max())) > 1e-5:
            raise RuntimeError(f"the rebuilt graph is off by {worst} on {length} tokens")


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
