# Review rounds

How a change in a gated plane meets its reviewer personas (`.agents/personas/*-reviewer.md`): when each one looks,
what a pass reads, which findings hold the change up, and when to stop patching. `.agents/rules/owners.md` says who
writes and who judges; this file says how the rounds run. The main session reads it before it spawns a reviewer or
relays one's findings, and every reviewer reads it to learn which pass it is on. The Stop hook
(`.claude/hooks/review-gate.sh`) enforces the order and hands a follow-up pass its delta. Ported from knit-next's
rule of the same name (knit-next `14417f73`).

Why it exists: knit-next's #195 took five full rounds of three reviewers each. The first design guessed, on each
phone, whether a pull ask came from the phone that wanted the blob or from an echo. Every round closed one loop and
found the next, until the design gained the signal it lacked (knit-next ADR 2026-10.2drc). Each pass also re-read the
whole diff, so findings unrelated to the last round kept arriving.

## 1. Review the design before the code

- When `owners.md` says to delegate a change to an owner, the main session first spawns that plane's reviewer on the
  plan: the brief it is about to send, with the files it would change. This is the **design pass**.
- The design pass reads the plan and the code the plan would change, walks the plan against its catalogue, and
  reports findings in its usual form, each labelled as in section 3. It runs no tests and stamps nothing: the gate
  watches code, and none has moved.
- A blocking design finding changes the plan before the owner starts. The brief carries the non-blocking ones, so the
  owner designs against them.
- Skip it for a fix of a few lines whose shape the issue already names.

## 2. The plane reviewers go first, the test reviewers after

- Stage 1 is the plane reviewers (`bluetooth-reviewer`, `blobs-reviewer`, `crypto-reviewer`). Stage 2 is the test
  reviewers. This port has none yet: the mesh-lab reviewer waits for the lab (`.agents/memory/roadmap.md`).
  `review-gate.conf` records each reviewer's stage.
- Stage 2 runs once no stage-1 review is pending. While a stage-1 reviewer is pending (owed, or asked for and not yet
  stamped), the gate lists only stage 1. That way a test reviewer never reviews tests written for a design the plane
  reviewer is about to reject.
- Reviewers in one stage run in parallel, spawned in one message.

## 3. Every finding is Blocking or Non-blocking

A reviewer labels each finding, and the verdict counts the blocking ones: `CLEAN`, or `FINDINGS: <n> (<b> blocking)`,
each finding opening with `[Blocking]` or `[Non-blocking]`.

- **Blocking:**
  - the change ships or keeps wrong behaviour: a loop or a strand (work that never ends, a frame or blob never
    delivered, a pair that never converges), a wedge, a crash, a leak, a security or privacy hole;
  - a wire, vector, convergence or frozen-string break;
  - a test that cannot fail on the behaviour the change exists for;
  - a flake whose window a busy CI runner or a sanitizer run reaches in ordinary scheduling.
- **Non-blocking:**
  - a cost the reviewer can bound (a tick's delay, a few extra frames, a slower recovery);
  - a secondary test claim that cannot fail, or an oracle looser than the code;
  - a flake whose window needs a stall the test's own timings rule out;
  - a doc's wording, a stale comment, a cleanup.
- When the label is in doubt, the finding is Blocking, and the report says why it is in doubt.

Only a blocking finding opens another round. The main session applies every blocking finding together with the
non-blocking ones in one batch, or hands that batch to the owner. With no blocking finding left, it either has the
non-blocking ones applied (the gate's follow-up pass then checks them) or lists them for the maintainer as follow-ups.
It never runs another full round for non-blocking findings alone.

## 4. A follow-up pass reads the delta

- A reviewer that stamped this change before, with no commit since that touched its paths, is on a **follow-up
  pass**. The gate writes the diff since its stamp to `<git dir>/claude-review/<name>.delta` and names that file in
  its message. The caller hands the reviewer the file and its previous findings.
- A follow-up pass:
  1. lists each previous finding as closed, or still open and why;
  2. reviews the delta, reading the whole function around each hunk and any new file whole;
  3. counts a new finding outside the delta only if it is Blocking. A non-blocking one outside the delta goes on a
     `Follow-ups:` line after the findings and does not count in the verdict;
  4. runs only the checks the delta touched (section 6), and stamps.
- A commit since the stamp that touches the reviewer's paths makes the next pass a full one.

## 5. Stop patching after two rounds

A round is the reviewers' pass over one batch of fixes. When two rounds in a row each bring a new blocking finding (a
finding still open from before does not count), the main session stops sending fixes. It names the cause the findings
share and puts the options to the maintainer: a different mechanism, a wire field, a paired change with knit-next, a
narrower scope. Only then does an owner write more code.

## 6. Don't run a check twice on one tree

- The owner runs `scripts/check.sh format lint` before its last `swift test` run, so that run covers the tree the
  reviewers read.
- A reviewer reruns a suite only when the change it reviews (the delta, on a follow-up pass) touched that suite or
  the code it drives. On a follow-up pass, `scripts/sync-vectors.py --check` runs only if the delta touched a wire
  type, a seal or a vector.
- The Mac gate runs once, in the main session, after the last round has no blocking finding (`owners.md`). A
  reviewer never runs it.
