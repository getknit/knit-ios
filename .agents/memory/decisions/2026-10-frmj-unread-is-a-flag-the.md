---
id: "2026-10.frmj"
slug: unread-is-a-flag-the
title: "Unread is a flag the store sets as a message arrives"
date: 2026-10-14
topics: [messages, store, ui, notifications]
---

# ADR 2026-10.frmj — Unread is a flag the store sets as a message arrives

Status: Accepted (2026-10-14)

**Context:** the roadmap listed unread counts as still owed. Knit for Android at the pin `5f521cb9` keeps one
watermark per thread, `last_read_<conversationId>`, in its settings (`SettingsStore.kt:71`, `:559`). The watermark is
the `sentAt` of the thread's newest row, written while the thread is on screen with the app in front
(`ChatViewModel.kt:719-730`) and by a notification's Mark read (`NotificationActionReceiver.kt:126`).
`MessageDao.countUnreadIn` (`:511-520`) counts what is newer: ordinary messages, not ours, from nobody blocked. It
runs once for each row the list draws (`ChatListViewModel.withUnread`, `:335-345`), so a request never counts. Each
row shows its count in a badge with no cap, which TalkBack reads as "%d unread message(s)" (`strings.xml:536-539`).
Read state never leaves the phone: there is no read receipt. knit-next's ADR 2026-09.z58t turned down a Room table
for it.

The watermark compares the author's clock. Store and forward hands over a message long after it was written: a DM a
carrier held for hours, or a group message the start-up replay delivers. Any message dated before the last read never
counts on Android, and neither does one from a phone whose clock runs behind.

**Decision:** a flag on each message, which the store sets once.

- **The store:** schema v15 adds `messages.unread INTEGER NOT NULL DEFAULT 0`, with the partial index
  `messages_unread (conversationId) WHERE unread = 1`, and `MemoryMessageStore` keeps the same flag on each row. A
  row is unread from the moment it is first stored if it is someone else's ordinary message
  (`MessageRecord.arrivesUnread`). That means it is `kind` 0 and has an `arrivedAt`, which our own messages and
  status lines don't. No save changes the flag: the SQL upsert leaves it out of `DO UPDATE SET`, and the memory store
  keeps it on an upsert. Only `markRead(in:)` clears it. `unreadCounts(excludingSenders:)` answers every thread's
  count in one `GROUP BY`, keyed by the thread id's bytes (ADR 2026-09.jc2x). Every row held before v15 reads as
  read, so an update shows no counts.
- **What counts:** someone else's ordinary messages, photos included. Flagged ones count too, since Android's count
  has no moderation term. Ours never count, nor do status lines, kinds this build doesn't know, or reactions. A blocked
  sender's messages are left out when the counts are read, so an unblock brings them back as unread as they were, as
  on Android. A deleted message takes its flag with it.
- **Where it shows:**
  - Every row the list draws carries `ChatRow.unreadCount`, read through `ThreadTable.unreadCount`: the room, the
    accepted DMs and the listed groups.
  - A request counts nowhere until it is accepted or verified, because Android draws no row for one. Accepting a
    request without opening it shows everything it holds.
  - The count is a `CountPill` at the end of the preview line, the same pill the requests entry draws, with no cap,
    as on Android. VoiceOver reads it in words (`Copy.ChatList.unreadCount`, Android's `chat_list_unread_count`).
- **When a thread is read:** whenever it is on screen with Knit in front, whatever the scroll position, as on Android.
  That covers `AppSession.show`, a message landing in it (`handle(.received)`), and `setActive(true)` while it is still
  on screen, which is Android's `ON_RESUME`. A read moves `revision` only when it changed a row, so a thread's redraw
  never reads it again.
- **Knit's icon, which Android doesn't have:**
  - The icon shows the total of the DMs' and groups' counts (`ChatListAssembler.badgeTotal`), walking the rows the
    list draws so the two cannot drift.
  - Nearby's count stays on its row: meeting a peer can back-fill up to 200 room posts.
  - `AppSession.syncBadge` sets the icon through `Notifier.setBadge` when the total changes. It runs wherever a count,
    or the set of threads the list shows, can move. It also runs at launch, which corrects an icon an earlier run left
    stale.
  - `setBadge` never suspends (`setBadgeCount(_:withCompletionHandler:)`), so two totals land in the order the session
    asked for them.
  - The app already asks for `.badge`. A message only arrives while Knit runs, so the icon is right whenever it can
    change.

The alternatives, and why each lost:

- **Android's watermark** loses the late message.
- **A watermark of our own clock** (`arrivedAt`) keeps the late message, but it needs a strict arrival order, and
  there isn't one. The wall clock can step back, and two arrivals can share a millisecond. `seq` has no
  `AUTOINCREMENT`, so SQLite hands a deleted newest row's number to the next row.
- **A watermark kept beside the database,** as Android keeps it in DataStore, is one more file to keep in step with
  deletes and blocks.

The flag costs one write each time a thread is read.

**Consequences / limits:**

- **Cost:** one column and a partial index. A read is one `UPDATE` through the index, and a redraw of the list adds
  one `GROUP BY` over the unread rows only.
- **Where it differs from Android:**
  - A late message counts here and not there.
  - The icon has a count.
  - A reinstall's custody back-fill arrives unread on both.
- **Not built:**
  - Android's notification Mark read, which would launch Knit in the background through `Launch`, the restoration
    path.
  - A swipe to mark a thread read or unread.
  - A "New messages" line in the thread.
  - Read receipts, which Android doesn't have either.
- **A downgrade:** a build before v15 stores new rows with `unread` at 0. What arrives while it runs reads as read once
  a newer build is back.
- **The traps:**
  - Naming `unread` in the upsert's update or in `SQLMessageStore.columns`. A re-save would then clear the flag or set
    it again, and `threadHeads` reads `columns`.
  - Binding the 1 in `unread = 1`. SQLite then skips the partial index.
  - Counting in Swift from `messages(in:)`.
  - Adding Nearby to the icon.
  - Reading a thread on screen without checking that Knit is in front.
- **The guards:**
  - `MessageUnreadTests`, over both stores, with the late message in `aLateMessageCountsWhateverItsSentAt`.
  - `SchemaTests`' v15 pin, `v15StartsEveryHeldMessageRead`, and `theUnreadQueriesUseThePartialIndex`, which plans
    the store's own SQL.
  - `UnreadTests` in KnitAppCore: the list, reading, the icon and the demo scenes. `CopyCatalogTests+Unread`.
  - `KnitUITests`' `testAnUnreadRowSaysHowManyAndOpeningItClearsIt`. Its `walkUnread` runs in every walk, so the
    largest text size and dark mode audit the long room's count in the hundreds.
