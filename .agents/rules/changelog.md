# Changelog prose

Rules for new entries in `CHANGELOG.md`'s `## Unreleased` section, and for App Store release notes cut from
it. Shipped sections are a record of what was published and are never restyled.

- **One bullet is one change, in two sentences of about forty words.** Say what changed, then who notices,
  and stop. A third sentence needs a reason: a caveat the reader must act on, or a limit that would
  otherwise surprise them.
- **Cut the mechanism.** The reader does not need to know what a custody digest is to know their message
  arrives. Name the surfaces they see, not the types behind them.
- **Wrap at 110 columns.**
- **Run the `humanizer` skill before the edit lands.** Two `PreToolUse` hooks then check it:
  - `.claude/hooks/changelog-gate.py` counts words, sentences, columns, emoji, curly quotes and a short list
    of banned words;
  - the prompt hook judges taste, and may block only on a span it quotes verbatim.
- **Categories** follow Keep a Changelog: Added, Changed, Fixed, in that order.
