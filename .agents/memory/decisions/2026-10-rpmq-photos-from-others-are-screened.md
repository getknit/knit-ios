---
id: "2026-10.rpmq"
slug: photos-from-others-are-screened
title: "Photos from others are screened on the iPhone when first shown, by Android's NSFW model in Core ML"
date: 2026-10-04
topics: [moderation, blobs, app, build]
---

# ADR 2026-10.rpmq — Photos from others are screened on the iPhone when first shown, by Android's NSFW model in Core ML

Status: Accepted (2026-10-04)

**Context:** ADR 2026-10.nh55 brought photos to the iPhone unscreened, and App Store guideline 1.2 asks for a way to
filter objectionable content before a store build (`.agents/memory/roadmap.md`). Knit for Android screens photos on
the phone with GantMan's `nsfw_model`, a MobileNetV2 140/224 in TFLite, under its Content filtering toggle (knit-next
`docs/CONTENT_MODERATION.md` §3; `NsfwImageModerator.kt`, `ImageScreeningService.kt`):

- **The verdict:** the scores of hentai, porn and sexy, summed, flag a photo at 0.9 or more. knit-next's doc and its
  assets README say 0.7, but the code says 0.9, and the code is what runs.
- **The input:** a bounded decode at 512 pixels, stretched to 224 by 224, RGB divided by 255. A GIF gives its first
  frame.
- **The sender** checks every photo it prepares, whatever the toggle says. In the Nearby room an explicit photo is
  refused. In a DM or a group the sender is asked before it is staged. Our own profile photo is never checked.
- **The recipient** screens a photo as its bytes land, a sealed one after it opens, and stores the verdict by blob
  hash in `blob_verdicts`. With the toggle on (the default), someone else's flagged photo hides behind a tap, and a
  flagged profile photo is not adopted.
- **When the model is missing** or fails, every photo goes through, and Android stores that "allowed" verdict for
  good.

GantMan's release 1.2.0 (`mobilenet_v2_140_224.1.zip`) carries the SavedModel that Android's TFLite was exported
from. Its `saved_model.tflite` is byte for byte knit-next's `nsfw.tflite` (sha256 `380f98f7…fab40`). coremltools
cannot read TFLite, but it can read that SavedModel.

**Decision:** the iPhone screens photos with the same model and the same policy, in Core ML. It screens when a photo
is first shown rather than when it lands.

- **The model:**
  - `tools/models/nsfw/` downloads the release and checks both hashes. It converts the SavedModel to a float16 ML
    program, `App/Models/NSFW.mlpackage` (8.6 MB of weights), committed in plain git.
  - The conversion is reproducible: `convert.py --check` rebuilds it byte for byte, once the manifest's random UUIDs
    are replaced with ones derived from each part's path.
  - Xcode compiles it into `Knit.app/NSFW.mlmodelc`, with codegen off, because the generated class would land in the
    C host target.
- **Float16 against float32:**
  - The maintainer chose float16 for half the size.
  - Measured on 2026-10-04 against Android's TFLite, over a synthetic corpus of 30 inputs (`parity.py`): the unsafe
    sum was off by at most 0.006 on the Neural Engine and 0.016 on the CPU. A boundary probe at 0.9016 fell below
    the line on the CPU.
  - Float32 matched exactly, at 17 MB.
  - So the two platforms can disagree about a photo within about 0.02 of 0.9.
- **The classifier:** `DevicePhotoClassifier`, in the app's `Moderation/`, the one place that imports CoreML
  (`seam_coreml`).
  - It decodes through `PhotoDecoder` at 512 pixels and stretches to 224 by 224 in sRGB, where transparency lands on
    black.
  - It runs on the CPU and the Neural Engine, never the GPU.
  - It loads on the first photo, and lets go when Knit goes to the background or iOS warns about memory.
  - A model that fails to load stays failed until the next launch, as Android's spent lease does.
- **The policy** is KnitAppCore's and tested on Linux: `ExplicitPhoto` for the threshold, and `PhotoScreening` for
  the rest. The toggle, `AppPreferences.filtersContent`, is on until it is turned off.
- **Sending** follows Android: `ChatModel.choosePhoto` checks the prepared bytes. The room refuses an explicit photo.
  A DM or a group asks with "Send anyway". Our own profile photo is not checked.
- **Showing:**
  - A thread screens someone else's photo before it draws it, from the blob store's bytes, opened with its message's
    key when sealed.
  - With the filter on, an explicit photo shows "Sensitive photo. Tap to show.". VoiceOver says the photo is hidden
    and offers Show photo, since the message reads as one element that names no photo of its own.
  - A face screens someone else's photo the same way and shows their initial in its place, and their profile then
    offers no photo to open.
  - Our own photos and face are never hidden. Turning the filter off shows everything at once.

The first alternative is to screen on arrival and store verdicts, as Android does. It is not used, for three reasons:

- It would run Core ML in the brief background wakes a link gives a suspended iPhone (ADR 2026-09.khjj).
- It would need a migration, and verdict rows the blob sweep would have to follow.
- It would need a second hook for bytes already held, which `receiveFile` never sees again.

Screening when shown runs only while Knit is on screen. It changes nothing the mesh carries, stores or serves (ADR
2026-10.5wgg). Its cost is one screen per photo per launch, in memory.

The second alternative is to ship LiteRT and run Android's file as it is. It would add a native dependency and a
second runtime, for a byte-identical file that the parity check makes unnecessary.

**Consequences / limits:**

- **Differences from Android, on purpose:**
  - Verdicts live in memory, so a photo is screened once per launch.
  - A photo that could not be scored is asked about again, where Android keeps "allowed" for good.
  - An explicit face is drawn as the initial, not left unadopted, so it comes back when the filter is turned off.
  - A photo tapped to show stays shown while its thread is open. Android's hides again once its row scrolls away.
  - A semi-transparent pixel is darkened rather than un-premultiplied. Photos rarely have one.
- **What it is not:**
  - It covers photos only. Text waits for the Detoxify milestone, and voice notes and files are not screened, as on
    Android.
  - It is no CSAM detection.
  - It can miss a photo or hide a fine one. The Settings footer says so.
  - Sender-side checks are good citizenship, since a modified client skips them. Hiding on the recipient's phone is
    the protection.
- **The trap:** reading a verdict anywhere the mesh decides what to carry, refuse or serve. ADR 2026-10.5wgg's
  reasoning applies: a per-node input there splits digests.
- **Guards:**
  - `PhotoScreeningTests`: the policy, the room's refusal, the DM's and group's question, hiding and its exemptions,
    the cache, and the toggle.
  - `CopyTests` and `CopyCatalogTests` for the words, and that About lists the model.
  - `ModelAssetTests`, so Linux CI fails without a whole package.
  - `check.sh xcode` and `release` fail without a whole `NSFW.mlmodelc` in the app.
  - `KnitUITests.testTheContentFilterHidesAsksAndTurnsOff` walks it under `-demoSensitive`, at both text sizes.
  - `convert.py --check` and `parity.py --coreml`, whenever the model or a pin moves.
  - The debug bridge's `screen` and `photos` replies, for the iPhone's half of a device check against `score.py`.
