# Owners and reviewers

Who writes and who judges a change in the planes that keep breaking on hardware. Routed from
[`AGENTS.md`](../../AGENTS.md); the decision is ADR 2026-10.zjmx.

Each plane has an **owner**, a subagent that writes and tests its changes, and a **reviewer**, a subagent that
reads the diff against a catalogue of defects this repository already shipped and fixed. The reviewer never wrote
the change it judges. Both are defined in `.agents/personas/` and linked from `.claude/agents/`, so Claude Code
spawns them by name.

## The planes

| Plane | Owner, reviewer | The hook gates | Adopt the reviewer too for | Read first |
| --- | --- | --- | --- | --- |
| Bluetooth | `bluetooth-owner`, `bluetooth-reviewer` | the link manager, `KnitBLE`, `KnitBlueZ` and knit-peer | the restoration and scene-phase paths of `Sources/Knit/App/AppEnvironment.swift`, `Sources/Knit/App/Launch.swift` and `Sources/Knit/KnitApp.swift`, and `App/Info.plist`'s `UIBackgroundModes` | `.agents/context/ble-transport.md` |
| Blobs and custody | `blobs-owner`, `blobs-reviewer` | the router, custody, receipts, recovery and blob exchange, their stores, the periodic passes, `FileIntake`, `FeedMeter` and `LinkManager+Files`, and the store unit (`StoreTransactor`, `KnitDatabase+Units`), which both reviewers judge | the custody, block and delete paths of `MeshEngine+Inbound`, `MeshEngine+Outbound`, `MeshEngine+Deletes` and `MeshEngine+Blocks` | `.agents/context/custody.md` |
| Crypto | `crypto-owner`, `crypto-reviewer` | `KnitCrypto`, the envelopes, the sealed plaintexts and the capability bits, groups and their roster, pinned keys, the Keychain store, the store unit, and the ratchet's own files as each phase adds them (ADR 2026-10.5sk9) | the verify and open paths of `MeshEngine+Inbound`, the seal paths of `MeshEngine+Outbound`, and, once the ratchet seals them, the receipt, reaction and profile paths of `MeshEngine+Outbound`, `MeshEngine+Reactions` and `MeshEngine+Profiles` | `.agents/context/crypto.md` |

The exact paths are each reviewer's line in `.claude/hooks/review-gate.conf`. `FeedMeter`, `LinkManager+Files`,
`MeshEngine+Delivery`, `TickSealing`, `StoredText`, `MeshStores` and the group form's three engine files sit in two
planes on purpose: a change there owes both reviewers. `MeshEngine+Delivery` writes a delivered message's row inside a
ratchet open's store unit, and fetches its photo and sends its receipt after it. `TickSealing` is the delivery-tick
ledger's protocol, whose seams seal. `StoredText` is the SQL stores' reader of every stored string, ids included.
`MeshStores` names every store the memory unit puts back when it fails. `MeshEngine+GroupRatchetInbound` opens group
frames and replays them from custody past the router. `MeshEngine+GroupRatchetOutbound` carries each seed DM and group
frame in the send unit and floods them after it commits, and `MeshEngine+GroupRatchetSeedSends` re-sends seeds from the
flushes.

A change in a hub file that the hook gates for no one (`Mesh.swift`, `MeshEngine.swift`, the `MeshEngine+Inbound`
family) still owes the reviewer whose plane the changed lines belong to. The "Adopt" column names those paths,
because the hook cannot see them.

## Delegating to an owner

Implementation work in a plane goes to its owner. The fixes that apply a reviewer's findings are yours, and the
reviewer's stamp lets those few lines through.

The owner sees only its brief, so make the brief complete:

- the goal, and the issue or ADR behind it;
- which of these are in scope, in words: a wire change, a paired change (with the contract), a schema change, the
  Mac build, lab hardware;
- anything you already know that rules out an approach.

The owner leads its report with `DONE`, `PARTIAL: <what's left>` or `BLOCKED: <the question>`. A question that
changes behaviour on air or across the pair is yours or the maintainer's to answer. Never tell the owner to guess.

An owner never commits, never drives a phone or an adapter, never edits knit-next and never messages another
session. You do those, under the rules that govern them.

## Running the reviewer

Spawn the plane's reviewer once the owner reports, or once you have edited a plane's file yourself. Spawn every
reviewer a change owes in one message. Their `swift test` runs share one `.build`, and SwiftPM's lock makes them
take turns. Hand each one the changed files and, from the owner's report, the assumptions it lists about the
platform, the pair or the mesh.

Apply each finding, or say why it does not hold. Then give the maintainer the findings and the trial the reviewer
names: the device trial, interop run or two-engine test the change still owes.

Reviewers run on Linux. `KnitBLE` and `Knit` compile to empty modules there, so after you apply the findings, run
the Mac gate yourself (`scripts/mac.sh run scripts/check.sh xcode`, `.agents/rules/build-and-test.md`). A reviewer
never calls `scripts/mac.sh`.

## What the Stop hook sees

`.claude/hooks/review-gate.sh` runs when a turn ends. It holds the turn once if an uncommitted change under a
reviewer's paths has no review, and names every reviewer owed.

- Each reviewer runs `review-gate.sh --stamp <name>` as its last step. The stamp lets through the edits that apply
  its findings, up to the follow-up lines in the conf. A commit, a file the review never saw or a larger change
  needs a fresh review.
- It sees uncommitted changes only. Review a change before you commit it (`.agents/rules/paired-change.md` says the
  same for paired work).
- It honours `stop_hook_active`, so a second stop in a row always ends the turn. It nudges, and the review is still
  owed.
- Its state lives in the git directory (`claude-review/`), so each worktree keeps its own.

## Adding a plane

A new plane is a pair of personas, their two links in `.claude/agents/`, a line in `review-gate.conf`, a row in the
table above and a row in `.agents/rules/decisions.md`. `PersonaTests` in `Tests/RepoConventionTests/` fails until
the pieces agree. Write the reviewer first, from this repository's own fix history, citing commits on `main`. Then
write the owner, which loads the reviewer's catalogue before it writes anything.

Not yet here, each waiting on what it reviews (`.agents/memory/roadmap.md`): the mesh-lab reviewer, a Wi-Fi Aware
pair and a doc-lint for the personas.
