---
id: "2026-10.spcy"
slug: the-iphone-screens-on-sending
title: "The iPhone screens on sending only in Nearby, and screens its profile photo"
date: 2026-10-07
topics: [moderation, privacy]
---

# ADR 2026-10.spcy — The iPhone screens on sending only in Nearby, and screens its profile photo

Status: Accepted (2026-10-07)

**Context:** knit-next ADR 2026-10.9rh6 moved Knit for Android's sender-side screening to the public rooms alone. The
classifiers miss things both ways. A false positive in a private chat refused a message the reader may well have
wanted, and "send anyway" put a classifier's guess between two people who chose to talk. A tampered client skips
every check on the sender's side anyway, so the receiver's check is the one that protects anyone. The iPhone still
checked words on sending in every conversation (ADR 2026-10.e4kz). It asked before an explicit photo went into a DM or
a group (ADR 2026-10.rpmq). It never screened its own profile photo. So the two phones disagreed: a slur in a DM was
refused on an iPhone and went out from Android (ADR 2026-10.8e2u).

**Decision:** mirror 9rh6 where the iPhone has the same surface.

- **Words:** `ChatModel.send` checks them only in the Nearby room, against the slur list, the profanity list and the
  model, whatever the content filter says. A DM or a group sends them without reading them.
- **Chat photos:** `ChatModel.choosePhoto` screens a pick only for the room, which refuses an explicit one as before.
  A DM or a group takes any photo straight into the composer. The "send anyway" question is gone, with its strings.
- **Our profile photo is screened when it is set.** A face shows to everyone who sees the profile, strangers in Nearby
  included, so it is the one private surface with a public audience. `OwnProfileModel.cropPhoto` screens the cropped
  JPEG whatever the toggle says (`AvatarStore.saveOwnAvatar`). An explicit one is refused, and the profile keeps the
  photo it had. A photo the model cannot score goes, as on Android.
- **The refusal is a note under the photo, not an alert.** It lands as the cropper's page closes, and SwiftUI dropped
  an alert that started then. The walk caught it. The note stays until the next pick.
- **Unchanged:** screening on arrival, in every conversation, behind the receiver's Content filtering. The iPhone
  already hid a flagged message's words in notifications, the chat list and requests (ADR 2026-10.e4kz), which 9rh6
  added on Android.
- **Not here:** group photos, link-preview cards, the Meshtastic room and commons. The iPhone sets no group photo and
  sends no card, so nothing on those paths is screened on sending.

**Consequences / limits:**

- **A slur or an explicit photo in a DM now leaves the sender's iPhone.** A receiver with Content filtering off sees
  it. That is the receiver's choice, as on Android. This amends ADR 2026-10.e4kz's sending rule, ADR 2026-10.rpmq's
  question, and ADR 2026-10.8e2u's "refused on sending" in DMs and groups.
- **App Review:** the review notes should say that private messages are screened on the receiving phone, behind
  Content filtering, which is on by default. A reviewer who tests by sending gets refused only in Nearby.
- **The trap:** knit-next's spool protocol (§7.5) lets a spool require screening on sending for the scopes it
  carries. If the iPhone ever carries those scopes, the check returns there, and without a "send anyway" bypass.
- **The guards:** `TextScreeningTests.aDMOrAGroupSendsItsWordsUnread`, `abusiveWordsAreNotSentAndStayInTheComposer`
  (in the room), `PhotoScreeningTests.aPrivateThreadTakesAPhotoUnchecked`,
  `anExplicitProfilePhotoIsRefusedAndTheOldOneStays`, and `KnitUITests.walkContentFilter`. That walk takes a DM's
  photo with no question and audits the profile's refusal note.
