# Third-party notices

Knit for iOS is free software under the GNU General Public License, version 3 or later, with an App Store
exception ([`COPYING`](COPYING), [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md)). Every component it
ships is under a license compatible with that. `RepoConventionTests` fails when `Package.resolved` gains a
package this file does not account for.

## Shipped in the app

| Package | Project | License |
| --- | --- | --- |
| `grdb.swift` | [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| `swift-crypto` | [apple/swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |

GRDB links the SQLite that ships with iOS and bundles none of its own. On iPhone, swift-crypto hands every
operation to Apple's CryptoKit. Its bundled copies of BoringSSL and XKCP compile only into Linux builds, such as
the `knit-peer` test tool, which is not distributed.

## Resolved but not shipped

SwiftPM resolves these while building the packages above, and none of their code reaches the app.

| Package | Project | License | Why it stays out |
| --- | --- | --- | --- |
| `swift-asn1` | [apple/swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 | Only swift-crypto's `CryptoExtras` uses it, and Knit doesn't link that |

## Build and test tools (not distributed)

| Tool | Project | License |
| --- | --- | --- |
| SwiftLint | [realm/SwiftLint](https://github.com/realm/SwiftLint) | MIT |
| swift-format | [swiftlang/swift-format](https://github.com/swiftlang/swift-format) | Apache-2.0 |
| Periphery | [peripheryapp/periphery](https://github.com/peripheryapp/periphery) | MIT |
| XcodeGen | [yonaskolb/XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT |
| lintorama | [zaventh/lintorama](https://github.com/zaventh/lintorama) | MIT |

## Agent skills in the repository (not distributed)

These are instructions for coding agents, kept under `.agents/skills/` with each license beside it. None of them
reaches the app.

| Skill | Project | License |
| --- | --- | --- |
| `dotagents-standard` | [zaventh/dotagents-standard-skill](https://github.com/zaventh/dotagents-standard-skill) | MIT |
| `humanizer` | [blader/humanizer](https://github.com/blader/humanizer), as ported in [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | MIT |
