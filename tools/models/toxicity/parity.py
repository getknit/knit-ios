#!/usr/bin/env python3
"""Check that the Core ML package scores what Detoxify's checkpoint scores.

    uv run python parity.py --reference [--android PATH]   # on Linux: score the corpus, write parity/reference.json
    uv run python parity.py --coreml [--package PATH]      # on the Mac: score it with the package and compare

The reference is the checkpoint itself, rebuilt in float32 PyTorch (`common.load_model`), since knit-next's
`toxicity.tflite` is an int8 approximation of it. `--android` scores the corpus with that TFLite too, so the file
records how far Android's copy sits from the checkpoint; nothing is held to it.

The corpus is short messages: everyday ones, rude ones, and ones each enforced label scores high, written below, plus
the generated texts that land nearest each label's line, so the check covers the scores where a verdict turns.

Only the enforced labels decide anything (`THRESHOLDS`), so those are what `--coreml` holds to TOLERANCE, on the
Neural Engine and on the CPU Core ML falls back to. Verdicts must agree wherever the reference lies further than
TOLERANCE from a line. Every other label is held only to LOOSE, which a broken conversion would miss by far.
"""

from __future__ import annotations

import argparse
import itertools
import json
import platform
import sys
from pathlib import Path

import numpy as np

from common import ANDROID_TFLITE_SHA256, LABELS, LENGTH, PACKAGE, REFERENCE, THRESHOLDS, blocked, padded, sha256

TOLERANCE = 0.03
LOOSE = 0.1
BATCH = 32

WRITTEN = [
    "",
    "ok",
    "thanks so much, have a great day",
    "Have a great day!",
    "see you at the north gate at noon",
    "can you bring the charger when you come over",
    "I love this song so much",
    "happy birthday!! 🎉",
    "the battery is dead again",
    "my brother is gay and my mum is muslim",
    "christian and jewish families live on our street",
    "this is the worst coffee I have ever had",
    "shut up moron",
    "you are such an idiot",
    "You're an IDIOT!!!",
    "you are a complete idiot and everyone hates you",
    "this is fucking ridiculous",
    "what the hell is wrong with you",
    "kys",
    "die in a fire loser",
    "I will find you and hurt you",
    "I am going to find you and hurt you.",
    "I am going to kill you",
    "I will kill you and your whole family",
    "I'm going to beat you until you stop breathing",
    "people of that religion are subhuman",
    "those people are subhuman and should be wiped out",
    "those people are subhuman and should be exterminated",
    "all of them are filthy animals and should be gassed",
    "I will shoot you in the head",
    "I swear I will stab you to death",
    "all muslims are terrorists and animals",
    "muslims should all be deported and killed",
    "gay people are disgusting perverts",
    "send me nudes",
    "I want to fuck you so hard",
    "suck my dick",
    "she sucked his cock and swallowed",
]

# Generated messages: every subject with every phrase. The ones that land nearest each line join the corpus.
SUBJECTS = ["you", "he", "she", "they", "those people", "people like you", "that whole family", "your friends"]
PHRASES = [
    "should be shot", "deserve to die", "will be found and hurt", "are going to get stabbed", "should be burned alive",
    "are vermin", "are less than human", "are a disease", "are worthless trash", "are stupid", "are annoying",
    "should go back where they came from", "want to suck my cock", "are a cheap whore", "love anal sex",
    "need a good fuck", "are sexy", "are hot", "are kind", "are late again",
]
TARGETS = (-0.15, -0.05, -0.02, 0.0, 0.02, 0.05)


def reference(android: Path | None) -> int:
    import torch

    from common import encode, load_model, tokenizer

    torch.set_num_threads(4)
    model = load_model()
    words = tokenizer()

    def score(texts: list[str]) -> list[list[float]]:
        found = []
        for start in range(0, len(texts), BATCH):
            inputs = [padded(encode(words, text)) for text in texts[start : start + BATCH]]
            ids = torch.from_numpy(np.concatenate([i for i, _ in inputs])).long()
            mask = torch.from_numpy(np.concatenate([m for _, m in inputs])).long()
            with torch.no_grad():
                found += torch.sigmoid(model(input_ids=ids, attention_mask=mask).logits).tolist()
        return found

    pool = [f"{subject} {phrase}" for subject, phrase in itertools.product(SUBJECTS, PHRASES)]
    pooled = score(pool)
    chosen = []
    for label, line in THRESHOLDS.items():
        column = LABELS.index(label)
        for target in TARGETS:
            nearest = min(range(len(pool)), key=lambda i: abs(pooled[i][column] - (line + target)))
            if pool[nearest] not in WRITTEN + chosen:
                chosen.append(pool[nearest])
    texts = WRITTEN + chosen
    scores = score(texts)
    tflite = android_scores(android, [encode(words, t) for t in texts]) if android else None

    items = []
    for i, text in enumerate(texts):
        item = {"text": text, "ids": encode(words, text), "scores": [round(s, 6) for s in scores[i]]}
        if tflite:
            item["android"] = [round(s, 6) for s in tflite[i]]
        items.append(item)
    REFERENCE.parent.mkdir(exist_ok=True)
    REFERENCE.write_text(json.dumps({"tolerance": TOLERANCE, "thresholds": THRESHOLDS, "items": items}, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {len(items)} items to {REFERENCE.name}")
    report("checkpoint", items, "scores")
    if tflite:
        worst = max(abs(a - b) for item in items for a, b in zip(enforced(item["android"]), enforced(item["scores"])))
        turned = [item["text"] for item in items if blocked(item["android"]) != blocked(item["scores"])]
        print(f"Android's int8 TFLite: worst enforced label {worst:.4f}; verdicts that differ: {turned or 'none'}")
    return 0


def android_scores(path: Path, encoded: list[list[int]]) -> list[list[float]]:
    """Android's TFLite at `path`, fed as its export orders the inputs: ids first, then the mask."""
    from ai_edge_litert.interpreter import Interpreter

    if (found := sha256(path)) != ANDROID_TFLITE_SHA256:
        raise SystemExit(f"{path}: sha256 {found} is not knit-next's toxicity.tflite")
    interpreter = Interpreter(model_path=str(path), num_threads=4)
    interpreter.allocate_tensors()
    ids_in, mask_in = interpreter.get_input_details()
    out = interpreter.get_output_details()[0]
    found = []
    for ids in encoded:
        tokens, mask = padded(ids)
        interpreter.set_tensor(ids_in["index"], tokens.astype(ids_in["dtype"]))
        interpreter.set_tensor(mask_in["index"], mask.astype(mask_in["dtype"]))
        interpreter.invoke()
        found.append([float(s) for s in interpreter.get_tensor(out["index"])[0]])
    return found


def enforced(scores) -> list[float]:
    return [scores[LABELS.index(label)] for label in THRESHOLDS]


def report(name: str, items: list[dict], key: str) -> None:
    print(f"{name}: enforced labels ({', '.join(THRESHOLDS)})")
    for item in items:
        print(f"  {' '.join(f'{s:.3f}' for s in enforced(item[key]))}  {blocked(item[key]) or ''}  {item['text']!r}")


def coreml(package: Path) -> int:
    if platform.system() != "Darwin":
        print("--coreml runs Core ML, which only macOS has", file=sys.stderr)
        return 2
    import coremltools as ct

    corpus = json.loads(REFERENCE.read_text())
    failed = False
    for units in (ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY):
        model = ct.models.MLModel(str(package), compute_units=units)
        worst_enforced, worst_other, turned = 0.0, 0.0, []
        for item in corpus["items"]:
            expected = np.array(item["scores"])
            ids, mask = padded(item["ids"])
            found = model.predict({"input_ids": ids, "attention_mask": mask})["scores"][0]
            off = np.abs(found - expected)
            columns = [LABELS.index(label) for label in THRESHOLDS]
            by_enforced = float(off[columns].max())
            by_other = float(np.delete(off, columns).max())
            worst_enforced, worst_other = max(worst_enforced, by_enforced), max(worst_other, by_other)
            if by_enforced > TOLERANCE or by_other > LOOSE:
                failed = True
                print(f"{units.name}: {item['text']!r} scores {np.round(found, 3)} against {np.round(expected, 3)}", file=sys.stderr)
            if blocked(found) != blocked(expected):
                turned.append(item["text"])
                near = any(abs(expected[LABELS.index(label)] - line) <= TOLERANCE for label, line in THRESHOLDS.items())
                if not near:
                    failed = True
                    print(f"{units.name}: {item['text']!r}'s verdict turned: {blocked(found)} against {blocked(expected)}", file=sys.stderr)
        print(
            f"{units.name}: {len(corpus['items'])} items; worst enforced label {worst_enforced:.4f}, worst other {worst_other:.4f}; "
            f"verdicts turned within {TOLERANCE} of a line: {turned or 'none'}"
        )
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--reference", action="store_true", help="score the corpus with the checkpoint (Linux)")
    mode.add_argument("--coreml", action="store_true", help="compare the Core ML package with the reference (macOS)")
    parser.add_argument("--android", type=Path, help="knit-next's toxicity.tflite, to record its scores beside the reference")
    parser.add_argument("--package", type=Path, default=PACKAGE, help="the Core ML package to check")
    args = parser.parse_args()
    return reference(args.android) if args.reference else coreml(args.package)


if __name__ == "__main__":
    sys.exit(main())
