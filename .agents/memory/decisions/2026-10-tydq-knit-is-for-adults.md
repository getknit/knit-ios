---
id: "2026-10.tydq"
slug: knit-is-for-adults
title: "Knit is for adults, and the Knit team reads emailed reports within 24 hours"
date: 2026-10-21
topics: [moderation, store, ui]
---

# ADR 2026-10.tydq — Knit is for adults, and the Knit team reads emailed reports within 24 hours

Status: Accepted (2026-10-21). Amends ADR 2026-10.cgm3 and ADR 2026-10.f6kf.

**Context:** App Review rejected 1.0.0 under guideline 1.2 on 2026-10-21, with the eight-item checklist ADR
2026-10.cgm3 and ADR 2026-10.f6kf were written against: "The app enables users to post content anonymously but does
not have the proper precautions in place." Six items were already in the app. Two were not:

- **"Age rating must reflect 18+."** The listing overrode the rating to 13+ (2026-10-07), and the review notes said
  Knit was for anyone 13 or older. This item is newer than the checklist quoted in 2025.
- **"Developer must act on objectionable content reports within 24 hours by removing the content and ejecting the
  user."** ADR 2026-10.f6kf deliberately promised no response time, and the notes said plainly that nobody can delete
  a message from someone else's phone or ban an account. That sentence most likely decided the rejection.

Two more were in the app but easy to miss: Delete, which removes any message from this phone at once (ADR
2026-10.u7cq), was not in the notes' 1.2 section, and the contact was two levels down, in Settings › About.

bitchat, the nearest serverless precedent, is no help. Its listing on 2026-10-21 rated it 4+ with Messaging and Chat
as the only descriptor, with no custom EULA, and its source (`5e9287f`) has block but no report, terms, filter or
contact. It passed under looser enforcement, and App Review answers a comparison with another app by reviewing each
app on its own.

**Decision:** answer the checklist in words and small changes, keeping the serverless design (option A of three put
to the maintainer on 2026-10-21; the maintainer chose it and committed to the 24 hours).

- **18+.** `listing.toml`'s `ageRatingOverrideV2` is `EIGHTEEN_PLUS`, and the notes say Knit is for adults. The terms
  open with "You must be 18 or older to use Knit." (`Copy.Terms.age`), so `Terms.version` is 2 and everyone agrees
  again at their next launch. App Store Connect keeps Apple's standard EULA: a custom one replaces it and has to
  carry Apple's minimum terms, which is legal text for a lawyer, beside the GPL's exception (ADR 2026-09.5phg).
- **24 hours.** The terms' footer, both report confirmations and Settings' new footer say the Knit team reads every
  emailed report within 24 hours. That is the maintainer's own commitment to `iosreports@getknit.app`. What acting on
  a report means is in the review notes: the reporter's phone has already deleted the message and blocked the sender;
  the team replies, and adds what the filters missed to the next release.
- **Contact at the top level.** Settings' first safety section now holds Blocked people, Report a problem (a
  `mailto:` to the report address) and Terms of use, with a footer naming the address. About keeps its Email Knit and
  terms rows.
- **The notes** answer the eight items in Apple's own order and words, name Delete, and no longer lead with what Knit
  cannot do. They still say, once, that no one can take a message off another phone.

The alternatives, put to the maintainer:

- **A ban list signed by Knit and fetched when a phone happens to be online,** applied at delivery the way a block is
  (ADR 2026-10.5wgg). It gives a real lever within 24 hours on any phone that goes online, at the cost of Knit's first
  network call, a recheck of the privacy label, and the claims that Knit uses no network. It is the next step if this
  answer is rejected again.
- **The same list flooded over the mesh,** which needs a new frame, a paired Android change and custody review, and
  puts a central authority into the mesh. ADR 2026-10.f6kf rejected it, and nothing here changes that.

**Consequences / limits:**

- **The 24 hours is a promise a person keeps.** The inbox needs watching every day, travel included. If that stops
  being true, change the copy and the notes together.
- **Nothing is ejected.** A banned person can still post from a fresh key, on every phone, as before. If App Review
  insists on ejection, the online ban list above is the answer, and it needs its own ADR.
- **An 18+ rating hides Knit from Screen Time's younger profiles,** and the terms are a statement, not age assurance.
- **Raising `Terms.version`** sends every installed Knit through the terms page once. `LiveKnit.acceptedTerms` moved
  to 2 with it, and `TermsTests.theLabIPhonesLaunchAgreesToTheseTerms` fails when they differ.
- **The guards:** `TermsTests.theTermsAreForAdultsAndEveryEmailedReportIsReadWithinADay` (the age line, the 24 hours
  in every place that promises it, and the address in Settings' footer), `CopyCatalogTests`' terms and report
  strings, and `KnitUITests.walkSettings`, which reaches Report a problem and opens the terms from Settings.
