# The NSFW photo model

`App/Models/NSFW.mlpackage` is the photo classifier Knit for Android ships as
`app/src/main/assets/moderation/nsfw.tflite`, converted to Core ML. This directory holds the recipe that converts it
and the checks that it still scores what Android scores.

## Where it comes from

[GantMan/nsfw_model](https://github.com/GantMan/nsfw_model) release 1.2.0, `mobilenet_v2_140_224.1.zip`: a
MobileNetV2 (width 1.4, 224 × 224 input) trained on five classes, `drawings`, `hentai`, `neutral`, `porn` and `sexy`.
The zip carries the SavedModel and the TFLite exported from it, and the TFLite is byte for byte the one knit-next
bundles. `fetch.py` checks both hashes before anything is converted.

Android flags a photo when `hentai + porn + sexy` reaches 0.9 (`NsfwImageModerator.kt`). knit-next's
`CONTENT_MODERATION.md` and its assets README still say 0.7, but the code says 0.9.

## Converting it

Python 3.11 through [uv](https://docs.astral.sh/uv/), with every version pinned in `uv.lock`:

```sh
cd tools/models/nsfw
uv run python fetch.py               # download, check both hashes, unpack into .cache/
uv run python convert.py             # write App/Models/NSFW.mlpackage
uv run python convert.py --check     # exit 1 unless the committed package is exactly what convert.py writes
uv run python parity.py --reference  # rebuild the corpus and its TFLite scores (Linux, a few minutes)
```

The conversion is float16 and needs no Mac. coremltools 9.0 is tested with TensorFlow 2.12, which has no wheel for
Apple silicon, so TensorFlow is installed on Linux only.

## Checking it

Core ML predicts only on macOS, so the comparison runs on the Mac:

```sh
scripts/mac.sh run bash -c 'cd tools/models/nsfw && uv run --frozen python parity.py --coreml'
```

`parity/reference.json` is a synthetic corpus scored by Android's TFLite: seeded noise, blocks, flat colours and
gradients, plus probes. A probe is a 28 × 28 pattern that gradient ascent through the SavedModel pushed toward one
class, or onto the 0.9 line. No input shows anything. The check holds the unsafe sum within 0.02 of the reference,
on the Neural Engine and on the CPU, and verdicts must agree wherever the reference is further than 0.02 from 0.9.

On 2026-10-04 the worst unsafe-sum difference was 0.006 on the Neural Engine and 0.016 on the CPU, where one probe
at 0.9016 fell below the line. A float32 package matched exactly, at twice the size. The maintainer chose float16.

For real photos, `score.py` runs Android's preprocessing and the TFLite on Linux, to compare with what an iPhone's
debug bridge reports. Keep those photos outside the repository.

## License

The model is MIT, copyright 2020 The nsfw_model Developers, and `THIRD-PARTY-NOTICES.md` lists it. These scripts
are part of Knit for iOS.
