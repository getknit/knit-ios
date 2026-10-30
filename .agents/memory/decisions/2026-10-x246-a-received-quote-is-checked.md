---
id: "2026-10.x246"
slug: a-received-quote-is-checked
title: "A received quote is checked against the original it names"
date: 2026-10-30
topics: [messages, moderation, interop, ui]
---

# ADR 2026-10.x246 — A received quote is checked against the original it names

Status: Accepted (2026-10-30)

**Context:** a quoted reply carries its sender's claim about what it quotes: `ReplyRef { messageId, authorId, author,
snippet, hasAttachment }`. Under ADR 2026-10.mn29 the iPhone stored that claim as sent, clipped to 256 UTF-16 units, and
checked nothing. A thread drew the sender's `author` string for any id it had not pinned. So any peer could put words in
anyone's mouth, under any name, and a quote naming the reader's own id read "You". The words were screened, but as one
verdict with the reply's body on the `moderation` column, so a quote of a flagged original showed whenever the replier
typed clean words over it.

Android closed the same hole in knit-next ADR 2026-10.gpa3 (`1870384c`, 2026-10-13, an ancestor of the pin `e63f15f4`).
This port had followed `1870384c` only for its mention alert. Two facts from gpa3 bound the fix here too. A frame id is
random and bound to no author, so an id that resolves proves nothing until the author and the thread match. And an
original routinely lands after its reply: custody serves newest first, and a parked or replayed frame lands late.

**Decision:** the iPhone judges every inbound quote against the original it holds, rule for rule as Android's Kotlin at
`7439fd9cc` does, and names the author by its own label. Nothing on the wire moves, and Android needs no change.

- **Admission** (`MeshEngine.reply(_:)`, `InboundPipeline.admitReply`). A quote whose `messageId` or `authorId` is blank
  or longer than 64 UTF-16 units is dropped, and the reply is kept quoting nothing. `author` goes to one line and 32
  units, and is kept as a record only. `snippet` goes to one line and 120 units.
- **The verdict** (`MessageReply.verdict(of:against:)`, `quoteVerdict`). A reply that isn't ours, whose original this
  phone holds under the quoted id, is verified when the original sits in the reply's thread, its sender is the quote's
  `authorId`, it is somebody's words, and it is not the reply itself. Ids and threads compare by their bytes (ADR
  2026-09.jc2x). Anything else that answers to the id is a mismatch, and a reply whose original isn't held stays
  unchecked. Somebody's words here means an ordinary message: a status line is not, since its sender column names whom
  the event is about (`MessageKind.isNotice`). Android also leaves out a heard Meshtastic post, whose sender column is the
  phone by convention; this port writes no such row, so it has nothing else to leave out.
- **The settlement** (`MessageReply.settlement`, `settleQuote`). A verified quote is rebuilt from the original by the
  composer's own rule, `MessageReply.quoting` with nothing hidden, so the composer and the receiver can't drift. Its
  labels for a GIF, a file or a voice note are the app's (`MeshConfiguration.quoteLabel`, the composer's
  `AttachmentKind.quoteLabel`). A mismatch keeps nothing of the claim: no words, no attachment, nothing flagged. Our own
  replies are never judged or rewritten.
- **The store, schema v20.** `messages` gains Android's two local columns under Android's names. `replyCheck` holds
  Android's `REPLY_UNCHECKED` 0, `REPLY_VERIFIED` 1 and `REPLY_MISMATCH` 2 (`QuoteCheck`). `replyToFlagged` holds the
  filter's verdict on the quote's words apart from the body's, in `MessageModeration`'s codes. Old rows start unchecked
  and clear. `settleQuote` writes the quote's columns once, only while the row is unchecked, and touches nothing else, as
  `MessageDao.applyQuoteVerdict` does: a whole-row `save` would undo a tick or a verdict written in between. Two partial
  indexes serve the replies waiting on an original and the quotes still to screen.
- **When it runs** (`MeshEngine+Quotes`, `QuoteVerifier`). On a first delivery, before the insert, when the original is
  already held: `storeDelivered` reads the message store and nothing else, so it may run inside a ratchet open's unit.
  After the commit, in `announce`: the row is judged if its original landed since, and every reply waiting on it is
  settled, in batches of 200. Whichever of a reply and its original lands second settles the pair. Once per start, after
  our profile's seed, the backlog: replies held from before v20, or whose settle a stop cut short, 200 a batch, each
  batch one store unit as Kotlin's is one transaction, and at most 50 batches.
- **Moderation.** An unchecked quote's words are screened by the app as a body is, in the same scope, on
  `replyToFlagged` (`AppSession.screen`, `setQuoteModeration`), and a flagged one hides the reply. Android screens them
  before its insert in `quoteOnArrival`. A verified quote carries its original's own verdict on its words, never one the
  original inherited from a quote of its own, so a reply to a reply hidden only for its quote is not hidden.
  - **The choice this port had to make:** Android classifies before it stores, so an original's verdict is final by
    the time any reply settles against it. Here the app screens after the engine stores, so the original's verdict
    can still be waiting. The quote then stores waiting too, and hides as unscreened words do. The store passes the
    original's verdict on when the original is screened, in the same write as the original's own (`setModeration`).
    A settle reads the original's verdict in the statement that writes it, and a reply judged before its insert reads
    it again once committed (`refreshQuoteModeration`). So a screen that lands between the judging and the write is
    never lost. The outcome is Android's: a verified quote is hidden exactly when its original is flagged, and its
    words never show while the original's screen waits.
  - **The alternative** was to screen the rebuilt words as their own. That costs an inference per reply and can
    disagree with the original's verdict, which a tap on the original already shows. It would also break
    non-transitivity whenever the scopes differ.
  - **One hide predicate:** `MessageRecord.hidesWords` reads both verdicts, so the thread, the chat list, a notification
    and the composer's quote follow it. A reply hidden for its quote hides whole behind one tap, quote included, as
    mn29's did.
- **What the reader sees** (`QuoteState`, `ChatQuote`, `quoteViewFor`). The author is the reader's own label for the
  quoted id: "You" for ours, else `Directory.labels`, a contact's name or the alias. It is never `ReplyRef.author`.
  - **Verified:** ours, or a verified quote. It draws as before, and only it jumps, within the thread.
  - **Unverified:** an unchecked quote of somebody else's id. It shows the sender's words, with "Unverified — original
    not on this phone" under them.
  - **Unavailable:** a mismatch, or an unchecked quote of our own id, since this phone holds everything it sent. It
    shows "Quoted message unavailable", with no author and no words, and a report of the reply names no quote.
- **The control surface.** `room`, `dm` and `group-send` refuse a `replyTo` held in another thread, which Android would
  read as unavailable; its own bridge refuses one too. A message line's `replyTo` reports `check` and `moderation`, as
  Android's bridge reports `replyCheck` and `replyToFlagged`.

**Consequences / limits:**

- **An id squatter still wins first-write,** as on Android: whoever stores a frame under an id first owns it here. A
  reply quoting the real original then reads unavailable, which fails safe. The real fix binds a frame id to its author,
  and that is a wire break parked in knit-next's `docs/NEXT_WIRE_BREAK.md`.
- **An unverified quote shows our trusted label beside the sender's words.** The cue under them is what keeps it from
  reading as genuine.
- **What stays as it was:** a reply stored before v20 whose original is absent keeps the one verdict mn29 gave its body
  and quote together, so one hidden only for its quote stays hidden. A verified reply whose original is deleted while its
  screen still waits stays hidden as unscreened. Both fail safe.
- **A GIF's label** depends on the photo's frames, read once its bytes land. A quote rebuilt before then reads as a
  photo, as Android's `attachmentAnimated` does.
- **Not covered:** stripping bidi controls from a snippet, which Android doesn't do either, and received mention names
  (knit-next #247, knit-ios #36).
- **The trap:** writing a settlement with `save`, which overwrites the moderation and the reply columns; or screening
  the rebuilt words, which breaks the non-transitive verdict. Another is letting the snippet's screen overwrite a
  settled quote: `setQuoteModeration` writes only while the quote is unchecked and waiting.
- **The guards:**
  - `MessageReplyTests+Quotes`: the verdict matrix (author, thread, a status line, itself, an id by its bytes), the
    settlement and its labels, non-transitivity, and, against both stores, the once-only settle that leaves the row
    alone, the original's verdict reaching its replies in either order, the quote's own screen, and both queries.
  - `MeshEngineQuoteCheckTests`: a forged snippet over a held original rebuilt, a reply ahead of its original settling,
    a wrong author or thread, a screen between the judging and the insert, our own replies untouched, a file's label,
    and the backlog with its bound. `MeshEngineReplyTests`: admission's clips and dropped ids, and a quote's words
    waiting apart from the body's.
  - `ReplyTests`: the reader's label, never the sender's string, for an unknown id too; our id with no original
    unavailable; the three states, their lines, jumps and VoiceOver label; a flagged unverified quote hiding its reply
    and the original's landing recomputing it; a flagged original hiding its verified reply and not the reply to it.
  - `SchemaTests`: the v20 pin, `v20StartsEveryHeldReplyUncheckedAndUnflagged`, and the two indexes' query plans.
  - `MeshControlReplyTests`: a cross-thread `replyTo` refused, and the line's `check`.
