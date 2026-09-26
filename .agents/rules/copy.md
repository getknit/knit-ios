# Copy

Rules for any text a person reads.

- **User-facing text goes through the `product-language-editor` skill, then the `humanizer` skill.** That
  covers UI strings, Info.plist usage descriptions, notifications, README, CONTRIBUTING, SECURITY, the
  CHANGELOG, store listings and help text.
- **Other prose goes through `humanizer`:** ADR bodies, `.agents/` files, docs, and merge request
  descriptions.
- **Legal text goes through neither:** `COPYING`, `DCO`, `APP-STORE-EXCEPTION.md`. It changes only on
  purpose, with a lawyer's read for the exception.
- **Scope every security claim to what it covers.** Direct messages are end-to-end encrypted. The Nearby
  room is open to everyone in range. v1 DMs have no forward secrecy yet.
- **Name the boundary once, and plainly.** The iPhone finds new people while Knit is open; open links keep
  working in the background.
- **UI strings live in one catalog** (`Copy`, in `Sources/KnitAppCore/Copy/`), never inline in a view (ADR
  2026-09.ycza). Android's `strings.xml` is the starting point, adapted to what the iPhone does: Bluetooth
  only, no Wi-Fi Aware. `App/Info.plist`'s usage strings keep a copy that `CopyTests` holds equal.
- **Use `NSLocalizedString(_:bundle:value:comment:)`, not `String(localized:)`.** Linux Foundation has no
  `LocalizationValue` (checked against the Swift 6.4 toolchain), so `KnitAppCore` would stop building on
  Linux. Xcode extracts `NSLocalizedString` calls into a String Catalog just the same.
