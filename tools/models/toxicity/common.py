"""What the toxicity model's scripts share: where things live, the pins that prove provenance, and how a text becomes
the model's input.

The model is Detoxify's `unbiased-small`, an ALBERT base v2 fine-tuned on Jigsaw's Unintended Bias data, which
knit-next ships as `app/src/main/assets/moderation/toxicity.tflite` after detoxify-mobile converts it. That TFLite is
dynamic int8, which coremltools cannot read, so `convert.py` starts where detoxify-mobile did: the checkpoint Detoxify
publishes, pinned by its SHA-256, rebuilt as `AlbertForSequenceClassification` with a sigmoid on top
(detoxify-mobile's `src/common.py`). The tokenizer and the word list are Android's own files, pinned the same way.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
CACHE = ROOT / ".cache"

CHECKPOINT_URL = "https://github.com/unitaryai/detoxify/releases/download/v0.1.2/unbiased-albert-c8519128.ckpt"
CHECKPOINT = CACHE / "unbiased-albert-c8519128.ckpt"
# detoxify-mobile's README pins the same hash, and the file's name carries its first eight digits.
CHECKPOINT_SHA256 = "c8519128cfebd26936383f49411afb4bb94800cc3b59c10c28ca65afb5b95753"

MODELS = REPO / "App" / "Models"
PACKAGE = MODELS / "Toxicity.mlpackage"
# knit-next's `app/src/main/assets/moderation/tokenizer.json`, byte for byte: ALBERT base v2's SentencePiece unigram
# vocabulary as transformers saves it, which the Swift tokenizer reads as Android's Kotlin one does.
TOKENIZER = MODELS / "ToxicityTokenizer.json"
ANDROID_TOKENIZER_SHA256 = "77e18685566ddefc3267601b473a3c55aa6fa2735611e1eae67dee9a27e4d966"
# knit-next's `app/src/main/assets/moderation/profanity_en.txt`, byte for byte: the room's word list, which
# knit-next's `scripts/gen-profanity-list.py` derives from dsojevic/profanity-list.
PROFANITY = MODELS / "Profanity.txt"
ANDROID_PROFANITY_SHA256 = "33f3ecf64ef23f819508a5b4fb5df58843f8ca2bf430392c6b5a3faab2de9ff5"
# knit-next's `app/src/main/assets/moderation/toxicity.tflite`, which `parity.py --reference --android` scores too.
ANDROID_TFLITE_SHA256 = "5edb906c77e7b872f7e53eac15968da238f7b0fadd26e7b497ef22f72fac8a39"

REFERENCE = ROOT / "parity" / "reference.json"

# The model's outputs, in head order: Jigsaw's seven toxicity labels, then nine identity columns that name a topic
# (knit-next's `labels.txt`).
LABELS = [
    "toxicity", "severe_toxicity", "obscene", "identity_attack", "insult", "threat", "sexual_explicit",
    "male", "female", "homosexual_gay_or_lesbian", "christian", "jewish", "muslim", "black", "white",
    "psychiatric_or_mental_illness",
]
# Android's policy (`MlTextModerator.DEFAULT_BLOCK_THRESHOLDS`): serious abuse only, each label against its own line.
# General rudeness (toxicity, insult, obscene) and the identity columns are never held against a message.
THRESHOLDS = {"severe_toxicity": 0.85, "identity_attack": 0.85, "sexual_explicit": 0.8, "threat": 0.9}

# Tokens per input, [CLS] and [SEP] included, as Android pads and truncates them (`MlTextModerator.DEFAULT_MAX_LEN`).
LENGTH = 128

# albert-base-v2's `config.json`, written out so the rebuild needs no download from the Hugging Face hub.
ALBERT_BASE_V2 = dict(
    vocab_size=30000,
    embedding_size=128,
    hidden_size=768,
    num_hidden_layers=12,
    num_hidden_groups=1,
    num_attention_heads=12,
    intermediate_size=3072,
    inner_group_num=1,
    hidden_act="gelu_new",
    hidden_dropout_prob=0.0,
    attention_probs_dropout_prob=0.0,
    max_position_embeddings=512,
    type_vocab_size=2,
    initializer_range=0.02,
    layer_norm_eps=1e-12,
    classifier_dropout_prob=0.1,
    position_embedding_type="absolute",
    pad_token_id=0,
    bos_token_id=2,
    eos_token_id=3,
)


def sha256(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def blocked(scores) -> list[str]:
    """The labels whose scores reach Android's line for them."""
    return [label for label, line in THRESHOLDS.items() if scores[LABELS.index(label)] >= line]


def tokenizer():
    """Android's tokenizer.json, run by Hugging Face's own tokenizers library: the ids every other tokenizer is held to.

    The file pads and truncates to 128 itself, as detoxify-mobile saved it, so both are turned off here and
    `encode` cuts as Android's `SentencePieceTokenizer.encode` does.
    """
    from tokenizers import Tokenizer

    words = Tokenizer.from_file(str(TOKENIZER))
    words.no_padding()
    words.no_truncation()
    return words


def encode(tokenizer, text: str) -> list[int]:
    """`text`'s ids, [CLS] first and [SEP] last, the words between cut to LENGTH - 2 as Android cuts them; unpadded."""
    ids = tokenizer.encode(text).ids
    return ids[: LENGTH - 1] + [ids[-1]] if len(ids) > LENGTH else ids


def padded(ids: list[int]):
    """`ids` padded to LENGTH, with the mask that marks the real tokens: the two int32 inputs, `[1, LENGTH]` each."""
    import numpy as np

    tokens = np.zeros((1, LENGTH), dtype=np.int32)
    mask = np.zeros((1, LENGTH), dtype=np.int32)
    tokens[0, : len(ids)] = ids
    mask[0, : len(ids)] = 1
    return tokens, mask


def load_model():
    """The checkpoint rebuilt as `AlbertForSequenceClassification`, evaluating, with the labels it was trained on."""
    import torch
    from transformers import AlbertConfig, AlbertForSequenceClassification

    checkpoint = torch.load(CHECKPOINT, map_location="cpu", weights_only=False)
    state = checkpoint.get("state_dict", checkpoint)
    state = {name.removeprefix("model."): weights for name, weights in state.items()}
    dataset = checkpoint["config"]["dataset"]["args"]
    labels = dataset["classes"] + dataset["identity_classes"]
    if labels != LABELS or checkpoint["config"]["arch"]["args"]["num_classes"] != len(LABELS):
        raise RuntimeError(f"the checkpoint's labels are {labels}, not {LABELS}")
    model = AlbertForSequenceClassification(
        AlbertConfig(**ALBERT_BASE_V2, num_labels=len(LABELS), problem_type="multi_label_classification"),
    )
    missing, unexpected = model.load_state_dict(state, strict=False)
    missing = [name for name in missing if not name.endswith("position_ids")]
    unexpected = [name for name in unexpected if not name.endswith("position_ids")]
    if missing or unexpected:
        raise RuntimeError(f"the checkpoint does not fit ALBERT base v2: missing {missing[:4]}, unexpected {unexpected[:4]}")
    return model.eval()
