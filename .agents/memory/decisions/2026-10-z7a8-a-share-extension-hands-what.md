---
id: "2026-10.z7a8"
slug: a-share-extension-hands-what
title: "A share extension hands what it takes to the app through an App Group"
date: 2026-10-21
topics: [share, ui, signing]
---

# ADR 2026-10.z7a8 — A share extension hands what it takes to the app through an App Group

Status: Accepted (2026-10-21)

**Context:** Knit for Android is a share target (`ui/share/ShareTargetScreen.kt`, `ShareInbox.kt`,
`MainActivity.handleShareIntent`). A `SEND` of text, one image or one file opens "Share to…", which lists what the
chat list lists: the Nearby room, groups still held and accepted DMs, with no request and no blocked person. A tap opens
that chat with the share in the composer, and nothing goes until Send. A shared contact link goes to Add contact
instead (ADR 2026-10.tpr5). Android has no direct share and takes one item.

An iPhone could take nothing from another app. Three things on iOS rule out copying Android's shape as it is:

- **A share extension cannot open its app.** iOS gives a share extension no public way to bring its host forward, so
  "pick a chat, then the composer opens" cannot happen in one step. The responder-chain trick that reaches
  `UIApplication` from an extension is private API.
- **Only the app can send.** The mesh, the radio, the Keychain identity and the ratchet's state live in the app's
  process. An extension that sealed a frame would race the app's ratchet over the same sessions (ADR 2026-10.5sk9).
- **Nothing is shared yet.** The database lives in the app's own Application Support folder (ADR 2026-09.nyya), the
  identity's Keychain item has no access group (ADR 2026-09.tkww), and preferences are `UserDefaults.standard`.

**Decision:** the sheet sends, and the app does the sending. The maintainer chose this over Android's prefill, which on
iOS would leave the user to switch to Knit by hand, on 2026-10-21.

- **The sheet** lists the chats, previews the share, takes an edit of the words and has Send, as Messages, Signal and
  WhatsApp do. Send writes the share to an App Group's inbox and closes the sheet. It takes text, one web URL (as
  text, since iOS has no link previews) and one picture, still or moving. A Knit contact link goes to Add contact. Files,
  video and several pictures wait until the iPhone can send them.
- **The App Group** is `group.app.getknit.knit` for the store id and `group.app.getknit.knit.dev` for the debug one, so
  the two builds never drain each other's shares. Under its `Share/` folder:
  - `chats.json`: the list the sheet shows, which the app writes whenever its chat list changes.
  - `incoming/<id>/`: the sheet writes a share here, then renames it into `inbox/<id>/`, so the app never reads half of
    one.
  - `held/<conversation>/<id>/`: a share a check refused, until its thread opens.
- **The app drains the inbox through `ChatModel`'s own rules,** for a share to the room, a DM or a group: `choosePhoto`
  (a picture already held, `PickedPhoto`'s preparation, and the room's photo screening, ADR 2026-10.spcy), the room's word
  screening in `send()`, and `ChatState`'s blocked, left-group and request checks. A share to a request is refused,
  since a send would accept it. It drains at launch, at the front, on a Darwin notification from the sheet, and on the
  session's revision moving, which every background wake moves. A contact link drains only at the front, into
  `Launch.requestedContactLink`.
- **A refused share waits in its chat's composer.** It moves to `held/`, a notification says so and opens the thread, and
  the thread takes it into the composer with the alert the composer itself would have shown.
- **At most once.** The app moves a share out of `inbox/` before it sends, so a crash between the two can lose that one
  share but never sends it twice.

The alternative a reader reaches for first is the database and the identity in the App Group, so the sheet can send
itself. It costs a migration of the identity's Keychain item (ADR 2026-09.tkww), puts SQLite in a shared container,
where iOS ends a suspended app that holds a file lock in one, and still leaves the sheet without the radio. It buys
nothing the inbox does not.

**Consequences / limits:**

- **A share goes when Knit next runs.** With Knit suspended and no link, a share waits until a wake or the front, as a
  message typed then would wait for a link anyway. The thread shows nothing until the drain.
- **The sheet never decodes a picture.** Its thumbnail comes from `CGImageSourceCreateThumbnailAtIndex`, and it refuses
  a picture over 50 MB or over `PhotoDecoder.pickedPixels` from the source's properties, because a share extension's
  memory limit is far below the app's. The app prepares the picture at the drain.
- **A background wake drains lightly.** The session's revision moves on every frame a wake brings, so `ShareHost`
  runs one pass for a burst, then waits a second before the next, and drains only when a share waits. A picture over
  `ShareDrain.backgroundPictureBytes` (4 MiB) waits for the front: decoding tens of megabytes in a Bluetooth wake
  could cost the wake, or the process and every link with it. The bluetooth-reviewer asked for both on 2026-10-21.
- **Bounded.** The sheet refuses a ninth share while eight wait, and a held share older than 7 days goes.
- **Two more App IDs and two App Groups** must exist before a signed build: `app.getknit.knit.share` and
  `app.getknit.knit.dev.share` (ADR 2026-09.txqp, ADR 2026-09.zawh). The extension carries the app's version keys, its
  own privacy manifest and the group's entitlement, which `check.sh xcode` and `check.sh release` check.
- **The traps:**
  - Seed a drained share's words through `ChatModel`'s initialiser, never `draft`'s setter, which cues typing.
  - Never call `AppSession.send` straight from the drain. It skips the room's photo screening, which runs in
    `choosePhoto`, and every check `ChatState` makes.
  - Never let the sheet open the database or the Keychain.
- **The guards:** `ShareInboxTests` (the manifest, a half-written share ignored, the bounds, the order),
  `ShareDrainTests` (each conversation kind, each refusal landing in `held/`, no typing cue, a contact link only at the
  front, a large picture left for the front, a drain asked for meanwhile still running its own pass), `ShareHostTests`
  (the chats offered, the pause between passes, the held notification), and the Simulator walks in
  `KnitUITests+Share.swift` under `-demoShare`.
