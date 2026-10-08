# The message toxicity model

`App/Models/Toxicity.mlpackage` is the text classifier Knit for Android ships as
`app/src/main/assets/moderation/toxicity.tflite`, rebuilt for Core ML. Beside it sit three of Android's files, byte
for byte: `ToxicityTokenizer.json` (Android's `tokenizer.json`), `Profanity.txt` (its `profanity_en.txt`, the Nearby
room's word list) and `Slurs.txt` (its `slurs_en.txt`, the slur list every conversation runs, knit-next ADR
2026-10.d62w). This directory holds the recipe that builds the package and the checks that it still scores what
the model should.

## Where it comes from

[Detoxify](https://github.com/unitaryai/detoxify)'s `unbiased-small` checkpoint, release v0.1.2,
`unbiased-albert-c8519128.ckpt`: ALBERT base v2 fine-tuned on Jigsaw's Unintended Bias data, with 16 sigmoid outputs.
The first seven are toxicity labels and the other nine name identity topics. Android's TFLite came out of
detoxify-mobile, the separate pipeline knit-next's `CONTENT_MODERATION.md` names, which rebuilds the same checkpoint
and quantizes it to int8. coremltools cannot read that TFLite, so `convert.py` starts where detoxify-mobile did: the checkpoint, pinned by
the SHA-256 both repositories record.

Android blocks a message when one label crosses its line (`MlTextModerator.kt`): `severe_toxicity` or
`identity_attack` at 0.85, `sexual_explicit` at 0.8, `threat` at 0.9. General rudeness never blocks. In the Nearby room
the word list runs first.

## Converting it

Python 3.11 through [uv](https://docs.astral.sh/uv/), with every version pinned in `uv.lock`:

```sh
cd tools/models/toxicity
uv run python fetch.py               # download the checkpoint, check it and Android's two files
uv run python convert.py             # write App/Models/Toxicity.mlpackage
uv run python convert.py --check     # exit 1 unless the committed package is exactly what convert.py writes
uv run python parity.py --reference  # score the corpus with the checkpoint, writing parity/reference.json
uv run python tokens.py              # write the ids the Swift tokenizer is held to, parity/tokens.json
```

The conversion traces the model in PyTorch 2.7.0, the newest coremltools 9.0 is tested with, and needs no Mac. It
adds one change to detoxify-mobile's graph: the attention mask adds -10000 where transformers adds the lowest float32,
which float16 cannot hold. `convert.py` checks that the rebuilt graph scores what transformers does before it converts
anything. Weights and arithmetic are float16. ALBERT shares one layer's weights across all twelve, and the package
keeps them once, at 23 MB.

`parity.py --reference --android PATH` also records the scores of Android's TFLite, given its path in a knit-next
checkout. Nothing is held to them.

## Checking it

Core ML predicts only on macOS:

```sh
scripts/mac.sh run bash -c 'cd tools/models/toxicity && uv run --frozen python parity.py --coreml'
```

The corpus is short messages: everyday ones, rude ones, ones that cross each enforced line, and generated ones that
land nearest each line. Each keeps its token ids, so the Mac needs only coremltools and numpy. The check holds every
enforced label within 0.03 of the checkpoint, on the Neural Engine and on the CPU, and verdicts must agree wherever the
checkpoint is further than that from a line.

Measured on 2026-10-04 over 45 messages:

| Package | Size | Worst enforced label, Neural Engine | Worst enforced label, CPU |
| --- | --- | --- | --- |
| float16, committed | 23 MB | 0.004 | 0.011 |
| float32 | 45 MB | 0.000 | 0.000 |
| int8 weights | 12 MB | 0.025, one verdict turned at a line | 0.027 |

Android's int8 TFLite sits up to 0.12 from the checkpoint over the same corpus, and turns two verdicts near the threat
line. So the two phones can disagree about a message close to a line.

`SentencePieceTokenizerTests` in KnitAppCoreTests holds the Swift tokenizer to `parity/tokens.json`, the ids Hugging
Face's own tokenizers library makes from Android's file.

For a message from a device check, `score.py` scores it with the checkpoint (and `--android PATH`, Android's TFLite) to
compare with what an iPhone's debug bridge reports for `screen-text`.

## License

Detoxify's weights and ALBERT base v2 are Apache-2.0. The word list derives from
[dsojevic/profanity-list](https://github.com/dsojevic/profanity-list), MIT. `THIRD-PARTY-NOTICES.md` lists all three.
The Jigsaw data the weights were trained on is not redistributed. These scripts are part of Knit for iOS.
