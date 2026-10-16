import KnitStore
import KnitWire

/// The rest of the DM ctl plane we send, sealed with the switch on (ADR 2026-10.5sk9, phase P5e): our DM reactions
/// (`sendReaction`, `sealReaction` and `sealDmReaction`, `MeshManager.kt:2174-2276`, at knit-next `cbf2a487`), our sealed
/// profile fanned to our confirmed sessions (`broadcastSealedProfile`, `currentProfilePayload` and `sendCtlDm`,
/// `:2840-2951`), and the answer a peer's still-riding init is owed (IntroSync's answer half, ``RatchetAnswers``; wired at
/// `MeshManager.kt:345-347`, `:517-519`, and answered with `sendIntroTo`, `:2885-2889`).
///
/// Each is a ctl DM originated through ``sealControl(_:to:in:plan:)``: in a store unit of its own, the outermost, the peer's
/// row read inside it, signed once, carried in our custody inside it, and marked and flooded only once it commits. None is
/// ever wrapped in v1. What cannot be sealed goes as its cleartext form: a reaction as the `reaction` frame, and a profile
/// not at all, since the cleartext profile goes whatever happens here. A store that fails sends nothing, as Kotlin's throw
/// does.
///
/// With the switch off, a reaction is today's cleartext frame from the same draws, and nothing here seals, reads the
/// ratchet's tables or draws a frame id.
extension MeshEngine {
    /// How our init answers went so far, under the name of Android's metric (``RatchetAnswerCounts``, phase P5e).
    public var answers: RatchetAnswerCounts { presentation.counts }

    // MARK: Our reactions

    /// Our reaction `reaction`, just applied to the message it names in thread `conversationId`, put on the air
    /// (`sendReaction`, `MeshManager.kt:2174-2199`). A reaction to a message in a DM with a peer who can read one goes as a
    /// sealed `CTL_REACTION` under a fresh id, dated by the row's own clock, so last writer wins compares the same stamp on
    /// both phones (`sealDmReaction`, `:2249-2276`). The room's goes as the cleartext `reaction` frame always, the room
    /// being plaintext by design, and a group's does until phase P6b ports its sealed form (`sealGroupReaction`). Toward a
    /// DM peer who cannot read one, and when the facade cannot seal, the cleartext frame goes, counted
    /// (`onReactionSealedFallback`, `:2189`). A store that fails sends neither, as Kotlin's throw out of `sendReaction`
    /// sends nothing; the row stays applied, as Kotlin's optimistic row does (`:2187`).
    func sendReaction(_ reaction: ReactionRecord, in conversationId: String) {
        guard configuration.ratchet, case .direct(let peer) = RatchetOutbound.reactionTarget(in: conversationId, me: nodeId) else {
            originateCleartext(reaction)
            return
        }
        let content = RatchetOutbound.reaction(on: reaction.messageId, emoji: reaction.emoji)
        let sealing = sealControl(content, to: peer, in: .reaction(at: reaction.updatedAt)) {
            RatchetOutbound.receiptPlan(to: stores.peers.peer(peer), ratchet: true)
        }
        switch sealing {
        case .sealed(let sealed):
            originateSealed(sealed)
            seals.reactionsSealed += 1
        case .unreadable, .unsealable:
            seals.reactionsSealedFallback += 1
            originateCleartext(reaction)
        case .failed:
            log.log(.warning, "mesh reaction on \(reaction.messageId) not sent: a store failed")
        case .joined:
            log.log(.warning, "mesh reaction on \(reaction.messageId) held back: asked for inside a store unit")
        }
    }

    /// Our reaction as the cleartext `reaction` frame, naming no recipient and no group, signed, flooded and carried
    /// (`MeshManager.kt:2190-2198`): the one form with the switch off, and the fallback with it on.
    private func originateCleartext(_ reaction: ReactionRecord) {
        originate(
            RelayEnvelope(
                type: .reaction,
                id: newFrameId(),
                senderId: nodeId.string,
                sentAt: reaction.updatedAt,
                payload: ReactionContent(messageId: reaction.messageId, emoji: reaction.emoji).encoded
            )
        )
    }

    // MARK: Our sealed profile

    /// Fans our sealed profile (`CTL_PROFILE`) to every peer we hold a confirmed session with (`broadcastSealedProfile`,
    /// `MeshManager.kt:2812-2853`): beside the cleartext profile, never instead of it, since only the cleartext one works at
    /// first contact and toward a build without the ratchet. So it takes nothing off the cleartext plane: the cleartext
    /// profile still floods our name, status and photo's hash to everyone, that peer included. Kotlin's doc says the
    /// sealed copy takes them off it (`:2819-2820`), which over-claims in the same way.
    ///
    /// The target set is the confirmed sessions, not accepted threads or unblocked people: a sealed profile discloses less
    /// than the cleartext profile already floods to everyone (`:2822-2824`). It is deduped per peer and version, never
    /// floored on a timer, so a second edit goes at once. A version of 0 has never been edited, and goes to nobody.
    ///
    /// Run after each edit of what we present (``publishEdit(_:)``, as `watchProfileChanges` runs it, `:2687-2688`; in
    /// ``setAvatar(_:)``, once the photo's push is queued) and at each heal (`:974`), since the target set is the sessions
    /// confirmed by then: a session that confirms just after an edit is told at the next heal. The dedupe lives in memory,
    /// as Kotlin's does, but two things mark it that Kotlin's leaves alone, so a relaunch and a new session buy no copy
    /// nobody needs: the start's seed (``seedSealedProfileVersions()``) and a sealed answer (``answer(_:of:)``).
    func broadcastSealedProfile() {
        // Who is owed this version comes first: on a heal with nobody owed, the common case, nothing more is read.
        guard configuration.ratchet, let own = stores.ownProfile.loadIfReadable(), own.version > 0 else {
            return
        }
        guard let confirmed = ratchet.confirmedPeers() else {
            log.log(.warning, "mesh sealed profile not sent: the sessions could not be read in a unit of their own")
            return
        }
        let owed = confirmed.filter { presentation.sealedProfileVersions[$0] != own.version }
        guard !owed.isEmpty else {
            return
        }
        let content = RatchetOutbound.profile(of: own)
        for peer in owed {
            let sealing = sealProfile(content, photo: own.avatarHash, to: peer) {
                RatchetOutbound.receiptPlan(to: stores.peers.peer(peer), ratchet: true)
            }
            switch sealing {
            case .sealed(let sealed):
                originateSealed(sealed)
                presentation.sealedProfileVersions[peer] = own.version
            case .failed:
                log.log(.warning, "mesh sealed profile to \(peer) not sent: a store failed")
            case .unreadable, .unsealable, .joined:
                // Left owed for the next heal: a peer whose pinned profile dropped the bit, a seal the facade could not make,
                // or a unit a caller opened.
                continue
            }
        }
    }

    /// Seeds the fan-out's dedupe at start with our profile's version as the last run left it, for every peer we hold a
    /// confirmed session with, so a relaunch sends none of them that version again (phase P5e). Kotlin's
    /// `sentProfileVersions` starts empty, and its first heal after a restart sends the version to every session once more
    /// (`MeshManager.kt:2836-2838`): one row of ours per session in every custody in reach, for a day, purged by nothing,
    /// since a ctl earns no receipt. The iPhone relaunches to restore Bluetooth far more often than Android's foreground
    /// service restarts (ADR 2026-10.mueg), so this port seeds it, a deliberate difference.
    ///
    /// What the seed forgoes is a sealed copy for a session that confirmed after the last fan-out to it, or that a failed
    /// seal left owed. That session takes this version from the cleartext profile, which reaches everyone and which both
    /// writers order on the version alone (`InboundPipeline.kt:1346-1349`, `:3285-3287`); this port has no spool where
    /// only the sealed copy would reach. It is seeded, not kept in the database: a kept map would send only those copies,
    /// at the cost of a table on both store kinds and a write in every seal's unit. It runs before the start's prekey
    /// sync, so a rotation due at start is a version the next heal sends, as a rotation due at a heal is. A store that
    /// cannot list the sessions seeds nothing, and the first heal sends the version once more, as Kotlin's does.
    func seedSealedProfileVersions() {
        guard configuration.ratchet, let own = stores.ownProfile.loadIfReadable(), own.version > 0 else {
            return
        }
        guard let confirmed = ratchet.confirmedPeers() else {
            log.log(.warning, "mesh sealed profile's dedupe not seeded: the sessions could not be read in a unit of their own")
            return
        }
        for peer in confirmed {
            presentation.sealedProfileVersions[peer] = own.version
        }
    }

    /// `content`, our sealed profile, sealed to `peer` as `readPlan` says, with our photo's hash `photo` beside it in the
    /// clear (`sendCtlDm`, `MeshManager.kt:2916-2951`): the hash alone, never its type (knit-next ADR 035), which lets a
    /// carrier that cannot read the frame pull the photo it names, as Kotlin repeats it. The authoritative copy is the one
    /// inside the seal.
    private func sealProfile(
        _ content: MessageContent, photo: BlobHash?, to peer: NodeId, plan readPlan: () -> RatchetOutbound.ReceiptPlan?
    ) -> ControlSealing {
        sealControl(content, to: peer, in: .profile(photo: photo), plan: readPlan)
    }

    // MARK: Init answers

    /// Answers the init `header` carries, from `sender`'s frame whose open just committed as its first verdict
    /// (`onPeerFrameOpened`, `IntroSync.kt:221-240`, called once `commitOpen` commits, `InboundPipeline.kt:1059-1067`): a
    /// header still carrying its sender's init proves the sender has seen no frame of ours, and our sealed profile, which
    /// it opens under the session we hold, is the frame that confirms it. Any frame that opened does, a ctl and the
    /// unsigned tick among them, as in Kotlin.
    ///
    /// Never from the start's replay, which only delivers, as Kotlin answers only in its commit and never re-opens its
    /// custody. A frame from the era we hold whose first verdict committed drops there as `DUPLICATE`, so none is answered
    /// twice. The frames that open there and deliver are the ones a failed unit or a closed switch left unread
    /// (``replayCustodiedRatchetMessages()``): their first verdict never committed, and none was answered. Each is left to
    /// its sender's next frame or to our first frame under the session, so the initiator stays unconfirmed that much
    /// longer, up to its re-send floor when its only frame was a ctl: no worse than Kotlin.
    func answerInit(in header: RatchetHeader, from sender: NodeId) {
        guard presentation.answersInits, let initial = RatchetAnswers.Init(header) else {
            return
        }
        answer(initial, of: sender)
    }

    /// A cleartext profile of `peer`'s just pinned as `record` (`onProfilePinned`, `IntroSync.kt:185-196`, called from
    /// `handleProfile`, `InboundPipeline.kt:3230`): the answer owed to an init of theirs that opened before we could seal
    /// to them is tried again, floor and all, and one whose profile pinned without the ratchet is forgiven.
    func answerOwedInit(of peer: NodeId, pinned record: PeerRecord) {
        guard configuration.ratchet else {
            return
        }
        if RatchetOutbound.isRatchetless(record) {
            presentation.answers.forgive(peer)
            return
        }
        if let debt = presentation.answers.takeDebt(of: peer) {
            answer(debt, of: peer)
        }
    }

    /// The answer `initial` from `peer` is owed, sealed and sent unless the same init was answered within the floor
    /// (``RatchetAnswers``): our current profile at its version, a version of 0 included, which Android ignores while the
    /// session still forms (`sendIntroTo`, `MeshManager.kt:2877-2889`). It bypasses the fan-out's dedupe, as Kotlin's does,
    /// since the answer keeps floors of its own. It needs what IntroSync's `canSeal` asks, the bits and a verified prekey
    /// (``RatchetOutbound/answerPlan(to:ratchet:)``), read once inside the seal's unit.
    ///
    /// Once sealed, it marks the fan-out's dedupe with the version it carried, which Kotlin's leaves alone (`:2883`): the
    /// answer is that version's sealed profile, so the next heal owes the peer nothing more of it, where Kotlin's sends the
    /// same version again, one more row in every custody in reach for each new session. An answer that is lost is given
    /// again at the init's floor, while the init still rides. A deliberate difference, as the start's seed is
    /// (``seedSealedProfileVersions()``).
    ///
    /// The debt is recorded before the attempt (`IntroSync.kt:231-235`), so what the attempt comes to decides it:
    /// - sealed: the floor starts, the debt is paid, and it counts (`onIntroAnswered`);
    /// - nothing sealable yet, no bits or no prekey pinned: it stays owed until a profile that carries them pins;
    /// - a seal the facade could not make toward a peer who could read one: the debt goes with no floor, as Kotlin's failed
    ///   send removes both (`:239`), so the next frame carrying the init tries again;
    /// - a store that failed, or a unit a caller opened: nothing goes, and the debt stays owed with no floor. Kotlin's throw
    ///   out of its `canSeal` leaves it so; its throw out of `sendIntro` would leave the floor set and the answer lost for
    ///   the hour, which one unit that reads and seals cannot tell apart, so the debt is kept.
    private func answer(_ initial: RatchetAnswers.Init, of peer: NodeId) {
        let now = clock.monotonicMilliseconds()
        guard configuration.ratchet, presentation.answers.owe(initial, to: peer, now: now) else {
            return
        }
        guard let own = stores.ownProfile.loadIfReadable() else {
            log.log(.warning, "mesh answer to \(peer)'s init owed: our profile could not be read")
            return
        }
        let sealing = sealProfile(RatchetOutbound.profile(of: own), photo: own.avatarHash, to: peer) {
            RatchetOutbound.answerPlan(to: stores.peers.peer(peer), ratchet: true)
        }
        switch sealing {
        case .sealed(let sealed):
            originateSealed(sealed)
            presentation.answers.answered(initial, of: peer, at: now)
            presentation.sealedProfileVersions[peer] = own.version
            presentation.counts.introsAnswered += 1
            log.log(.info, "mesh answered \(peer)'s init as \(sealed.frame.envelope.id)")
        case .unreadable:
            log.log(.info, "mesh answer to \(peer)'s init owed until its prekey pins")
        case .unsealable:
            presentation.answers.unanswered(peer)
        case .failed:
            log.log(.warning, "mesh answer to \(peer)'s init owed: a store failed")
        case .joined:
            log.log(.warning, "mesh answer to \(peer)'s init held back: asked for inside a store unit")
        }
    }
}

/// What our reactions, our sealed profile and our init answers keep in memory (phase P5e), the engine's one
/// ``MeshEngine/presentation``. It dies with the process, as Kotlin's `sentProfileVersions` and IntroSync's floors and debts
/// do; the start seeds the dedupe again (``MeshEngine/seedSealedProfileVersions()``).
internal struct RatchetPresentationState {
    /// The answers we owe the inits peers' frames still carry, and when each was last given.
    var answers = RatchetAnswers()
    /// Whether an init a peer's frame still carries is answered: always, but in A9's replays. It is their seam, internal as
    /// the engine's initializer that takes A9's draws is (`ratchetEngine:`), so nothing outside KnitMesh, the app and
    /// knit-peer included, can turn answers off. The file comes from Kotlin's pipeline alone, which wires no answer
    /// (`onPeerFrameOpened`'s default, `InboundPipeline.kt:206`, at knit-next `cbf2a487`), so a replay turns it off to seal the
    /// file's frames byte for byte.
    var answersInits = true
    /// The profile version our sealed profile last went at to each peer (`sentProfileVersions`, `MeshManager.kt:610-611`):
    /// the fan-out's dedupe per peer and version (``MeshEngine/broadcastSealedProfile()``), seeded at start and marked by a
    /// sealed answer, where Kotlin's is marked by the fan-out alone.
    var sealedProfileVersions: [NodeId: Int64] = [:]
    /// How our init answers went so far, which ``MeshEngine/answers`` reads.
    var counts = RatchetAnswerCounts()
}
