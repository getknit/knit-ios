# Third-party notices

Knit for iOS is free software under the GNU General Public License, version 3 or later, with an App Store
exception ([`COPYING`](COPYING), [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md)). Every component it
ships is under a license compatible with that. `RepoConventionTests` fails when `Package.resolved` gains a
package this file does not account for.

## Shipped in the app

| Package | Project | License |
| --- | --- | --- |
| `grdb.swift` | [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| `swift-crypto` | [apple/swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |

GRDB links the SQLite that ships with iOS and bundles none of its own. On iPhone, swift-crypto hands every
operation to Apple's CryptoKit. Its bundled copies of BoringSSL and XKCP compile only into Linux builds, such as
the `knit-peer` test tool, which is not distributed.

## Bundled models

| Asset | Project | License |
| --- | --- | --- |
| `App/Models/NSFW.mlpackage`, the photo classifier (MobileNetV2, copyright 2020 The nsfw_model Developers) | [GantMan/nsfw_model](https://github.com/GantMan/nsfw_model) | MIT |
| `App/Models/Toxicity.mlpackage`, the message classifier (Detoxify unbiased-small, copyright Unitary) | [unitaryai/detoxify](https://github.com/unitaryai/detoxify) | Apache-2.0 |
| `App/Models/ToxicityTokenizer.json`, its tokenizer (ALBERT base v2's SentencePiece vocabulary) | [albert/albert-base-v2](https://huggingface.co/albert/albert-base-v2) | Apache-2.0 |
| `App/Models/Profanity.txt`, the Nearby room's word list (copyright 2021 David Sojevic) | [dsojevic/profanity-list](https://github.com/dsojevic/profanity-list) | MIT |

The photo classifier is release 1.2.0's SavedModel converted to Core ML, the same weights Knit for Android bundles as
`nsfw.tflite`. The message classifier is Detoxify's v0.1.2 checkpoint `unbiased-albert-c8519128.ckpt`, which builds
on ALBERT base v2, converted to Core ML; Knit for Android bundles an int8 copy of the same weights as
`toxicity.tflite`. The tokenizer and the word list are Android's files, byte for byte; knit-next's
`scripts/gen-profanity-list.py` derives the list from dsojevic/profanity-list at commit `c279243`.
`tools/models/nsfw/` and `tools/models/toxicity/` hold the recipes. The Detoxify weights were trained on Jigsaw's
Unintended Bias in Toxicity Classification data, which is not redistributed.

## Resolved but not shipped

SwiftPM resolves these while building the packages above, and none of their code reaches the app.

| Package | Project | License | Why it stays out |
| --- | --- | --- | --- |
| `swift-asn1` | [apple/swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 | Only swift-crypto's `CryptoExtras` uses it, and Knit doesn't link that |

## Build and test tools (not distributed)

| Tool | Project | License |
| --- | --- | --- |
| SwiftLint | [realm/SwiftLint](https://github.com/realm/SwiftLint) | MIT |
| swift-format | [swiftlang/swift-format](https://github.com/swiftlang/swift-format) | Apache-2.0 |
| Periphery | [peripheryapp/periphery](https://github.com/peripheryapp/periphery) | MIT |
| XcodeGen | [yonaskolb/XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT |
| lintorama | [zaventh/lintorama](https://github.com/zaventh/lintorama) | MIT |
| coremltools | [apple/coremltools](https://github.com/apple/coremltools) | BSD-3-Clause |
| TensorFlow | [tensorflow/tensorflow](https://github.com/tensorflow/tensorflow) | Apache-2.0 |
| uv | [astral-sh/uv](https://github.com/astral-sh/uv) | MIT or Apache-2.0 |

coremltools, TensorFlow and their Python dependencies (pinned in `tools/models/nsfw/uv.lock`) convert the photo
classifier and check it. They never reach the app.

## Agent skills in the repository (not distributed)

These are instructions for coding agents, kept under `.agents/skills/` with each license beside it. None of them
reaches the app.

| Skill | Project | License |
| --- | --- | --- |
| `dotagents-standard` | [zaventh/dotagents-standard-skill](https://github.com/zaventh/dotagents-standard-skill) | MIT |
| `humanizer` | [blader/humanizer](https://github.com/blader/humanizer), as ported in [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | MIT |
