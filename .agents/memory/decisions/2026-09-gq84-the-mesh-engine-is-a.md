---
id: "2026-09.gq84"
slug: the-mesh-engine-is-a
title: "the mesh engine is a synchronous state machine behind one actor"
date: 2026-09-25
topics: [architecture, concurrency, testing]
---

# ADR 2026-09.gq84 — the mesh engine is a synchronous state machine behind one actor

Status: Accepted (2026-09-25)

**Context:** knit-next's mesh runs on coroutines. Each periodic job is a `delay()` loop, and the router
launches one coroutine per pending relay. Its lab tests pass on a fast machine and fail one run in thirty on
a loaded one, which is why it grew a chaos harness and a reviewer persona that catalogues flake shapes. The
iPhone's dependencies are synchronous: GRDB, the in-memory stores and swift-crypto all return at once.

**Decision:** `MeshEngine` (routing, custody, profiles, receipts, key recovery) and `LinkManager` are
synchronous, single-threaded classes. They read time from an injected `MeshClock`, draw randomness from an
injected generator, keep every timer as a deadline they report through `nextDeadline`, and fire it in
`advance()`. One actor, `Mesh`, owns both: it feeds them radio events one at a time, runs a single timer task
aimed at the earliest deadline, and takes the app's sends. Tests drive the engine and the link manager with
a clock they move by hand and never sleep. The alternative, an actor per component with its own tasks,
would reproduce knit-next's scheduling races and make every test await quiescence.

**Consequences / limits:** nothing may block inside the actor for long, so a database write stays short and
crypto stays off any lock the radio needs. A new periodic job is a deadline the engine reports, never a
`Task.sleep`. The SwiftLint clock and randomness bans enforce that in the protocol targets. The multi-node
mesh lab is deferred at the maintainer's request (2026-09-25), and a synchronous core is what would let a
later lab run deterministically from a seed. `MeshTests` covers the actor under TSan in `scripts/check.sh`.
