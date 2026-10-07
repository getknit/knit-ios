---
id: "2026-10.f6kf"
slug: a-report-blocks-the-person
title: "A report blocks the person and deletes the message here, and can email Knit"
date: 2026-10-07
topics: [moderation, privacy, ui]
---

# ADR 2026-10.f6kf — A report blocks the person and deletes the message here, and can email Knit

Status: Accepted (2026-10-07)

**Context:** App Store guideline 1.2 asks an app with content from other users for four things: a filter, a way to
report, a way to block, and published contact details. Filtering was in place (ADR 2026-10.rpmq, ADR 2026-10.e4kz),
and so was Block (ADR 2026-10.5wgg). Report and contact details were not, and Knit for Android has neither.

Reviewers apply a stricter checklist than the guideline's text. Rejections quoted on Apple's developer forums in
2025 and 2026 ask the developer to "act on objectionable content reports within 24 hours by removing the content and
ejecting the user who provided the offending content", and want contact details inside the app. Knit has no server.
Nobody can take a message off other phones or eject anyone from the mesh, and a fresh key costs nothing.

The maintainer chose on 2026-10-07 to read "act" as what the reporter's own phone can do, which is immediate and is
all a serverless app can do, and to set up `iosreports@getknit.app` for the email.

**Decision:** a report does on this phone what a delete and a block do, and the user may also email it to Knit.

- **Where:** a message's long-press menu, on someone else's message only (and VoiceOver's actions), a profile, and a
  DM request's swipe. A group's request has nobody to report, as it has nobody to block. Our own messages and status
  lines have no Report.
- **What it does here** (`AppSession.report`): deletes the reported message (ADR 2026-10.u7cq), so an unblock never
  brings it back, then blocks the author (ADR 2026-10.5wgg), which hides the rest of what they wrote and withdraws
  their notifications. A report from a profile or a request blocks without deleting. Nothing goes on the wire and
  custody reads nothing new, so the mesh sees no change.
- **The confirmation** is an alert, as Block's and Delete's are: Report and Email Knit, Report, or Cancel. Both
  Report buttons file the report first.
- **The email** (`ReportEmail`) is plain text the user reads, edits and sends from their own mail, or cancels. It
  carries the person's label and node id, where (Nearby, a DM, a group and its title, a request, a profile), the
  message's words and send time in ISO 8601 UTC, their status line from a profile, and the app's version and build.
  The words go in whatever the content filter hid: the user is reporting them.
- **No photo, ever.** The email says one came with the message and leaves it out. A reported photo may be CSAM, and
  once one reaches Knit's inbox, Knit has actual knowledge, which brings reporting duties to NCMEC in the US
  (18 U.S.C. 2258A). Words carry no such risk.
- **How it opens:** Mail's composer when Mail has an account; else the phone's `mailto:` handler; else an alert that
  names the address, with Copy Address. App Review's phones may have no mail account, so the last step is not an
  edge case.
- **Contact:** About gains an Email Knit row with the same address.

The alternatives:

- **A report server, or a signed ban list flooded over the mesh:** either one puts a central authority into a
  serverless design. A ban is also cheap to dodge, because a fresh key costs nothing, and the App Privacy label would
  stop being "Data Not Collected".
- **A report that never leaves the phone:** it meets the checklist's letter, but gives the reviewer nothing for
  "timely responses to concerns".
- **Block as a separate checkbox on Report:** the maintainer judged report and block the same act on one phone. A
  checkbox would also need a dialog that iOS 27 draws badly (ADR 2026-10.5wgg).

**Consequences / limits:**

- **A report removes nothing from anyone else's phone.** The review notes have to say so plainly, and say what Knit
  does with an email: reads it, replies, and adjusts the filters in a later release.
- **The email is optional, and data the user sends.** It is sent only when the user taps Send in their own mail.
  Recheck the App Privacy label against Apple's wording on optional, user-initiated data before submitting.
- **The copy promises no response time.** "The Knit team will read it" is the only commitment. If someone commits
  to 24 hours, the copy changes with it.
- **Android has no report.** The email says "for iPhone", and a paired change can bring the same flow to Android
  later. Google Play's policy on user-generated content likely asks for one too.
- **The trap:** reporting through the mesh, or anything custody reads, breaks what ADR 2026-10.5wgg found about
  per-node inputs to custody. A report belongs on the delivery path and in the stores, like a block.
- **The guards:** `ReportTests` in KnitAppCore (what a report deletes and blocks from each place, never ourselves,
  the email's fields, and the `mailto:` link's escaping of `&` and `+`), `CopyCatalogTests`' report strings,
  `AccessibilityIDTests.eachReportNamesWhatItReports`, and `KnitUITests`' two report walks: a room post reported
  from its menu, and a profile's Report and Email Knit reaching the no-mail alert in the Simulator, which has no
  Mail.
