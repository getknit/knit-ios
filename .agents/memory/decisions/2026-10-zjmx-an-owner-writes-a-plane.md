---
id: "2026-10.zjmx"
slug: an-owner-writes-a-plane
title: "an owner writes a plane's change and a separate reviewer judges it"
date: 2026-10-13
topics: [tooling, testing, interop]
---

# ADR 2026-10.zjmx — an owner writes a plane's change and a separate reviewer judges it

Status: Accepted (2026-10-13)

**Context:** most fixes in this repository are one kind of defect. The code passed `swift test` on Linux, then
broke on an iPhone, a Pixel or a BlueZ adapter, and a device trial or a soak found it days later. On `main` by this
date that covers 14 Bluetooth shapes (restoration, suspension, the overflow area, PSM reuse, bluetoothd acting on
links) and 5 custody shapes (a newcomer starved by the serving order, a receipt before its DM, the port drifting
from the Kotlin). Most were caught on hardware, because nothing in the session knew the shape to look for.

knit-next hit the same wall and built a fix in stages. A mesh-lab reviewer and its Stop hook came first
(knit-next `ee71be89`, 2026-09-24). Then a generic gate and the first platform reviewer (`71c07bcd`, 2026-10-04).
Owners came last (`a71e3040`, `3061d59a`, 2026-10-08 and 09), because changes kept going back for several review
passes. knit-next ADR 2026-10.5buf records the reviewer's second, fourth and fifth passes on one change. An owner
loads the reviewer's catalogue before it writes, so the change starts out written against it.

**Decision:** three planes get an owner and a reviewer, each a Claude Code subagent defined in
`.agents/personas/` and linked from `.claude/agents/`: Bluetooth (the link manager, CoreBluetooth and BlueZ), blobs
and custody, and crypto (v1 DMs and groups). The main session delegates a plane's implementation to its owner with
a self-contained brief, then spawns that plane's reviewer on the diff. The reviewer is never the agent that wrote
the change. An owner never commits, drives a device or edits knit-next. A reviewer never edits the tree. Its one
write is a stamp in the git directory. The table, the brief and the hub files the hook cannot see are in
`.agents/rules/owners.md`.

A Stop hook, `.claude/hooks/review-gate.sh`, ported from knit-next, holds the turn once while an uncommitted change
under a reviewer's paths (`.claude/hooks/review-gate.conf`) has no review. It honours `stop_hook_active`, so it
nudges once and never traps a session. It hashes diffs and builds nothing, which keeps it inside ADR 2026-09.jgs6's
rule that Stop hooks run no builds. The reviewers it asks for run their own targeted tests.

Left out: LoRa and Wi-Fi Aware, which iOS does not implement (ADR 2026-09.zwdp, ADR 2026-10.2c6c), and the mesh-lab
reviewer, which waits for the lab (`.agents/memory/roadmap.md`). knit-next's doc-lint waits too. A convention test
stands in for its cheapest checks.

The obvious alternative was to have the main session review its own change against a checklist. knit-next's
history argues against it: a reviewer that did not write the change, holding only the catalogue and the diff, is
what found the defects the ADRs above cite.

**Consequences / limits:**

- The gate sees uncommitted changes only. A paired-change worker commits on its branch, so
  `.agents/rules/paired-change.md` asks for the review before the commit.
- The gate works per file. A plane's paths inside a hub file (`MeshEngine+Inbound`, `AppEnvironment`) are routed
  by the "Adopt for" column in `.agents/rules/owners.md`, which the hook cannot enforce.
- On Linux, `KnitBLE` and `Knit` compile to empty modules, so a reviewer's green run says nothing about them. The
  caller runs the Mac gate once, after the findings are applied, and reviewers never call `scripts/mac.sh`.
- Reviewers spawned together share one `.build`. SwiftPM's lock makes their test runs take turns.
- The personas are public, like the rest of the repository. They name lab phones by model and point at
  `.private/lab.env` for addresses, serials and node ids. They cite only commits on `main`.
- A catalogue goes stale as code moves. `Tests/RepoConventionTests/PersonaTests.swift` keeps the wiring true: each
  persona has its link, a gate line and a row in `owners.md`; each owner has a reviewer; each reviewer lacks `Edit`
  and `Write`; and every path and ADR id the personas cite resolves. A symbol that is renamed waits for a doc-lint.
