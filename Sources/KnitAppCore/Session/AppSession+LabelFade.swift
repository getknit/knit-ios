import KnitMesh
import KnitStore
import KnitWire

/// A stranger's name clash fades a week after the look-alike was last heard (ADR 2026-11.58yk, knit-next ADR
/// 2026-10.k8ge): the directory lets the quiet strangers give way in its labels, judged again whenever the revision moves,
/// every hour while the session listens, and when the app comes back to the front.
extension AppSession {
    /// Everyone this device knows, labelled, as of now: the pinned peers, the people blocked, and our own profile, with
    /// the strangers whose clash has faded giving way.
    func buildDirectory() -> Directory {
        let own = stores.ownProfile.load()
        let peers = stores.peers.allPeers()
        let blocked = stores.blocks.blockedNodeIds()
        let names = filtersContent ? names : nil
        let directory = { (stale: Set<NodeId>) in
            Directory(
                peers: peers,
                blocked: blocked,
                me: self.identity.nodeId,
                myName: own.name,
                myPhoto: own.avatarHash,
                names: names,
                stale: stale
            )
        }
        let plain = directory([])
        let stale = fadedStrangers(among: peers, labelled: plain.labels)
        return stale.isEmpty ? plain : directory(stale)
    }

    /// The strangers in `peers` whose clash has faded (``LabelFade``), given `labels`, the index with none giving way.
    ///
    /// A peer moves anyone's label by giving way only if it wears a discriminator of its own there: every member of a
    /// shared name, and of a shared text, grows together. So a quiet peer that reads plain changes nothing, and only the
    /// ones that clash are judged. Most of the time that is none, and the anchors, which cost a look through the messages,
    /// are never read.
    private func fadedStrangers(among peers: [PeerRecord], labelled labels: PeerLabelIndex) -> Set<NodeId> {
        guard let now else {
            return []
        }
        let me = identity.nodeId
        let clashing = peers.filter { $0.nodeId != me && labels.label(for: $0.nodeId.string).discriminator != nil }
        return LabelFade.stale(among: clashing, now: now()) { anchors() }
    }

    /// The anchors (``LabelAnchors``), read in a store unit of their own, or `nil` when a read failed. Outside a unit a
    /// failing store answers as if it held nothing (ADR 2026-09.nyya), and an empty answer here would make every quiet
    /// contact a stranger: the look-alike reading plain beside them, its best case. With `nil`, nothing fades.
    private func anchors() -> Set<NodeId>? {
        let stores = stores
        let me = identity.nodeId
        let read = stores.transactor.atomically { () -> Set<NodeId>? in
            LabelAnchors.of(
                accepted: stores.conversations.acceptedConversations(),
                authored: stores.messages.conversations(authoredBy: me),
                groups: stores.groups.groups())
        }
        guard case .committed(let anchors) = read else {
            return nil
        }
        return anchors
    }

    /// Judges the week again with nothing written: a stranger crosses it on the calendar. Only a change to who gives way
    /// moves the revision, so every screen, the list and the open thread as much as the next notification, reads the
    /// same labels.
    func judgeLabelFade() {
        guard now != nil, buildDirectory().stale != directory.stale else {
            return
        }
        revision += 1
    }

    /// ``judgeLabelFade()`` every ``LabelFade/tickMilliseconds`` until the calling task is cancelled.
    func judgeLabelFadeHourly() async {
        guard now != nil else {
            return
        }
        while true {
            do {
                try await Task.sleep(for: .milliseconds(LabelFade.tickMilliseconds))
            } catch {
                return
            }
            judgeLabelFade()
        }
    }
}
