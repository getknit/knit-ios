# Contributing to Knit for iOS

Thanks for your interest. Knit for iOS is the iPhone port of Knit, an offline mesh messenger, and
contributions are welcome within the expectations below.

## Support expectations

Knit for iOS is released as-is under the [GNU GPL v3.0-or-later](COPYING), with the
[App Store exception](APP-STORE-EXCEPTION.md). It is developed on a best-effort, hobby basis, with no
support, warranty or response-time guarantee. That is the GPL's "no warranty" clause, stated plainly:

- Issues and merge requests are welcome, but they may not be triaged, answered or accepted.
- There is no commitment to fix bugs or review contributions on any timeline.
- Don't depend on Knit where failure matters. It is experimental software driving radios.

## Ground rules

- **Follow the [Code of Conduct](CODE_OF_CONDUCT.md).** Harassment and abuse are not welcome in issues,
  merge requests or discussions.
- **License.** By contributing, you agree that your contribution is licensed under GPL-3.0-or-later
  together with the App Store exception, the same terms as the project. Contribute only code you have the
  right to license that way.
- **Sign your commits under the DCO.** Add a `Signed-off-by: Your Name <you@example.com>` trailer to each
  commit (`git commit -s`), certifying the [Developer Certificate of Origin](DCO), version 1.1. The
  trailer's email must match the commit's author or committer. `git config core.hooksPath .githooks`
  turns on a hook that adds it for you.
- **Dependencies.** Anything the app ships must be under a GPL-compatible license (Apache, BSD, MIT or
  similar), and gets a row in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). A test fails until
  every package in `Package.resolved` has one.

## Development

[`AGENTS.md`](AGENTS.md) is the starting point for build and test commands, the toolchain, the
architecture and the rules that keep an iPhone compatible with Knit for Android. In short:

- **Swift 6.4** (`.swift-version`). On Linux, also `libdbus-1-dev` and `pkg-config`.
- **`scripts/check.sh fast`** runs format, lint, the build and the unit tests. **`scripts/check.sh all`**
  adds coverage, the thread and address sanitizers, analysis and the documentation linters.
- **`xtool dev build`** builds the iOS app on Linux, once `scripts/xtool-sdk-fixup.sh` has repaired the
  Darwin SDK.
- **Anything that changes what goes on the air** must match Knit for Android byte for byte
  ([`.agents/rules/interop.md`](.agents/rules/interop.md)).

`git config core.hooksPath .githooks` turns on the repo's hooks:

- `prepare-commit-msg` adds the DCO sign-off;
- `commit-msg` strips agent session-link trailers;
- `pre-commit` lints staged Swift files and checks the ADR router;
- `pre-push` runs `scripts/check.sh fast`.

That setting replaces `.git/hooks` entirely, and `--no-verify` skips the hooks for one command.

## Where to submit

Development happens at `source.jeffmixon.com/knit/knit-ios`; a public mirror will follow. Keep each merge
request to one change, with a clear description of what changed and why. The template asks for the rest.
CI checks every commit's DCO sign-off. If it fails, `git rebase --signoff <target branch>` and a force-push
fix the whole branch at once.

## Security

Don't report security vulnerabilities in public issues or merge requests. [`SECURITY.md`](SECURITY.md)
explains how to report them privately.
