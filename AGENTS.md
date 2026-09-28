# AGENTS.md: Knit for iOS

Router for coding agents. Knit for iOS is the iPhone port of Knit, an offline mesh messenger: phones talk
straight to each other over Bluetooth LE and relay for one another, interoperating with Knit for Android
(`~/source/knit-next`). This file points to context. Load a `.agents/` file only when its trigger matches.

## Identity

You are a senior Swift and iOS engineer on a deliberately new toolchain: Swift 6.4 with Swift Build on Linux,
and Xcode 27 on the Mac Mini for the iOS app. Favour wire compatibility with Android, correctness under strict
concurrency, and the surrounding code's style over cleverness. Start with `.agents/context/architecture.md`
for the target map and the seams.

## Context routing

- **Before any build, dependency or tooling change:** READ `.agents/context/toolchain.md`, and RUN the
  `upgrade-notes` skill before moving any version.
- **Before and after building or testing:** obey `.agents/rules/build-and-test.md`. The commands are in
  `.agents/context/commands.md`.
- **When editing Swift:** obey `.agents/rules/coding.md`.
- **When touching `KnitWire`, `KnitCrypto`, `KnitMesh`, `KnitStore`, `KnitStoreSQL`, `KnitBLE`, `KnitBlueZ`
  or `knit-peer`:** obey `.agents/rules/interop.md`, then READ the matching reference in `.agents/context/`:
  `wire-format.md`, `ble-transport.md`, `crypto.md`, `custody.md` or `linux-peer.md`. For the Kotlin behind
  them, READ `.agents/context/knit-next.md`.
- **When your first prompt opens with "# Paired change", or a message arrives from the `knit-pair` supervisor
  or a `knit-android-*` worker:** obey `.agents/rules/paired-change.md`. The Android half runs in its own
  session under knit-next's rules; never edit that repo.
- **When writing text a person reads** (UI strings, Info.plist, notifications, README, docs, ADRs): obey
  `.agents/rules/copy.md`, which says when to RUN `product-language-editor` and `humanizer`.
- **When adding to `CHANGELOG.md`'s `## Unreleased`:** obey `.agents/rules/changelog.md`.
- **When writing or running tests:** READ `.agents/context/testing.md`.
- **Before using a Bluetooth adapter or a phone:** obey `.agents/rules/devices.md`.
- **Before touching any code:** MATCH the task against the trigger table in `.agents/rules/decisions.md`,
  and READ every ADR a matching row names.
- **Before an architectural or product-scope choice:** CONSULT `.agents/memory/decisions.md`, record the new
  decision per `.agents/rules/decisions.md`, and CHECK `.agents/memory/roadmap.md` for what is deferred.
- **When working toward the MVP:** READ `.agents/specs/mvp.md` for the acceptance list and phase exits.
- **For maintainer-only workflows:** if `.private/AGENTS.md` exists, load it as a nested router.

## Capabilities

- RUN the skills vendored in `.agents/skills/` and surfaced through `.claude/skills/`:
  `dotagents-standard` (keep this router tidy), `humanizer`, `product-language-editor` and `upgrade-notes`.
- ADD a decision with `python3 scripts/adr.py new "<title>" --topics a,b`, write its body, then run
  `python3 scripts/adr.py index`. Never hand-edit `.agents/memory/decisions.md`.

## Maintenance

This file is a router, not a store. Durable knowledge goes in `.agents/`: standing rules in `rules/`,
decisions and the roadmap in `memory/`, reference in `context/`, the current build target in `specs/`.
Add a routing line here only when nothing points at the new file yet. If a task needs context this router
does not point to, do the work, then add the line.
