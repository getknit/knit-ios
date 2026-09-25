<!--
Thanks for contributing to Knit for iOS. Keep each merge request to one change.
Submitting means your contribution is licensed under GPL-3.0-or-later with the App Store exception
(APP-STORE-EXCEPTION.md), and every commit carries a DCO sign-off (`git commit -s`).
-->

## What and why

<!-- What changes, and why. Link the issue it closes (Closes #NN). -->

## How it was tested

- [ ] `scripts/check.sh fast` (format, lint, build, unit tests)
- [ ] `scripts/check.sh all` when the change touches `KnitWire`, `KnitCrypto` or `KnitMesh`
- [ ] Checked against knit-next over the air (`knit-peer` or a phone), if it changes what goes on the wire

## Checklist

- [ ] Every commit is signed off under the [DCO](DCO); `CONTRIBUTING.md` explains how
- [ ] Licensed under GPL-3.0-or-later with the App Store exception
- [ ] No new shipped dependency, or `THIRD-PARTY-NOTICES.md` names it with a GPL-compatible license
- [ ] Wire, custody and crypto changes match knit-next and say so (`.agents/rules/interop.md`)
- [ ] New user-facing text went through the product-language-editor and humanizer skills
