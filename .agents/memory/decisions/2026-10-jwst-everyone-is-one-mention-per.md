---
id: "2026-10.jwst"
slug: everyone-is-one-mention-per
title: "@everyone is one mention per member"
date: 2026-10-14
topics: [mentions, groups]
---

# ADR 2026-10.jwst — @everyone is one mention per member

Status: Accepted (2026-10-14)

**Context:** a group's members could be mentioned one pick at a time (ADR 2026-10.nbhj), and calling a whole group of up
to eight took up to seven picks. A receiver already alerts on the node-id match alone, once per message and only in an
accepted thread, so the mention list is all an alert needs. Android adds `@everyone` as sender-side sugar (knit-next ADR
2026-10.6h2g), and its builds already in the field take the result without knowing the word.

**Decision:** the iPhone mirrors it, in the composer alone.

- **The row.** A group thread's picker offers an `@everyone` row first, matched when the query is blank or `everyone`
  starts with it (trimmed, case-insensitive). It isn't offered in a DM, in Nearby, or when the roster holds nobody but
  us and the blocked. It reads the roster only, where the other rows also take senders.
- **A pick.** It writes `@everyone ` into the draft and adds one `Mention(nodeId, "everyone")` for each roster member
  but us and the blocked, in ascending node id, each pair once. The name is ASCII and never localized: it lives in the
  sender's body. A person picked by hand keeps their own entry beside it.
- **Send.** The existing filter stands: the entries ride only while `@everyone` is still in the text, so editing it away
  drops all of them. A restored draft keeps its text and loses its bindings, as it does for any pick.
- **Nothing else moves.** No wire byte, no receive path, no notification code and no `MessageMention.carried`: seven
  entries of one name count one distinct token against its bound.

The alternatives, and why not: a token the receiver expands, or a sentinel node id, would need every build already out
to change; a new wire field would add a capability bit for what the existing list can say.

**Consequences / limits:** the list is frozen at pick time, so a member who joins later isn't mentioned, and one who has
left isn't either. A mention alerts; the row's copy promises no more than that. The bound in `MessageMention.carried`
needs a second look if a group's cap ever rises past eight. `MentionEveryoneTests` pins the row, the pick and what Send
keeps; `MessageMentionTests` and `MeshEngineMentionTests` pin seven entries through `carried` and a sealed group
message; the UI test walks the row in a group.
