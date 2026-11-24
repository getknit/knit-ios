---
id: "2026-11.58yk"
slug: a-name-clash-fades-a
title: "A name clash fades a week after the look-alike was last heard"
date: 2026-11-23
topics: [interop, text]
---

# ADR 2026-11.58yk — A name clash fades a week after the look-alike was last heard

Status: Accepted (2026-11-23)

**Context:** a label shows `Name (Alias)` whenever another identity this phone knows shares the name's `NameKey`
(ADR 2026-10.k99b), and the identities it checks are every pinned peer plus us. Nothing ever left that set. A
stranger named Alice heard once at a festival suffixed the contact named Alice on every screen, for good. Android
fixed this in knit-next `47485429` (knit-next ADR 2026-10.k8ge), amended by `28d426883` (ADR 2026-11.p6dk), and
`.agents/context/knit-next.md` had filed it under "nothing to mirror". The maintainer asked for it here. No wire byte
moves, and nothing is paired: each phone judges its own labels.

**Decision:** port the rule from knit-next HEAD `2e91518e3`, in three parts.

- **Stale members give way** (`PeerLabelIndex`'s `stale`, `PeerLabels.index`). The live members, us always among
  them, are labelled as if the stale ones were absent, so a contact whose only namesake went quiet reads plain again.
  A stale member starts at the tokens it would hold against every member, never fewer, and grows past any text that
  still matches, live texts held fixed. So a look-alike that ground a contact's alias and went quiet keeps both
  tokens. `resolve`, for an id outside the index or another name, still counts the stale members.
  `holdsTheNames(of:)` now compares token counts too, since a fade moves labels with no name changing, and
  `MentionLights` must judge again when it does.
- **Who never goes stale** (`LabelFade`, `LabelAnchors`). Not anchored, not verified, and last heard more than a week
  ago, strictly: a stranger. The anchors are the peers of every DM we accepted or wrote in, and the members of every
  group we have not left. With verified peers and us, that covers every contact signal this port has: a link import
  accepts, a scan verifies, and a DM over a relay is authored. They are read only when a quiet peer wears a
  discriminator, since only such a peer moves anyone's label by giving way, and they are read in a store unit of their
  own. Outside a unit a failing read answers empty (ADR 2026-09.nyya), which would make every quiet contact a
  stranger, the look-alike's best case. A failed read fades nobody.
- **When a peer was last heard** (`peers.lastSeenAt`, `v27-peer-last-seen`, `HeardFrom`). This is the newest `sentAt`
  among the peer's signed frames that verified here, by radio or pulled from a spool, capped at our wall clock. The
  engine buffers it in memory, banks it every 60 s and at stop in one write (a stamp within 6 h of the stored one is
  skipped), and emits one `peersHeard` per bank. The profile upsert stamps the row it pins, and no upsert lowers it. The
  migration seeds it from the later of the profile version and the kept proof of key's `sentAt`, as Android's
  `MIGRATION_18_19` does. `AppSession` judges the week whenever its revision moves, every hour while it listens and
  when the app comes to the front, and moves the revision only when who gives way changed. A session built without a
  clock never fades, as a `PeerRepository` without a `LabelFade` never does there. The app always passes one.

Where this port differs from Android, and why:

- **The stamp is floored at 0,** and the bank's gate is overflow-checked. Kotlin keeps a negative stamp, but this is a
  stored presentation value, so nothing on Android reads the difference.
- **Only a sender with a peer row is buffered.** A profile verifies against its own in-band key before it pins.
  Android buffers those, so a burst of fresh identities could fill the 1,024-id buffer and push an honest namesake's
  stamp out. A new pin is stamped by the profile upsert instead.
- **The bank emits one `peersHeard` event, not a profile event.** knit-peer turns a profile event into a `profile`
  line, which `interop.py` reads as "a profile arrived". The session re-labels only when a heard peer was stale.
- **Custody replays at start do not stamp.** Android replays custody through `onDeliver`. Here the start and hourly
  replays take the ratchet's custody route, which never reaches `verify`. A frame was stamped when it first verified,
  so only the stamps of the last minute before iOS ended Knit without a stop are lost.

The alternative a reader reaches for first is to drop quiet strangers from the index. It fails on two quiet Alices:
both would read plain.

**Consequences / limits:** a contact's label now changes when the other Alice goes quiet, not only when she appears.
The appearance is still the tell. A received mention's highlight follows the reader's labels (ADR 2026-11.p6dk there),
so a fade can light an old "@Alice", and a new clash can put it out. Nearby-room regulars the user never wrote to
aren't anchored, so two such strangers can swap which reads plain as each goes quiet; both stay labelled apart. Someone
known only through a group is anchored only while both stay in it. The stamp is the peer's own word, so a look-alike
that dates its frames back reads as quiet while it posts: the contact beside it reads plain, and it keeps its own
alias. The Add contact preview yields to stale members too, so it can show the alias before an import and none after.

The trap: `lastSeenAt` is sender-asserted and rides replays. It is presentation only. It must never feed a presence
tier, a route, custody, a fetch order or what is evicted first. Android also reads it to order face re-wants
(`PeerDao.facesNeedingFetch`, knit-next ADR 2026-11.4ckq) and in `MeshcoreClaim`; this port takes neither. A new
reader here amends this ADR and goes past the blobs reviewer. It is never drawn, sent or logged per peer. A new
contact signal joins `LabelAnchors` as well as `DirectContacts`.

The tests that keep this true:

- `StaleLabelsTests`, ported from `PeerLabelsTest`'s stale cases;
- `LabelFadeTests`, covering the window, the anchors and a failed read;
- `LabelFadeSessionTests`, covering a fade on the calendar alone, every anchor, a re-heard stranger and a failed
  anchors read;
- `MentionLightsTests.aFadeLightsTheBareNameAndANewClashPutsItOut`;
- `HeardFromTests` and the engine's bank tests;
- `SchemaTests+V27`.
