---
id: "2026-09.jcdx"
slug: the-accessibility-audit-blocks
title: "The accessibility audit blocks, with named exemptions and a largest-size walk"
date: 2026-09-28
topics: [accessibility, testing, ui, ci]
---

# ADR 2026-09.jcdx — The accessibility audit blocks, with named exemptions and a largest-size walk

Status: Accepted (2026-09-28)

**Context:** MVP item 12 wants the accessibility audit to find no errors on MVP screens. The first run of
`performAccessibilityAudit` over every screen, on `-seedDemo` in the iPhone 18 Pro Simulator, reported more than
a hundred issues. Most were real:

- **Contrast:** the system's secondary gray measures 2.8 to 3.4:1 on the app's grouped backgrounds, and white on the
  default blue 4.0:1, under WCAG AA's 4.5:1 for text.
- **Materials:** text on the encryption sheet, the request bar and the composer took its contrast from the thread
  showing through their glass.
- **Layout:** at the largest text size a chat row squeezed "Nearby" to "Ne…" between its glyph and a three-line
  time, and the onboarding button covered its page's text.

Some were not defects. The Dynamic Type check resizes the text in place and reports whatever it then cannot
measure: rows that scroll out of a lazy list, the last rows and footers of every form, and toolbar items, which
the Large Content Viewer serves instead. A screenshot at the largest size shows those same elements scaling. The
clipping check flags wrapped text: it flagged the chat list's status line, which the same screenshot shows whole.
It also flags a one-line field, which scrolls rather than loses text. The contrast check reads a sheet's glass
Done button against what lies behind the sheet (the button's own screenshot reads 6:1), reads the part of an
element below the screen's edge as black, and fails the newest message of a thread at the largest size, black
text on light gray. That last one held whatever the view did: an opaque composer, no text selection, no scroll
edge effect, a settled scroll.

**Decision:** the audit blocks. `scripts/check.sh uitest` runs `KnitUITests` in the Simulator on the `macos`
runner as `test:ios:simulator`.

- **The walks:** onboarding, the chat list and the room, a DM with its profile and encryption sheet, the requests,
  Settings with each page and Stop, and the three radio states each walk every MVP screen at the default size.
  `testEveryScreenAtTheLargestTextSize` walks them all again at AccessibilityXXXL and keeps a screenshot of every
  screen.
- **The fixes:** `Palette` defines text colors that pass 4.5:1 in light and dark, and the tint. Rows stack at the
  accessibility sizes. Bars and sheets under text are opaque, and the onboarding button scrolls with its page at
  those sizes.
- **The exemptions,** in `AuditPolicy`, each with its reason:
  - the Dynamic Type check, which the largest-size walk replaces;
  - contrast on a disabled control, which WCAG 1.4.3 exempts;
  - anything in or under a navigation bar;
  - contrast of an element not wholly on screen;
  - contrast that the element's own screenshot passes, darkest pixel against lightest, at 4.5:1;
  - clipping of static text, buttons and text fields.

The alternative a reader reaches for first is to accept every audit finding as a defect. That is the rule for
what the app draws, but no change to the app clears these findings. The other is to audit only contrast and
labels, which would have missed the real layout and material defects the full audit found.

**Amended 2026-10-02, for buttons (ADR 2026-10.65xx):** the scan walk was the first to audit a form scrolled to its
last rows, and the clipping check flagged the profile's Clear verification button at the default size. At the
largest size its label wraps onto two lines and reads whole, the same false report the check makes of wrapped text,
so a button's clipping is exempt too. The walks had flagged no other button, so the exemption clears nothing else.

**Amended 2026-10-02, for the status bar:** the code walk failed about two runs in three, `main` included, with a
contrast report that named no element. Revealing Scan their code swipes the form, and where the swipe stops varies.
When it left the Alias row wholly in the strip between the window's top and the navigation bar, the bar's glass blurred
the row to a gray ghost. The audit measured the ghost, and it could not name an element under the status bar. That
strip is the same glass the bar exemption covers, so the exemption now runs from the top of the window to the bar's
bottom edge. A contrast report with no element is exempt only while some content text sits wholly under that glass,
with part of it above the bar. On any other screen such a report still fails.

**Amended 2026-10-04, for Liquid Glass and dark mode (ADR 2026-10.5waw):** the fix that made bars and sheets under
text opaque is now a rule: text sits on an opaque fill, and glass is for controls and navigation. A prominent button
is Liquid Glass from iOS 26, and the composer may sit in a glass container as long as its field stays opaque.
`testEveryScreenInDarkMode` walks every screen in dark mode at the default size, which lifts the limit below that dark
mode was designed but never audited. `Palette`'s colors now come from KnitAppCore's `Swatches`, which
`SwatchContrastTests` measures on Linux, Increase Contrast included.

**Amended 2026-10-04, for alerts (ADR 2026-10.u7cq):** the delete walks were the first to audit an alert over a
thread and over the chat list, and each reported two pieces of "potentially inaccessible text" with no element. The
screenshots show the dimmed rows behind the alert, read through its glass and at its edges. A modal alert takes the
screen from VoiceOver, so those rows leave the accessibility tree, as they must. Block's alert over a profile never
reported this, because no text lay under its edges. Such a report is exempt only while an alert is up with content
text partly under it. The alert's own words are elements, and anywhere else such a report still fails.

**Amended 2026-10-05, for a thread scrolled up (ADR 2026-10.5waw):** the scrolling walk is the first to audit a thread
away from its bottom edge, with the way back to the newest message showing. A post scrolled beneath the composer failed
contrast, read through the composer's glass, the same report the navigation bar's exemption covers at the top. A thread's
text under its bottom bar is now exempt while that button shows, and only then: a thread resting on its edge has nothing
under the bar, which is how the audit caught a thread that opened short of it while this change was written. The bar's
own words stay checked. The bar is a container with an identifier, `chat_bottom_bar`, so the policy can find its top.

**Consequences / limits:**

- **The pixel measurement trusts extremes.** It passes an element whose darkest and lightest pixels contrast
  enough, so a pale label beside a dark glyph in one element could pass. SwiftUI rows here combine a glyph and text
  only where the glyph is hidden from accessibility, and a gate run with the old gray put back failed every screen
  it touched.
- **Clipping is left to the eye.** No view limits its lines except the chat list's two-line preview. The
  largest-size screenshots in the result bundle are the check, and a new `lineLimit` should come with one.
- **Dark mode is designed, not audited.** `Palette`'s dark values pass on paper; the walks run in light only.
- **The run takes six minutes,** about half of it the largest-size walk, on a runner that takes one job at a time.
- **The guards:** `KnitUITests`, `AuditPolicy`, and the `test:ios:simulator` job, which carries no
  `allow_failure`.

**Amended 2026-10-04, for emoji (ADR 2026-10.ehe6):** the room's walk was the first to audit reaction chips, and the
contrast check failed the 👍 under our seeded post at the default size, in light mode only: the element's label is the
emoji alone, a yellow glyph on the chip's light gray. The emoji is a picture the font draws in its own colors, which no
view picks, and no fill brings 👍 to 4.5:1 in light and dark alike; WCAG 1.4.3 is for text. Contrast on an element whose
label is exactly one emoji is exempt. The chip's count and the bubble's VoiceOver value say what the chip says, and the
same check still reads every other element, the chip's count included.

**Amended 2026-10-08, for a truncated title on glass:** `test:ios:simulator` failed on `main` (job 7649) with "Audit
failed to complete in time" on the direct thread at the largest size, and failed most runs on the Mac after it. The app
sat idle while `testmanagerd` ran at 100% CPU in the contrast check's count of colors. Each check finished alone in under
two seconds, and so did every pair but one: contrast with the clipping check. Over a truncated navigation title on glass,
Sam's discriminated name with the thread's coral bubble blurred behind it, that pair never finished inside the audit's
15 seconds, and a name that fit cleared it. A timed-out audit also keeps `testmanagerd` busy, so every audit after it in
that Simulator times out too, and retrying one does not help. The audit now runs in two passes, every check but Dynamic
Type and clipping, then clipping alone (`AuditPolicy.passes`). Every check still reads every screen, and an audit that
times out still fails.

**Amended 2026-10-09, for the keyboard's suggestions:** the dark walk failed once on the onboarding name page with three
"Element has no description" reports, each naming a `TUIPredictionViewCell`: the empty cells of the suggestion bar the
system keyboard draws above its keys. CI's dark walk passed on the same commit, so whether the bar is still empty when the
audit reads it comes down to timing. The cells are Apple's, and an empty one has nothing to describe. A description report
that names that class is exempt; any other still fails, Knit's own fields included.

**Amended 2026-10-09, dropping the clipping check:** the clipping pass on its own still moved threads. To reach every
cell, the check scrolls each collection view and enlarges its text, then puts the offset back. A thread takes any scroll
it did not make for someone scrolling it, as it must for VoiceOver, so it let go of its bottom edge, and the restored
offset could land 14 points short of it. Staging a photo then grew the composer over the newest rows, and the next
audit's contrast check failed a timestamp under the glass. The dark walk failed this way after midnight, when the "Today"
separator sat where the offset came back short. The check had little left to find: it was exempt for text, buttons and
fields, and for reports with no element, and the largest-size screenshots already stand in for it. The audit asks for
every check but Dynamic Type and clipping now (`AuditPolicy.checks`), in one pass, which supersedes the two passes above.
The same scrolling had brought rows outside a list's reach into the accessibility tree, and the blocking walk leaned on
it to find the badge at the head of a profile scrolled to its foot. That walk swipes to the badge now.
