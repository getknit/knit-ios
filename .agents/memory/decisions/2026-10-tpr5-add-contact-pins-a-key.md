---
id: "2026-10.tpr5"
slug: add-contact-pins-a-key
title: "Add contact pins a key from a scanned code or a signed contact link"
date: 2026-10-19
topics: [app, crypto, security]
---

# ADR 2026-10.tpr5 — Add contact pins a key from a scanned code or a signed contact link

Status: Accepted (2026-10-19)

**Context:** an iPhone could make someone a contact only by chatting with them or by verifying a key it already held
(ADR 2026-10.65xx, which left Add contact and contact links for later). Knit for Android has two more ways, and they
behave differently:

- **A scanned code** (`AddContactViewModel.onScanned`, `:221-267`): with no key pinned, the code's key pins and the
  person is marked verified. The same key marks them verified. Another key is a mismatch, and nothing is written. The
  card's name is dropped, nothing is sent, and the block list is not read.
- **A signed contact card** (`docs/CONTACT_CARD.md`, knit-next ADR 042), shared as `https://getknit.app/c#…` or
  `knit://c/…`. Importing it pins the key, accepts the conversation and asks neighbours for the profile
  (`ContactImporter.import`, `:97-114`; `MeshManager.importContact`, `:1108-1113`). It never marks anyone verified. It
  also starts an intro: a sealed `CTL_PROFILE` whose X3DH init rides every copy, re-sent every 20 hours until answered.

A card is `Signed {body, sig}`, with the body `{v: 1, id, pk: sigPub ‖ hpkePub, name?, sp?, iat}`, signed with Ed25519
over `"knit/card/v1" ‖ body`. It certifies itself: the id must derive from the bundle rebuilt from `pk`. Android draws
only the legacy `knit-id:v1` code as a QR code, and both its scan paths read either form.

**Decision:** both paths, as Android has them, except the intro.

- **`ContactCard`** in KnitCrypto ports the codec at knit-next `main`. It runs Kotlin's checks in Kotlin's order, on
  UTF-8 (ADR 2026-09.jc2x), and verifies the signature over the body bytes as received. The name clamp is `main`'s,
  which never splits a surrogate pair, a change past the pin.
- **`MeshEngine.addContact`** is the one place that pins without a profile frame.
  - It answers our own id before it writes anything, from either source.
  - It re-reads the stored row inside the call and refuses another key, which Kotlin's `import` does not check.
  - It starts from the stored row. A fresh row over an existing one would wipe the prekey, the capabilities and both
    watermarks, and the ratchet would fall to v1 until the peer published again. That was the design pass's blocking
    finding.
  - It reads the row back and answers `failed` if the pin did not land, because the store swallows its errors.
- **The scan path** pins with `verified` and sends nothing, as Android's does.
- **The link path:**
  - unblocks first if the user asked;
  - keeps a stored name over the card's;
  - keeps the stored verification;
  - accepts the conversation;
  - asks neighbours for the key.
- **One deliberate difference: frames parked for the sender are released at the pin.** Kotlin releases them only when
  the profile pins (`InboundPipeline.kt:3649`), so a DM that arrived just before the import waited for a carrier to
  serve it again after the dedup window. The key is the one the id derives from, so the frame verifies against it.
- **What waits for the profile, as in Kotlin:**
  - a DM or group message already queued for the key;
  - an init answer this phone owes them;
  - the proof frame `KeyExchange` serves.
- **No intro.** It is deferred (maintainer, 2026-10-19). On a Bluetooth mesh the session forms with the first message,
  and the intro's other job, naming the Internet relay's pair scope, has nothing to do here. This port still answers
  Android's intros (`RatchetAnswers`).
- **The screen:**
  - Add contact opens from New message.
  - It shows our `knit-id` code, Scan their code, Share link and Copy link.
  - Add by link takes pasted text through `PasteButton`, which asks no paste permission.
  - A preview shows the label, the node id and the safety number before anything is written.
- **The profile still only compares** (ADR 2026-10.65xx). It now reads a card as well as a `knit-id` code, as Android's
  does.
- **Links open the app through `knit://` alone.** `App/Info.plist` registers the scheme. An `https://getknit.app/c#…`
  link opens Safari until the site serves an apple-app-site-association file and the app carries
  `applinks:getknit.app`. A thread shows a link as plain text, so a link sent in a Knit chat is copied and pasted
  into Add contact.

**Consequences / limits:**

- **A DM sent before the peer's profile arrives goes v1, and is never upgraded,** and its ticks and reactions go in the
  clear. The pin carries no `CAP_RATCHET` and no prekey. Android behaves the same. `SECURITY.md`, the encryption sheet
  and `.agents/rules/copy.md` name the exception, which was the crypto review's blocking finding.
- **A card can be replayed and forwarded.** Nothing checks `iat`, by design: a card is a public key and a name.
- **A card pin has no proof frame.** This phone cannot serve that key to others until the profile arrives, and cannot
  send it ahead of a backlog it carries. It does carry the sender's frames, so a neighbour without the key is served
  that backlog at every digest, a minute apart, and drops or parks it, until the profile reaches one of them or the
  frames expire. Android's card import costs the same (`ForwardSync.kt:136-187`).
- **Without the intro,** an Android phone that imports our card shows its own intro state, not ours, and the pair has no
  session until one of them writes.
- **A person blocked before their profile pinned is blocked without a device tag,** so a reinstall escapes the block. It
  is the same on Android.
- **The camera's usage string** now covers adding contacts as well as verifying them. `CopyTests` holds it equal to
  `App/Info.plist`.
- **The guards:**
  - `ContactCardTests`: Android's two vectors, every refusal, and our body byte-equal to the vector's. It also runs in
    `test:macos`, because CryptoKit signs differently.
  - `MeshEngineContactTests`: each outcome; a pinned row's ratchet state surviving a re-import; parked frames released;
    queued DMs left waiting; a two-engine run to one confirmed session.
  - `AddContactTests` and `ProfileTests` in KnitAppCore.
  - `KnitUITests`' Add contact walk.
  - `interop.py iphone-contact` against a Pixel.
