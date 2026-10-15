import KnitMesh
import KnitStore
import KnitWire

// The composer's mentions (ADR 2026-10.nbhj): the "@" word the cursor sits in, the people it offers, a pick, and the
// chips that keep each picked name whole, as `ChatScreen.kt`'s `pendingMentions` and `MentionChips` do.
extension ChatModel {
    /// The "@" word the cursor sits in while nothing is selected, wherever the thread takes a message, or `nil`.
    public var mentionQuery: MentionQuery? {
        guard selection.isEmpty, state.canReply else {
            return nil
        }
        return MentionText.activeQuery(in: draft, cursor: selection.lowerBound)
    }

    /// Whom the picker offers for ``mentionQuery``: empty when there is no query, or nobody matches it, and the picker
    /// stays closed.
    public var mentionCandidates: [MentionCandidate] {
        guard let query = mentionQuery else {
            return []
        }
        let offered = offeredCache.value(for: session.revision) {
            let group = session.threads().group(conversationId)
            return MentionCandidate.offered(
                senders: session.stores.messages.senders(in: conversationId),
                members: group?.members ?? [],
                isGroup: group != nil,
                directory: session.directory
            )
        }
        return MentionText.filter(offered, query: query.query)
    }

    /// Where the picked names sit in the draft, each one chip.
    public var chips: [Range<Int>] {
        MentionText.spans(in: draft, mentions: pendingMentions)
    }

    /// Mentions `candidate`: the "@" word becomes "@", their label and a space, the cursor goes past it, and the pick is
    /// kept for Send (`ChatScreen.kt:3799-3810`). A second pick of the same person adds nothing more. The `@everyone` row
    /// keeps one mention for each member it stands for, and a second pick of it adds none.
    public func mention(_ candidate: MentionCandidate) {
        guard let query = mentionQuery else {
            return
        }
        let units = Array(draft.utf16)
        let insertion = MentionText.insertion(for: candidate)
        let edited = units[..<query.start] + Array(insertion.utf16) + units[query.end...]
        draft = String(decoding: edited, as: UTF16.self)
        let cursor = min(query.start + insertion.utf16.count, draft.utf16.count)
        selection = cursor..<cursor
        for picked in candidate.mentions {
            let key = [ExactKey(picked.nodeId), ExactKey(picked.name)]
            if !pendingMentions.contains(where: { [ExactKey($0.nodeId), ExactKey($0.name)] == key }) {
                pendingMentions.append(picked)
            }
        }
    }

    /// Applies a typed edit, replacing the UTF-16 `range` of the draft with `replacement`, if it would cut into a chip:
    /// it takes the whole chip, or lands after it (``MentionText/keepChipsWhole(_:edits:)``). Answers `false` when the
    /// edit leaves every chip whole, for the field to apply as it came.
    public func keepChipsWhole(replacing range: Range<Int>, with replacement: String) -> Bool {
        guard let edited = MentionText.edited(draft, chips: chips, replacing: range, with: replacement) else {
            return false
        }
        draft = edited.text
        let cursor = min(edited.cursor, draft.utf16.count)
        selection = cursor..<cursor
        return true
    }

    /// Moves the field's new selection out of any chip, given the cursor before a move that changed no text, and keeps
    /// it (``MentionText/snapOutOfChips(_:selection:from:)``). Answers the selection the field should show.
    public func select(_ range: Range<Int>, from previous: Range<Int>?) -> Range<Int> {
        let snapped = MentionText.snapOutOfChips(chips, selection: range, from: previous)
        selection = snapped
        return snapped
    }
}
