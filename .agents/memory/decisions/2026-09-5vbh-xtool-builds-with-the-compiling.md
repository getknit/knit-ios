---
id: "2026-09.5vbh"
slug: xtool-builds-with-the-compiling
title: "xtool builds with the compiling toolchain's clang headers"
date: 2026-09-25
topics: [toolchain, build]
---

# ADR 2026-09.5vbh — xtool builds with the compiling toolchain's clang headers

Status: Accepted (2026-09-25)

**Context:** the first `xtool dev build`, on 2026-09-25, failed in clang's module scan of the Xcode 27 SDK with
`module '_c_standard_library_obsolete' requires feature 'found_incompatible_headers__check_search_paths'`.
xtool 1.20.1's SDK bundle carries clang 21 builtin headers that are older than Swift 6.4's own clang 21:
243 files against 253, without `ptrcheck.h` or `__float_float.h`. Its `float.h` still does
`#include_next <float.h>` on Apple platforms, which reaches the SDK's `float.h`, a header Xcode 27 fences off
to catch broken search paths. xtool 1.20.1 is the latest release, and no xtool issue covers this.

**Decision:** `scripts/xtool-sdk-fixup.sh` repoints the bundle's `usr/lib/swift/clang` at a directory whose
`include/` is the compiling toolchain's clang headers, keeping the bundle's compiler-rt `lib/`. The compiler
and its builtin headers then match, which is what clang assumes. The script is idempotent and has
`--check` and `--undo`. Patching `float.h` alone was the narrower fix, but it would leave every other header
skewed. Waiting for an xtool release would block every iOS build until then.

**Consequences / limits:** `xtool sdk install` rebuilds the bundle and drops the fix, so rerun the script after
it. A future xtool that ships matching headers makes the script unnecessary, and `--undo` restores the
original link. `scripts/check.sh ios` runs `--check` before building and fails with the fix command. The
issue is worth reporting upstream to xtool, and has not been filed yet.
