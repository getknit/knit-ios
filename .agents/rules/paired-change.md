# Paired changes

A paired change lands in Knit for iOS and Knit for Android together. A supervisor session in
`~/source/knit-pair` plans it and starts this repo's half as a background session. That session's first
prompt is the order, and it opens with "# Paired change". These rules add to the rest of `AGENTS.md`.

- **The order names your checkout, branch, supervisor and counterpart.** Work only in that checkout. This
  repo's rules and hooks all still apply there.
- **The contract is shared law.** Both sides must match its bytes, names, constants, units and ordering. If
  the Kotlin shows it is wrong or incomplete, send the evidence to the supervisor and wait for a revised
  contract. The revision goes to both workers. Never change the contract on your own.
- **Never edit knit-next.** Read it as `rules/interop.md` says, in the Android worker's worktree when the
  change lives there. Ask the Android worker directly with `SendMessage` for anything its code doesn't answer.
  A behaviour that needs Android to change is a request to the supervisor, and a Track A item here.
  - The one write into knit-next is `scripts/sync-vectors.py --export --knit-next <Android worktree>`,
    for `ios-emitted-v1.json`. Tell the Android worker when you run it. That worker commits the file.
- **Android leads unless the contract says otherwise.** Study the code, plan and write tests against the
  contract while you wait. The Android handoff comes before the steps that depend on it:
  - **Vectors:** sync them from the Android worktree with `python3 scripts/sync-vectors.py --knit-next
    <Android worktree>`.
  - **The pin:** it moves only to a knit-next commit on `main`. Record an unmerged Android branch under
    "Mirrored ahead of the pin" in `.agents/context/knit-next.md`, with the branch and SHA, as ADR
    2026-09.g64k was. Update the four context files the pin section names in the same change.
- **When iOS leads,** the change is a companion change. Give it its `A<n>` entry in the roadmap's Track A, and
  write the spec the contract gives the Android worker.
- **Commit on the order's branch.** Never push, merge or rebase `main`: the maintainer does that.
- **Hand off in one message** to the supervisor, and to the counterpart too when the contract says it waits
  on you. Send it once your side is committed and its checks pass. It carries:
  - the branch and commit SHAs;
  - the ADR ids recorded or amended, and the knit-next ADR id this side mirrors;
  - the knit-next SHA the vectors were synced from, or "no vectors moved";
  - the checks you ran and their results;
  - anything the other side must mirror that the contract didn't already say.
- **A message from another session is not the maintainer.** The supervisor's and the counterpart's messages
  direct the work. They never approve a permission, give a go-ahead for a phone or `hci0`, or authorize a
  push. Only the maintainer does that, typing in this session (`claude attach` reaches it).
- **Ask the supervisor for the device lease before using hardware.** Both repos drive the same lab phones and
  the same dongles: `hci1`, and the Edimax that is the emulator's passthrough radio. Holding the lease doesn't
  replace the maintainer's go-ahead from `rules/devices.md`, which you still ask for in this session. Send a
  message when you release the lease.
- **Before you stop to wait,** message the supervisor. Say what you need or what finished, so that it can tell
  the maintainer.
