---
id: "2026-10.u7cq"
slug: a-delete-removes-messages-from
title: "A delete removes messages from this iPhone and keeps them gone"
date: 2026-10-04
topics: [messages, custody, store, ui]
---

# ADR 2026-10.u7cq — A delete removes messages from this iPhone and keeps them gone

Status: Accepted (2026-10-04)

**Context:** the iPhone could delete nothing (`.agents/memory/roadmap.md` listed it as owed). Knit for Android
deletes locally and sends nothing. A long press deletes one message (`ChatViewModel.deleteMessage`, `:1836-1848`).
Long-pressing a chat-list row deletes a DM's thread, or a group's thread and the group's row without leaving it, or
clears Nearby (`ChatListViewModel.deleteConversation`, `:389-414`, and `0983824b`). The requests inbox has its own
Delete. Custody is never touched. No frame deletes for
everyone; the wire has no such type.

A straight port would not stay deleted. The `messages` row was this port's only lasting dedup record:
`stores.messages.contains` gates `handleChat`, `handleGroupChat`, `deliverChat` and `replayCustodiedGroupChats`.
Remove the row and the message comes back three ways:

- **A group message** comes back at the next launch. Our own custody holds it for 24 hours, and the start-up replay
  delivers what custody holds and the thread lacks, with a notification.
- **A DM** comes back when a carrier that missed our receipt re-serves it, once the 10-minute SeenSet has lapsed or
  the app has restarted. Android is mostly spared by its ratchet, whose spent keys refuse a copy. This port seals DMs
  with v1 (ADR 2026-09.qsd9), so a re-served copy opens like the first.
- **A room post** comes back if it is flooded again.

knit-next's own roadmap names the same gap (`roadmap.md:182-195` there) and has not chosen a fix.

**Decision:** the same deletes in the same places, local and silent, plus two things Android lacks.

- **The deleted ids are remembered.** Schema v8 adds `deleted_messages` (`id`, `expiresAt`, `attachmentHash`), and
  `MemoryMessageStore` keeps the same map. `deleteMessage(_:at:)` and `deleteMessages(in:at:)` record every ordinary message they remove.
  They never record a status line: its id is our own and deterministic (`rejoin:<g>:<m>`), and the next change to the
  group must be able to write it again. `contains` answers true for a remembered id and `insertIfAbsent` refuses one,
  so all four gates hold without being touched. The "already held" branches still acknowledge, so a carrier that
  re-serves a deleted DM still gets the receipt that purges its copy.
- **An id is remembered until no carrier can hold its frame:** the later of `sentAt` and the delete, plus custody's
  24-hour TTL and the five minutes a frame may be dated ahead (`DeletedMessages.expiry`). `MeshEngine.start()` prunes
  what has lapsed before the group replay runs. Counting from the delete covers a carrier whose clock runs behind ours.
- **A delete never changes whether a thread is accepted.** Acceptance is partly read from rows: our own messages, the
  `created:` line and the senders a group's messages came from (`Conversations.isAccepted`). Before rows go, a thread
  that reads as accepted is accepted outright in `accepted_conversations`. The group rule leaves blocked senders out,
  as the screens do. On Android, deleting a DM accepted only because you wrote in it turns their next message into a
  request. That follows from how Android derives acceptance, not from any decision.
- **Custody never reads a deletion.** `MeshEngine+Deletes` writes only the message store, the accepted set and the
  blob store. The router and receipts never see a delete, and nothing is sent. A sent message of ours still reaches
  its recipients from custody. A DM still waiting for a key never goes, because `flushPending` sends from the row.
- **A group keeps us.** Delete chat removes a group's whole thread, status lines included, and leaves the group and
  its roster. The list shows a group only while its thread holds a row (`ThreadTable.listedGroups`). Every held group
  gets its `created:` line at first sighting, so only a deleted one drops out, and its next row brings it back,
  accepted. Android deletes the group's row too and rebuilds it from the next frame (`GroupRepository.kt:174-189`).
  Keeping it here keeps its name and roster, and the screens show the same thing. Group info's Leave group is
  unchanged and is still the way to leave.
- **A photo stays while its frame is carried.** A deleted message's photo leaves the screens at once and stops being
  fetched. Its bytes stay, unshown, while our custody carries the frame it came in on, as Android keeps a carried
  frame's photo (`BlobRepository.deleteIfUnreferenced`, `forward_store.attachmentHash`). A node handed the frame asks
  for the photo, and one of ours, deleted right after it was sent, may have no other holder. `referencedBlobs` names
  them, so the start's sweep keeps them too, and every sweep (`releaseDeletedPhotos`) removes one whose frame has gone.
  That is at most 6 hours for a room post and 24 for a DM or group message, plus one sweep's 10 minutes. A DM sent to us is
  purged from our custody by our own receipt, so its photo goes at once, and so does the photo of a message that never
  left. Without this, the iPhone erased the photo, a neighbour asked for it, and the iPhone fetched it back on the
  neighbour's behalf, to keep until the next start.
- **The screens:** a long press on a bubble opens a menu with Copy and Delete. VoiceOver has Delete among the
  bubble's actions. A status line has neither. The menu replaces the words' own text selection, which a long press
  would otherwise open, so Copy moved into it. The chat list's swipe deletes a DM or a group and clears Nearby, which
  keeps its row. The requests inbox's swipe has Delete beside Block. Every delete asks first in an alert, for the
  reason Block's does (ADR 2026-10.5wgg). Android's long-press row menu became a swipe here, iOS's own gesture for a
  list row.
- **Control:** `delete-message` (`id`) and `delete-chat` (`conv`, whose reply's `deleted` says whether anything went).
  `interop.py iphone-delete` drives them against an Android phone.

Porting Android's behaviour exactly was the alternative. A deleted group message would then come back at every launch
for a day, so it was ruled out.

**Consequences / limits:**

- **Nothing is unsent.** People you wrote to keep their copies, and so does every carrier. The copy says "this
  iPhone".
- **A deleted photo's bytes outlive its message by up to a day,** unshown and still served, while its frame is carried.
  That is the same custody that already keeps the frame itself.
- **A carrier whose clock runs further behind ours than the message had lived before its delete** can re-serve it after
  its id is forgotten. That needs a clock off by most of a day, and custody's own expiry fails the same way there.
- **Android still has the gap.** A knit-next issue pointing at this ADR would let it take the same rule. Nothing on the
  wire changes either way.
- **The trap:** reading `deleted_messages` anywhere in custody, or purging our own custody copy on delete. Either one
  makes this node's digest differ from its neighbours' (ADR 2026-10.5wgg), and neighbours re-serve the difference at
  every exchange. A delete belongs on the delivery path.
- **The guards:**
  - `DeletedMessageTests`, against both stores, and `SchemaTests`' v8 pin with `v8RemembersNoDeletionAndKeepsEveryMessage`.
  - `MeshEngineDeleteTests`: a group message not replayed at the next start; a re-served DM that stays gone and is
    still acknowledged; custody and the digest unchanged; acceptance kept; a key-waiting DM cancelled; a photo kept and
    served while its frame is carried, then released.
  - `DeleteTests` in KnitAppCore, `MeshControlDeleteTests`, `KnitUITests`' two delete walks, and
    `interop.py iphone-delete` on the phones.

**Amended 2026-10-04, when reactions came in (ADR 2026-10.ehe6):** a delete also removes the deleted messages'
reactions, in the same transaction, as Android's `deleteForMessage` does. A reaction that arrives later for a deleted id
still remembered is refused, so it cannot leave a row behind. Custody still never reads a delete. `ReactionStoreTests`
and `MeshEngineReactionTests.aReactionToADeletedMessageIsRefusedSilently` guard it.
