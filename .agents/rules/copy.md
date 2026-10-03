# Copy

Rules for any text a person reads.

- **User-facing text goes through the `product-language-editor` skill, then the `humanizer` skill.** That
  covers UI strings, Info.plist usage descriptions, notifications, README, CONTRIBUTING, SECURITY, the
  CHANGELOG, store listings and help text.
- **Other prose goes through `humanizer`:** ADR bodies, `.agents/` files, docs, and merge request
  descriptions.
- **Legal text goes through neither:** `COPYING`, `DCO`, `APP-STORE-EXCEPTION.md`. It changes only on
  purpose, with a lawyer's read for the exception.
- **Scope every security claim to what it covers.** Direct and group messages are end-to-end encrypted. A
  group's name and member list are not, and neither are its delivery ticks. The Nearby room is open to
  everyone in range. v1 DMs and groups have no forward secrecy yet.
- **Name the boundary once, and plainly.** The iPhone finds new people while Knit is open. In the background
  it looks for people only once it has lost its last link, and stops after a few tries that lead nowhere (ADR
  2026-10.mueg). Its links stay up there, but a suspended Knit reads them only when a phone wakes it (ADR
  2026-09.khjj), so say that some phones' messages wait until Knit is next open. Never say open links "keep
  working".
- **UI strings live in one catalog** (`Copy`, in `Sources/KnitAppCore/Copy/`), never inline in a view (ADR
  2026-09.ycza). Android's `strings.xml` is the starting point, adapted to what the iPhone does: Bluetooth
  only, no Wi-Fi Aware. `App/Info.plist`'s usage strings keep a copy that `CopyTests` holds equal.
- **Use `NSLocalizedString(_:bundle:value:comment:)`, not `String(localized:)`.** Linux Foundation has no
  `LocalizationValue` (checked against the Swift 6.4 toolchain), so `KnitAppCore` would stop building on
  Linux. Xcode extracts `NSLocalizedString` calls into a String Catalog just the same.
