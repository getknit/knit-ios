---
id: "2026-09.xgtz"
slug: periphery-blocks-on-the-mac
title: "Periphery blocks on the Mac and on Linux"
date: 2026-09-28
topics: [tooling, ci, testing]
---

# ADR 2026-09.xgtz — Periphery blocks on the Mac and on Linux

Status: Accepted (2026-09-28)

**Context:** Periphery was the one code gate left advisory. ADR 2026-09.jgs6 excused it because Linux cannot
see Apple-only code, and ADR 2026-09.fkqb kept it advisory when it moved to the Mac. On 2026-09-28 the Mac scan
reported 23 findings and Linux 11. Most were not dead code:

- **18 were KnitBlueZ's D-Bus names** on the Mac, where the target compiles but its callers do not.
- **Eight were fields of four Equatable or Hashable types** that only the synthesized `==` reads: a cache key,
  a D-Bus signal key, an error's column and a fake's recorded write. Periphery does not count that read.
- **Two were deliberate:** `L2CAPLink` holds its channel so CoreBluetooth keeps it open, and `knit-peer` built its
  radio host through the concrete type, so the protocol's `init` read as unused.
- **One was dead:** `AppEnvironment` kept a second reference to the mesh, which `AppSession` already holds. Only
  the Linux scan saw it, from index records xtool's iPhone build had left behind; the Mac's host build compiles
  the app to an empty module.

**Decision:** `check.sh periphery` always runs with `--strict`. Both CI jobs block: `verify:periphery` on the
`macos` runner and `verify:periphery:linux` on `knit-local`.

- **The Mac also reads the iPhone index.** Xcode indexes while it builds, so the gate adds
  `.build-xcode/Index.noindex/DataStore` to the host's `.build/out`, and the job runs `check.sh xcode periphery`.
  The Mac skips `KnitBlueZ` and its tests, which Linux judges.
- **`--retain-equatable-properties`:** a field of an Equatable type counts as used, since it decides equality.
  A comment on each such field was the alternative. It would be noise on every key type, and the next one would
  fail the gate for the same reason.
- **The rest were fixed in code.** `AppEnvironment` drops the extra `mesh`, `knit-peer` creates its host through
  `PeerRadioHost`'s `init`, and `L2CAPLink.owner` carries a `periphery:ignore` with its reason.

**Consequences / limits:**

- **A field that only feeds `==` never reads as unused,** so a leftover field in an Equatable struct can go
  unnoticed.
- **The Mac job needs the Xcode build** before it and fails without it. It rebuilds incrementally from the
  kept `.build-xcode`, and adds a few minutes to a runner that takes one job at a time.
- **An index store keeps records for deleted files** until the tree is rebuilt, so a local scan can report code
  that is gone. Clear `.build/out` and scan again.
- **The guard:** both jobs carry no `allow_failure`. On 2026-09-28 an unused function planted in `Knit` and one
  in `KnitAppCore` each failed the Mac gate.
