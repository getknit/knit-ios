---
id: "2026-09.d3jv"
slug: the-darwin-sdk-stays-on
title: "the Darwin SDK stays on this machine"
date: 2026-09-25
topics: [ci, toolchain, legal]
---

# ADR 2026-09.d3jv — the Darwin SDK stays on this machine

Status: Accepted (2026-09-25)

**Context:** xtool builds iOS apps on Linux against a Darwin SDK extracted from `Xcode.xip`. Apple's Xcode and
SDK agreement ties that SDK to Apple-branded computers. CI jobs cache directories and upload artifacts,
and either could carry the SDK somewhere it should not go.

**Decision:** the SDK lives only in `~/.swiftpm/swift-sdks` on the maintainer's machine. `build:ios` runs on the
`knit-local` shell runner there, and uploads `xtool/Knit.app` and nothing else. No image or cache includes
the SDK. iOS builds move to the Mac Mini when it arrives, and xtool becomes a fallback.

**Consequences / limits:** a fork, or any runner but this one, cannot run `build:ios` without its own Mac. An iOS
build break is caught only when that runner is up. The job's `tags: [knit-local]` and its explicit artifact
path in `.gitlab-ci.yml` are the check.
