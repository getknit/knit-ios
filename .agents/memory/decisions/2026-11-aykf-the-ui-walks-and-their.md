---
id: "2026-11.aykf"
slug: the-ui-walks-and-their
title: "The UI walks and their audit advise, not block"
date: 2026-11-09
topics: [accessibility, testing, ci]
---

# ADR 2026-11.aykf — The UI walks and their audit advise, not block

Status: Accepted (2026-11-09). Amends ADR 2026-09.jcdx (the audit no longer blocks) and ADR 2026-09.jgs6 (a fourth
named advisory).

**Context:** `test:ios:simulator` took 436 s on 2026-10-01, near the six minutes ADR 2026-09.jcdx recorded. On
2026-11-08 it took 3,477 s for 43 tests, and pipeline #1384 failed on the project's one-hour limit while uploading the
result bundle of a run whose tests had all passed. It had been creeping toward that limit since October, and three
things had grown it:

- **The suite:** 10 tests on 2026-10-02, 43 on 2026-11-08. Every walk runs three times: on its own, then in the
  largest-size walk and in the dark walk (added 2026-10-04). Those two walks took 2,226 s of the 3,477.
- **`waitForExistence`:** it first looks a second in, even for an element already on screen. The walks waited
  1,237 times, and each wait took at least that second: 1,360 s.
- **`reveal`:** its two `for … where` loops checked its control sixteen times whether or not it was already in view,
  two queries a check. Queries took 637 s of the run, 13,205 of them, many of them these checks.

The Mac's runner takes one job at a time, so the next pipeline's Mac jobs queued behind this one. A finding held a
merge for a fix that could have followed it, and the maintainer wants to iterate faster than that allows.

**Decision:** `test:ios:simulator` carries `allow_failure: true`. It still runs in every pipeline and keeps its
result bundle. A finding or a failed walk now marks the pipeline as passed with warnings, and the fix follows the
merge. The rest of ADR 2026-09.jcdx stands: the walks, `AuditPolicy`'s exemptions and Knit's contrast check.

The walks are faster too. `appear` checks every 0.1 s itself instead of calling `waitForExistence`, and `reveal`
stops checking once its control is in view. Each audit then waits one second (`KnitUITests.arrival`) for its screen
to finish arriving. The old one-second floor used to give it that pause by accident: the first full run without it
failed contrast on the dark walk's name page, reading the keyboard's suggestions while the keyboard was still rising
(1.96:1), and on the sample banner at the largest size. With the pause, the whole suite passed in 2,062 s on the Mac,
against 3,477.

The first alternative is to keep the gate and raise the job's timeout. That keeps a pipeline red on findings that
could wait, and keeps the runner busy for longer still. The second is to drop the dark or largest-size walk. They
find what the default walk cannot, and together they now take 1,377 s, against 2,226.

**Consequences / limits:**

- **A finding no longer stops a merge.** The pipeline's warning and the result bundle, kept for a week, are the only
  signal. Read the job's last run on `main` before `release:testflight`, which nothing else ties to it.
- **The job still holds the Mac's runner** for its whole run.
- **The local rule is unchanged:** `.agents/rules/build-and-test.md` still runs `check.sh uitest` after a change to a
  view. `KNIT_UI_TESTS` narrows the run to one walk.
- **Removing the pause before an audit brings the flakes back.** A wait that returns as soon as an element exists
  leaves the audit reading a screen still in motion.
- **The guards:** the comment beside `allow_failure` in `.gitlab-ci.yml`, which names this ADR, and
  `KnitUITests.arrival`. A job that ADR 2026-09.jgs6 does not name as advisory still blocks.
