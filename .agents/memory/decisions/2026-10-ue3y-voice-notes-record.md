---
id: "2026-10.ue3y"
slug: voice-notes-record
title: "Voice notes record, play and travel as Android's do, in debug builds until approved"
date: 2026-10-26
topics: [voice, blobs, app]
---

# ADR 2026-10.ue3y — Voice notes record, play and travel as Android's do, in debug builds until approved

Status: Accepted (2026-10-26)

**Context:** Knit for Android records, sends and plays voice notes in DMs and groups (knit-next ADR 034, at the pin
`e63f15f4`). A voice note there is an ordinary attachment with the type `audio/aac`, AAC-LC in an ADTS stream, so it
needs no wire, crypto or custody change. The iPhone named one ("🎤 Voice message") and showed a tile saying it could
not play it (ADR 2026-10.6cas). Two things stood in the way of simply copying Android:

- **No model on a phone screens speech.** Photos and words from other people are screened here (ADR 2026-10.rpmq, ADR
  2026-10.e4kz), and App Review rejected 1.0.0 under its rule 1.2 on user content (ADR 2026-10.tydq). A voice note is
  the one kind of message from someone else the content filter can't catch.
- **iOS has no `MediaRecorder` piping into memory.** `AVAudioRecorder` writes a file, which would put a sealed note's
  plaintext on disk, the staging knit-next ADR 029 refused.

**Decision:** the iPhone records, sends, receives and plays voice notes as Android does, in a debug build only until
the maintainer approves them for the store.

- **Recording** (`EngineVoiceCapture`, `VoiceRecorder`):
  - `AVAudioEngine`'s input tap feeds an `AVAudioConverter`, and each packet is framed with the ADTS header
    `VoiceAudio.header` writes, in memory. The format is Android's: AAC-LC, mono, at the first of 16, 22.05, 24, 32,
    44.1 and 48 kHz the encoder takes, 32 kbps.
  - The rate is constant. Apple's encoder defaults to a variable rate, which came to about 12 kbps on a quiet room;
    the iPhone 12 recorded 32.76 kbps once it was set.
  - The session takes the built-in microphone and plays to the speaker or a headset's A2DP side, never a headset's
    call profile.
  - Android's rules: a press or a recording under 0.7 s keeps nothing ("Hold the mic button to record"), five minutes
    stops and keeps the note, the bytes are judged rather than the stop, and the drain stops at 4 MiB.
  - The permission is asked on the press that finds it missing, and that press records nothing.
  - Knit leaving the screen stops and keeps a recording of 0.7 s or more (the maintainer's call). Android records until
    its chat closes, but Knit has no audio background mode (ADR 2026-09.khjj), so iOS would end it anyway.
- **What a note says about itself is read on each phone, never carried:**
  - The length is the ADTS walk, ported exactly (`VoiceAudio.durationMs`).
  - The waveform is 64 bars from AudioToolbox's decode in memory, one bucket per decoder run as Android buckets
    MediaCodec's output, scaled to the 95th percentile unless the room was silent (`VoicePeaks`, `ToolboxVoiceDecoder`).
  - Both are kept in schema v23's local `voiceDurationMs` and `voicePeaks`, on every row naming the blob hash: the
    ciphertext's for a sealed note. Each column is coalesced on its own when a row is saved again, and the waveform is
    raw bytes where Android keeps base64.
  - The session reads a note as it is sent (from its plaintext), when its bytes land, when its message lands after its
    bytes (knit-next #132, which raises no `attachmentArrived`), and at launch. The launch reads the whole list and pages
    it in memory, 64 at a time, so a note that can never be read holds up none after it (blobs-reviewer's design pass).
- **Playing** (`VoicePlayback`, `PlayerVoiceOutput`): `AVAudioPlayer` from the plaintext in memory, which reads the
  container from the bytes, so a picked file plays as well as a recorded note. Android's player rules hold:
  - one note at a time, app-wide, and a tap on another stops the first;
  - a tap on the waveform moves the loaded note only, playing or paused, and only once its length is known;
  - a note played out lets go;
  - the system's pause (a call, Siri, the headphones leaving) keeps the place.

  The bubble shows the ADTS walk's length, because the player's own drifts for ADTS: 3.08 s for a 3.136 s note.
- **Where they go:** DMs and groups. The composer offers no mic in Nearby, and `AppSession.send` refuses an `audio/`
  attachment there, which also closes the debug bridge's `room`. A voice note someone posts in Nearby shows a tile
  saying voice notes play in DMs and groups, and doesn't play: stricter than Android, which plays one, for rule 1.2
  (the maintainer's call). No Android build posts one there.
- **The UI:**
  - The mic sits between the field and Send while there is nothing to send. Hold to record, slide up 46 points to lock,
    slide back 61 points to cancel, which is Android's 120 and 160 pixels at a Pixel's density.
  - The recording bar replaces the field, never the row, so the mic outlives the press (ADR 034's trap). Once locked,
    the mic gives way to Stop.
  - VoiceOver's activation records locked.
  - The held note plays in the composer before it is sent, and takes a caption and a quote.
  - The bubble has Android's 40-point disc, 64 bars and `m:ss`, mirrored in a right-to-left layout. A note on its way
    waits in a row the player's width, with the ring, the stitches and the hourglass a photo's box shows (ADR
    2026-10.eyad), where the first cut drew a photo's 160-point square.
  - A message stays one VoiceOver element, with Play or Pause among its actions, so the bubble's own play button stays
    out of the tree. The clock names the note, "Voice message, 0:07", or "Voice message, 0:07, at 0:01" part played:
    the audit reports text on screen that no label carries.
  - The player knows a note by its blob, as Android's does, so two messages carrying one blob play together.
  - Copy is in `Copy.Voice`, after Android's strings.
- **The release gate:**
  - `KnitAppCore` holds no build condition (ADR 2026-10.8cy5): the session takes a `VoiceNotes` bundle, and
    `AppEnvironment.voiceNotes` hands it over in a debug build alone.
  - Without it there is no mic, the old tile stays, and nothing is read. Schema v23 still migrates, and its columns stay
    empty.
  - `Sources/Knit/Voice/` compiles into a debug build only, since App Store Connect flags a binary whose code reaches
    the microphone without its key, and the key stays in `App/project.yml`'s Debug config.
  - `check.sh release` fails a build holding "voice notes are on in this debug build", as well as one holding the key.
    On 2026-10-26 the Release binary held no voice code at all.
- **The demo and the bridge:**
  - `-demoScene voice` stages a DM with Sam's notes: two held, one streaming in, one owed.
  - `-demoVoice` hands the mic a bundled clip, `App/DemoMedia/voice-reply.aac`, and the scene's notes are
    `voice-note.aac`: speech-shaped noise ffmpeg made, so no one's voice is in them. They are two clips so that playing
    the recorded note plays nothing in the thread.
  - The bridge's `voice` command lists a thread's notes as this phone read them, records for a given time, and plays or
    stops a note.

The alternative a reader reaches first for is `AVAudioRecorder` with a file in the app's temporary directory, deleted
after the send. It is simpler, but it writes the plaintext of a note that is about to be sealed to disk, which Android
refused for the same reason. The other is shipping voice notes in the store build now, as Android does. That waits for
the maintainer, because no screen exists for speech.

**Consequences / limits:**

- **Both phones read the same length** from the same bytes. On 2026-10-26 the iPhone 12 and a Pixel 9 Pro XL agreed:
  2304 ms for a note the Pixel recorded, 3136 ms for one the iPhone recorded. The bars can differ by a step, since
  Apple's decoder and MediaCodec round differently, and the decoder's priming (about 136 ms) shows on both.
- **A note that can never be read is read again at every launch:** a blob that won't open, or audio with neither ADTS
  nor a container length. Android reads one again only when it is delivered again. The read is bounded by how many such
  notes there are.
- **A voice note can't be screened,** and that is why the gate stays shut. Opening it takes, in its own change:
  - Report and Block shown to work on a voice message (ADR 2026-10.f6kf);
  - the review notes' 1.2 section naming voice notes;
  - the App Store Connect privacy answers for audio;
  - the key moved to `App/Info.plist` in `Copy.System.microphoneUsage`'s words, with `CopyTests` holding it;
  - `Sources/Knit/Voice/` built in every configuration, and `AppEnvironment.voiceNotes` handing the bundle over in
    every build;
  - `check.sh release` flipped to require the key and to stop refusing the marker, and ADR 2026-10.x2cq amended again;
  - an entry in `CHANGELOG.md`'s Unreleased section, which speaks to the store build and so has none until then.
- **Playing over a Bluetooth headset** shares the 2.4 GHz radio with the mesh. Android's ADR 034 notes the same, for
  its scan. Nothing here measures it yet.
- **The audio session is set active on the main actor,** which iOS 27 warns can stall the screen and for which it
  offers an asynchronous form. It is a few milliseconds a press or a play here; moving it off is a follow-up.
- **Not here:** transcription (knit-next ADR 2026-10.am8d), a speed control, the earpiece, and hearing a note through
  the speaker and a headset, which the trial still owes by ear.
- **Guards:**
  - `VoiceAudioTests` (Android's `VoiceAudioTest` at its exact numbers) and `VoicePeaksTests`;
  - `VoiceRecorderTests`, `VoicePlaybackTests`, `SessionVoiceTests` (#132, the launch's paging) and `ChatVoiceTests`,
    with and without the bundle;
  - `VoiceDescriptionTests` and `SchemaTests` v23 for the store;
  - `KnitUITests`' `testVoiceNotesPlayAndTheMicRecordsOne`, through the accessibility audit, and again at the largest
    size and in dark mode with every screen;
  - `check.sh release`'s two checks, and the debug build's check that it bundles every clip in `App/DemoMedia`.
