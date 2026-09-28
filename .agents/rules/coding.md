# Coding

Standing rules for all Swift in this repo. Interop rules for wire, crypto and mesh code are in `interop.md`.

## Style

- **swift-format owns layout:** 4 spaces, 140 columns, K&R braces (`.swift-format`). Run `swift format -i`
  on what you touched; never hand-align.
- **Every SwiftLint opt-in rule is on,** and CI runs `--strict`. Disable a rule on one line with
  `// swiftlint:disable:next <rule>` and a reason, never file-wide. A rule that is wrong for the whole repo
  leaves `.swiftlint.yml` with its reason written beside it.
- **Top-level declarations say their access level** (`public`, `internal`, `private`). Public API has a doc
  comment.
- **Match the surrounding code.** Comments explain why, and cite the knit-next file or ADR a rule comes
  from.

## Swift

- **Warnings are errors.** Fix the cause. A `@preconcurrency` import or a `nonisolated(unsafe)` needs a
  comment saying why it is safe.
- **Strict concurrency.** Shared mutable state lives in an actor, or behind `KnitSync`'s `Lock`, never a
  `Synchronization.Mutex`, whose futex TSan cannot see on Linux (ADR 2026-09.ahrr). A global holds only
  `Sendable` values; build a non-`Sendable` value (a `CBUUID`) where it is used.
- **Strict memory safety** is on in the platform-free targets. An `unsafe` expression is kept small and says
  what makes it sound.
- **`try!`, force unwraps and implicitly unwrapped optionals are banned.** Use `guard` and `#require`.
- **Errors are typed where a caller branches on them.** A parser throws a specific error; it never traps
  on hostile input.

## Architecture

- **Respect the seams in `.agents/context/architecture.md`.** One target imports each framework, and
  everything above the radio talks to `MeshTransport`.
- **The protocol targets take time and randomness as dependencies:** a wall clock, a monotonic clock and a
  `RandomNumberGenerator`. `Date()`, `Task.sleep`, `UUID()` and `.random(` are banned there.
- **No `print`.** Log through `KnitLog`.
- **Apple-only code goes behind `#if canImport(…)`,** and iOS-only calls (UIKit, `identifierForVendor`,
  restoration keys) behind `#if os(iOS)`, so the package builds on Linux and on macOS.

## Tests

- **Swift Testing** (`@Test`, `#expect`, `#require`), one test target per module.
- **A new platform-free target** gets a floor in `scripts/coverage-floors.json` the day it gains
  executable lines.
