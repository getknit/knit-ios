# Decisions

When an ADR must be read, and how a new one is recorded. Routed from
[`AGENTS.md`](../../AGENTS.md): match the trigger table here before touching code,
and read the whole file before recording an architectural or product-scope choice.

## When to read one

Every row names a **trigger** and a **file**. Follow the rows that match the task and
skip the rest. The traps live in the routed files, not here: if a trigger row starts
growing an explanation, that explanation belongs in the ADR.

| If touching | READ |
| --- | --- |
| a radio plane, a capability bit we advertise, or anything Wi-Fi Aware, LoRa, spool or Wi-Fi Direct | [ADR 2026-09.zwdp](../memory/decisions/2026-09-zwdp-knit-for-ios-meshes-over.md) |
| `KnitWire`, `KnitCrypto`, `KnitMesh`, golden vectors, or the knit-next pin | [ADR 2026-09.2ved](../memory/decisions/2026-09-2ved-knit-next-s-code-and.md) |
| the target layout in `Package.swift`, or a `#if canImport` / `#if os` guard | [ADR 2026-09.wde9](../memory/decisions/2026-09-wde9-the-protocol-core-is-platform.md) |
| the deployment target, the bundle id, `xtool.yml` or `App/Info.plist` | [ADR 2026-09.txqp](../memory/decisions/2026-09-txqp-ios-18-is-the-floor.md) |
| a CI job's `allow_failure`, a disabled lint rule, a compiler setting, or coverage floors | [ADR 2026-09.jgs6](../memory/decisions/2026-09-jgs6-each-quality-gate-blocks-from.md) |
| `COPYING`, `APP-STORE-EXCEPTION.md`, or how contributions are licensed | [ADR 2026-09.5phg](../memory/decisions/2026-09-5phg-knit-for-ios-is-gpl.md) |
| `build:ios`, the `knit-local` runner, CI caches or artifacts | [ADR 2026-09.d3jv](../memory/decisions/2026-09-d3jv-the-darwin-sdk-stays-on.md) |
| `scripts/xtool-sdk-fixup.sh`, `xtool sdk install`, or a clang module-scan failure | [ADR 2026-09.5vbh](../memory/decisions/2026-09-5vbh-xtool-builds-with-the-compiling.md) |
| DM sealing, `EncEnvelope` versions, or the capability bits `CAP_RATCHET` and `CAP_CRYPTO_V3` | [ADR 2026-09.qsd9](../memory/decisions/2026-09-qsd9-dms-seal-with-v1-static.md) |
| who dials whom, HELLO admission, link teardown, or a `Radio` adapter | [ADR 2026-09.6es2](../memory/decisions/2026-09-6es2-one-linkmanager-owns-dialing-and.md) |
| the router, custody rules or quotas, the digest exchange, or receipts | [ADR 2026-09.p6nb](../memory/decisions/2026-09-p6nb-the-iphone-relays-and-carries.md) |
| a set, map or column keyed by a frame id, a frame key or an unparsed sender id | [ADR 2026-09.jc2x](../memory/decisions/2026-09-jc2x-wire-ids-compare-by-their.md) |
| a timer, a `Task`, the `Mesh` actor, or how the engine reads time | [ADR 2026-09.gq84](../memory/decisions/2026-09-gq84-the-mesh-engine-is-a.md) |
| `KnitBlueZ`, `knit-peer`, `scripts/interop.py`, or anything that touches `hci1` | [ADR 2026-09.5ftc](../memory/decisions/2026-09-5ftc-a-headless-linux-peer-on.md) |
| the GATT payload, its UUIDs, `FLAG_DIALS_GATT_PEERS`, or `Radio.dialsGattPeers` | [ADR 2026-09.xzpt](../memory/decisions/2026-09-xzpt-an-iphone-is-found-through.md) |

## Where they live

One file per decision under [`../memory/decisions/`](../memory/decisions/). The index
at [`../memory/decisions.md`](../memory/decisions.md) is a **generated router** over
them.

## Adding one

```sh
python3 scripts/adr.py new "<title>" --topics a,b   # scaffolds the file, prints the citation
# write the body
python3 scripts/adr.py index                        # regenerates the router
python3 scripts/adr.py lint                         # markdownlint via lintorama
```

**Never hand-edit the router.** `python3 scripts/adr.py index --check` fails instead
of writing, and CI runs it.

`new` deliberately does *not* update the router: a decision appears there once it is
written, not while it is a stub.

Once the body is written, add a row under [When to read one](#when-to-read-one) if the
next task in that area would need the decision. A decision nobody is routed to is a
decision nobody reads.

## Ids are minted, not chosen

A new ADR is `YYYY-MM.suffix` with a random four-character suffix (`ADR 2026-08.k3f9`),
because a sequence number is itself the merge conflict: every branch reads the same
"next number" and takes it. Sequence ids that predate the convention stay valid.

**Cite whichever form an ADR carries, and never renumber one.** The generator refuses a
duplicate id, a missing frontmatter key, a filename that disagrees with its `id` and
`slug`, and a `# ADR …` heading that disagrees with its frontmatter. That last check is
load-bearing: every citation in the codebase resolves by grepping for that heading.

## What belongs in one

An ADR records a decision **and what it cost**. The scaffold's three labels are the
shape:

- **Context**: what was observed, and what it was mistaken for. Numbers where there
  are numbers.
- **Decision**: what changed, and what the alternative was.
- **Consequences / limits**: what this costs, what it does not cover, and the trap
  the next person will reach for. **Name the test or check that keeps it true.**

That last line earns its keep. A decision with no named guard is a decision the next
refactor undoes without noticing.

To reverse a decision, write a new ADR and change the old one's `Status:` line to
`Superseded by ADR <id> (<date>)`. Never delete an ADR: its id is cited in commit
messages that cannot be rewritten.

## Every count in an ADR is point-in-time

An ADR records what was measured **on the day it was written**. A count inside
`memory/decisions/` is evidence for that decision and **never a statement of what is
true now**. Do not quote one as the current figure, and do not carry one into a new
comment, doc or answer. Measure again instead.

## Consult before deciding

Read the router at [`../memory/decisions.md`](../memory/decisions.md) for prior choices
before making an architectural or product-scope call. The ADR is usually faster than
the argument, and a re-litigated decision should end in a new ADR that supersedes the
old one, not in a silent reversal.
