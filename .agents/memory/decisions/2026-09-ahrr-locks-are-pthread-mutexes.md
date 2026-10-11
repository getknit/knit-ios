---
id: "2026-09.ahrr"
slug: locks-are-pthread-mutexes
title: "Locks are pthread mutexes, so TSan can see them"
date: 2026-09-28
topics: [concurrency, testing, tooling]
---

# ADR 2026-09.ahrr — Locks are pthread mutexes, so TSan can see them

Status: Accepted (2026-09-28)

**Context:** shared state sat behind `Synchronization.Mutex`, as `coding.md` asked. On Linux, `Mutex` waits on
a futex, and ThreadSanitizer sees only the pthread calls it intercepts. It reported races between two
`withLock` bodies that the lock kept apart. The flake was known on 2026-09-26 and deferred on the roadmap. A
pipeline on 2026-09-28 then failed `test:tsan` twice in a row: once in `KnitBlueZ`'s `Mailbox`, and on the
retry in `MemoryCustodyStore`. `CustodyStoreTests.concurrentStoresAndSweepsLeaveAConsistentSet` alone failed
13 of 15 runs under TSan. A gate that fails at random gets rerun until it passes, and then it proves nothing.

**Decision:** a `KnitSync` target holds one type, `Lock<Value>`. It has `Mutex`'s API, `init(_:)` and
`withLock`, with the same `sending` rules, over a heap-allocated `pthread_mutex_t`. Every `Mutex` in `Sources/`
and `Tests/` became a `Lock`, and SwiftLint's `no_mutex` rule bans `Mutex` outside `KnitSync`. The same test
then passed 20 of 20 runs under TSan. Two other fixes were considered and rejected:

- **A TSan suppression for `Mutex`** would hide real races inside the same bodies.
- **Annotating `Mutex` with `__tsan_acquire` and `__tsan_release`** needs a C shim built only for sanitizer
  runs, and the annotations would have to wrap every call site.

**Consequences / limits:**

- **Cost:** `Lock` is a class, so each one costs an allocation, which `Mutex` as a struct avoided. Nothing here
  takes a lock often enough for that to show.
- **Atomics stay:** `Atomic` stays where it is, in `KnitBLE`, since TSan understands atomics.
- **What `Lock` does not cover:** a lock cannot fix a real race, and TSan still reports those.
- **The guards:** the `no_mutex` rule, `KnitSyncTests` under every gate TSan included, and `test:tsan`, which
  can now block without reruns.
