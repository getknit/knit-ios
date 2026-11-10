---
id: "2026-11.w5ew"
slug: a-web-address-in-a
title: "A web address in a message opens on a tap"
date: 2026-11-09
topics: [messages, ui, interop]
---

# ADR 2026-11.w5ew — A web address in a message opens on a tap

Status: Accepted (2026-11-09)

**Context:** on 2026-11-09 an iPhone tester reported that a URL in a chat could not be tapped. On the iPhone a web
address in a bubble was plain text, with no tint, no underline and nothing on a tap. The bubble's words came from
`MentionHighlight`, which built an `AttributedString` from the body and set only the mentions apart (ADR 2026-10.nbhj).
SwiftUI's `Text` finds no links by itself.

Knit for Android has made them links since knit-next `057c70b8e` (2026-06-27), well inside the pin `cad69c77b`:

- `findUrls` (`MentionText.kt:270-288`) matches `(?i)(?:https?://|www\.)[^\s<>]+`. `trimTrailing` takes sentence
  punctuation (`.,;:!?"'` and the closing quotes ” ’ ») off the end, with any closing bracket the address does not
  open. A `www.` address opens as `https://`, and its drawn range stays as written.
- `annotateMessageBody` adds a `LinkAnnotation.Url` per address, underlined in `accentText`, the same color as a
  mention. A tap calls `openUrl`, an `ACTION_VIEW` intent with no confirmation.
- An email address, a `geo:` position and a `knit://` link are not links. A position's card opens the position.

Nothing in the roadmap or an ADR had deferred this: the port missed it. `AttachmentView` already leaves Android's
link card out of a thread, because "the link in the text" shows the same, which wasn't true here until now.

**Decision:** a web address in a bubble's words is a link, found by Android's rule and opened on a tap.

- **The rule.** `LinkText.links(in:)` in `KnitAppCore` ports `findUrls` and `trimTrailing` as a scan over UTF-16
  units, so a link covers the same units as on Android. Each match starts where the last one's run ended, before the
  trim, as Kotlin's `findAll` resumes, and each kind of bracket counts on its own.
- **Whitespace is ART's.** On a phone `java.util.regex` is ICU, and `\s` is Unicode White_Space (ADR 2026-10.7uyt), so
  a no-break space or U+0085 ends an address. knit-next's own `MentionTextTest` runs on the desktop JDK, where `\s` is
  ASCII, so it can't show this. `TextLimits.isJavaRegexWhitespace` is public now so the rule reads the same pinned
  list.
- **The thread.** `ChatModel` stores the links on `ChatMessage.links`, next to `mentionSpans`, once per refresh.
  `MessageLink.target` is `URL(string:)`, which percent-encodes a non-ASCII path. An address Foundation can't read
  stays words.
- **The bubble.** `BubbleText` (formerly `MentionHighlight`) sets `.link`, an underline and the mention's color:
  `Palette.mention` on someone else's bubble and `Palette.onOwnBubble` on ours, as Android uses `accentText` for both.
  SwiftUI draws a link in the tint, which on our coral bubble would vanish, so the `Text` takes that color as its tint.
- **A tap.** It goes through the environment's `openURL`. `KnitApp` sets an `OpenURLAction` that gives a contact link
  (`AddContactModel.isContactLink`) to `Launch.open(url:)`, the path a universal link from Messages takes, and returns
  `.handled`, so Add contact opens without leaving Knit. Android's intent reaches its own app link the same way.
  Every other address gets `.systemAction`, and iOS opens it where it sends that address. Like Android, Knit doesn't
  ask before opening.
- **VoiceOver.** The row is one element (`.accessibilityElement(children: .combine)`), which keeps VoiceOver from the
  links inside it. So while the words show, each link is an action of the row, `Copy.Chat.openLink`: "Open" and the
  address as the sender wrote it, which tells two links in one message apart.

The obvious alternative was `NSDataDetector`, or `UITextView`'s data detectors. They find more than Android does:
bare domains, phone numbers, addresses and dates. Two phones would then disagree about which words in one message
are links, and the rule couldn't be tested on Linux.

**Consequences / limits:**

- **Opening a link leaves Knit for the web.** The browser, or the app iOS hands the address to, contacts the site.
  Knit itself fetches nothing: link previews stay out of scope. (Amended 2026-11-10: a debug build is getting
  Android's link previews, fetched by the sender with a setting that is off by default; ADR 2026-11.hcvg.)
- **Not links, as on Android:** an email address, a phone number, a bare domain without `www.`, `geo:`, `knit://` and
  `mailto:`. Words the content filter hides show no link until they are shown, and a reply's quote stays plain.
- **Where this may differ from Android:** ICU's case folding takes a few letters besides ASCII, such as U+017F for
  "s". A crafted address spelled with one is a link there and words here, and so is an address Foundation can't
  parse.
- **Not built:** a long-press menu for a link (the bubble's menu keeps the long press), and the sender's formatting
  ranges (knit-next ADR 2026-10.p95v), which this bubble still doesn't draw.
- **Owed on the iPhone:** a tap opens Safari, a contact link opens Add contact, a long press on a link still opens the
  bubble's menu, VoiceOver offers Open, and the link reads in both bubbles in light and dark. The Linux tests can't
  show any of these.
- **The traps:**
  - Reaching for data detectors, or Swift's `isWhitespace`, which drifts from ART's list.
  - Setting only `foregroundColor` on the link run: SwiftUI draws the link in the tint, and on our own bubble the tint
    is the bubble's own coral.
  - Routing every URL through Knit: only a contact link stays in the app.
- **The guards:**
  - `LinkTextTests`, every `findUrls` case of `MentionTextTest.kt` plus ART's whitespace, angle brackets, each bracket
    kind and UTF-16 offsets;
  - `MentionTests.aMessageShowsWhereItsLinksSit`, a thread's links beside its mentions;
  - `CopyCatalogTests+Links`;
  - `SwatchContrastTests`' mention pair, which the link color reuses.
