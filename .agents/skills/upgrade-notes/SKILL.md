---
name: upgrade-notes
description: Read the vendor's breaking changes, deprecations, migration notes and CVEs for every version between the one pinned now and the one being moved to, through the `whatsnew` MCP server's `upgrade_notes` tool. Use WHENEVER any dependency or tool version changes in this repository (a package in `Package.swift` or `Package.resolved`, the Swift toolchain in `.swift-version`, SwiftLint, Periphery, XcodeGen, or a CI image in `.gitlab-ci.yml`), and whenever asked "is it safe to upgrade X" or "what changed in X since Y". Run it BEFORE editing the version, not after the build breaks.
---

# Upgrade notes

Every version change here gets the vendor's own notes read first. The `whatsnew` MCP server
(`https://whatsnew.fyi/mcp`, declared in `.mcp.json`, no auth) returns every tracked release between two
versions with the breaking, deprecation, migration and security sections verbatim, including breaking
changes shipped in a minor or a patch.

This skill says what to read before a bump. `.agents/context/toolchain.md` and
`.agents/rules/build-and-test.md` still decide whether and how the bump lands. Read both.

## When the tool is missing

If no `whatsnew` tools are loaded, the server is not approved in this session. Tell the user once
(Claude Code: `/mcp`, approve `whatsnew`), then read the vendor's release notes directly. The skill is
advisory; never block a bump on it.

## Steps

1. **List what is moving.** Take `from` from what is pinned now (`Package.resolved` for packages,
   `.swift-version` for Swift, the variables at the top of `.gitlab-ci.yml` for SwiftLint and the images,
   `.agents/context/toolchain.md` for Periphery and XcodeGen) and `to` from the target. Exact versions, never
   ranges.
2. **Call `upgrade_notes`**, up to 20 dependencies per call. Give `name` as the package or tool name, and
   `repository` as its GitHub `owner/repo` whenever it has one; without it a match is often `untracked`.
   The repositories this repo pins: `apple/swift-crypto`, `apple/swift-asn1`, `groue/GRDB.swift`,
   `realm/SwiftLint`, `peripheryapp/periphery`, `yonaskolb/XcodeGen`, `swiftlang/swift` (the toolchain and
   swift-format), `aquasecurity/trivy`.
3. **Check `match` before reading anything.** `match.slug` must be the product you meant; discard a result
   matched to some other product.
4. **Read each result.** For `status: ok`, start with `signals` (major bump, breaking mentions, CVEs), then
   each release's breaking, security, deprecated and migration sections. For `untracked`, `unversioned` or
   notes that stop short of the target, read the vendor's notes yourself and say so.
5. **Act on it.** Apply the migrations the notes call for in the same change as the bump, regenerate
   `Package.resolved`, update the `THIRD-PARTY-NOTICES.md` row, and run `scripts/check.sh all`. Tell the
   user, per dependency, the breaking items that touch this repo, the CVEs fixed, and anything left
   unchecked.
