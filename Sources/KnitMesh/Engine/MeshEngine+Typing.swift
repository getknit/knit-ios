import KnitStore
public import KnitWire

/// Typing cues (after `MeshManager.sendTyping`, `InboundPipeline.handleTyping` and `TypingTracker` in knit-next).
///
/// A cue is a signed, cleartext `typing` frame with `relay = false` and a fresh id each time, so no seen set swallows
/// the next one. It names its thread as a chat does, a DM by its recipient and a group by a compact
/// ``TypingContent/groupId``, and goes one hop: to the DM's peer if linked, otherwise to every neighbour. It is never
/// carried, parked or relayed, never rings the doorbell, and is never sealed: Android seals none. Nothing says a sender
/// stopped; a cue lapses on its own, or when their message lands.
extension MeshEngine {
    /// Tells `thread` that we are typing, unless we did within ``MeshConfiguration/typingIntervalMilliseconds``
    /// (`ChatViewModel.onUserTyping`'s throttle): the room and a group we are still in go to every neighbour, and a DM
    /// only to its peer, and only if that peer is linked. Answers whether a cue went out. A thread this node cannot
    /// write in, a group we left or a person we blocked, gets none.
    @discardableResult
    public func noteTyping(in thread: String) -> Bool {
        let now = clock.monotonicMilliseconds()
        let interval = configuration.typingIntervalMilliseconds
        let key = ExactKey(thread)
        if let last = typingCues[key], now - last < interval {
            return false
        }
        guard let scope = typingScope(of: thread), let wire = sign(typingCue(scope), relay: false) else {
            return false
        }
        typingCues = typingCues.filter { now - $0.value < interval }
        typingCues[key] = now
        transport.send(wire, to: scope.recipient)
        return true
    }

    /// Someone's typing cue (`InboundPipeline.handleTyping`), held in its thread for
    /// ``MeshConfiguration/typingLifetimeMilliseconds``: a group's when we hold the group and the sender is on its roster,
    /// a DM's when it is addressed to us, and the room's when it names nobody. A blocked sender's is dropped, and so is
    /// one that does not decode, which knit-next `03c4c3b1` counts rather than read as a DM or room cue.
    func handleTyping(_ envelope: RelayEnvelope) {
        guard let sender = NodeId(envelope.senderId), sender != nodeId else {
            return
        }
        if isBlocked(sender) {
            // Never `dropBlocked`: it ticks a frame that names no recipient as a room post, and a cue earns no tick.
            drop(.blocked, envelope)
            return
        }
        guard let content = try? TypingContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        let thread: String
        if let groupId = content.groupId {
            // Android takes any sender in a held group; a cue from off the roster shows in nothing a member would see.
            guard let group = stores.groups.group(groupId), group.member(sender.string) != nil else {
                return
            }
            thread = group.id
        } else if let recipient = envelope.recipientId {
            guard NodeId(recipient) == nodeId else {
                return
            }
            thread = sender.string
        } else {
            thread = Conversations.nearby
        }
        let lapsesAt = clock.monotonicMilliseconds() + configuration.typingLifetimeMilliseconds
        if typing.note(sender, in: thread, until: lapsesAt) {
            announceTyping()
        }
    }

    /// `sender`'s message landed in `thread`, so their cue there ends now (`TypingTracker.onMessageFrom`).
    func clearTyping(_ sender: NodeId, in thread: String) {
        if typing.clear(sender, in: thread) {
            announceTyping()
        }
    }

    /// Ends every cue due by `now`.
    func lapseTyping(now: Int64) {
        if typing.lapse(now: now) {
            announceTyping()
        }
    }

    /// Forgets who is typing, as the mesh stops: no cue reaches a stopped node to end it.
    public func forgetTyping() {
        if typing.removeAll() {
            announceTyping()
        }
    }

    /// Who is typing where, as the board holds it now.
    public var typingNow: [String: [NodeId]] { typing.picture }

    // MARK: Private

    private struct TypingScope {
        var recipient: NodeId?
        var groupId: String?
    }

    /// Whom a cue in `thread` names, or `nil` for a thread we cannot write in.
    private func typingScope(of thread: String) -> TypingScope? {
        if thread == Conversations.nearby {
            return TypingScope()
        }
        if Conversations.isGroup(thread) {
            guard let group = stores.groups.group(thread), !group.hasLeft else {
                return nil
            }
            return TypingScope(groupId: group.id)
        }
        guard let peer = NodeId(thread), peer != nodeId, !isBlocked(peer) else {
            return nil
        }
        return TypingScope(recipient: peer)
    }

    /// The cue itself (`MeshManager.sendTyping`): no `group` roster, which could crowd a small frame, only the group's id.
    private func typingCue(_ scope: TypingScope) -> RelayEnvelope {
        RelayEnvelope(
            type: .typing,
            id: newFrameId(),
            senderId: nodeId.string,
            sentAt: clock.wallMilliseconds(),
            recipientId: scope.recipient?.string,
            payload: TypingContent(groupId: scope.groupId).encoded
        )
    }

    private func announceTyping() {
        events.append(.typing(typing.picture))
    }
}
