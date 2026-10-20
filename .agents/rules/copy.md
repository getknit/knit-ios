# Copy

Rules for any text a person reads.

- **User-facing text goes through the `product-language-editor` skill, then the `humanizer` skill.** That
  covers UI strings, Info.plist usage descriptions, notifications, README, CONTRIBUTING, SECURITY, the
  CHANGELOG, store listings and help text.
- **Other prose goes through `humanizer`:** ADR bodies, `.agents/` files, docs, and merge request
  descriptions.
- **Legal text goes through neither:** `COPYING`, `DCO`, `APP-STORE-EXCEPTION.md`. It changes only on
  purpose, with a lawyer's read for the exception.
- **Scope every security claim to what it covers.** Direct and group messages are end-to-end encrypted. Between
  phones running the ratchet (this build, and Knit for Android 2.3 and later) they also have forward secrecy, and
  their reactions and delivery ticks are sealed. Toward an older phone, and in a group that includes one, they take
  v1, which has none, and the reactions and ticks go in the clear. So does a DM sent to someone added by link or code
  before their profile arrives (ADR 2026-10.tpr5). A group's name and member list are never
  encrypted, and neither are typing indicators. The Nearby room is open to everyone in range. Forward secrecy
  covers what was recorded off the air, not a phone in someone's hands (ADR 2026-10.5sk9).
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
