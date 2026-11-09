import KnitCrypto
import KnitStore
public import KnitWire

/// The blinded advert's writer (knit-next ADR 2026-11.xp6d's writer, at `cad69c77b`; ADR 2026-11.prsp): the iPhone airs a
/// rotating tag in its GATT payload instead of its id, tells its linked contacts the coming tag in `TAG_NEXT`, writes `t` in
/// its HELLO, and takes Android's two blinding admission rows (`LinkManager+Admission.swift`).
///
/// - **The gate.** ``Configuration/blindsAdvert`` says whether this build may blind at all, and ``setBlinding(_:)`` is the
///   runtime switch, starting where ``Configuration/blindSwitchOn`` puts it. With either off, or no ``PresenceKeySource``
///   attached, the forms are clear and nothing here runs: no slot turn, no `TAG_NEXT`, no `t`, no blinding row. A flip with
///   the radio up closes every open channel, so each peer relinks and looks the doorbell up afresh.
/// - **One snapshot** (``AdvertWriter``): the form on the air, the one before it and the PSM, replaced whole. Every advert
///   push builds from it, and ``AdvertOrder/Mine`` is read from it.
/// - **The turn** (``AdvertRotation``): the coming slot's tag reserved and announced 210 s before the edge, the rotation at
///   the first wake at or after the later of the edge and the announcement plus 30 s, a late wake's rotation unannounced
///   and followed by the form once to each link. Each bring-up, key change and flip rotates at once.
/// - **The sends** (``TagNextSends``): a link record, written first in first out behind whatever the link holds, as
///   Android's `FramedLink.sendTagNext` queues it, and never a ring.
///
/// Nothing here logs a time, a generation or a slot beside a rotation, and no line names a tag: what happened is counted
/// (``writerCounters``), and a send's line names its recipient alone.
extension LinkManager {
    /// The writer's state, apart from the reader's.
    struct BlindWriter {
        /// The aired snapshot.
        var writer: AdvertWriter
        /// The marks and the reservation.
        var schedule: TagSchedule
        /// The slot turn.
        var rotation = AdvertRotation()
        /// One pass request per generation for a stale mark.
        var staleLatch = StaleLatch()
        /// Who was sent a form, and when.
        var sends = TagNextSends<ChannelID>()
        /// Each link's announced form waiting for its edge.
        var notes = LinkFormNotes<ChannelID>()
        /// The engine's readers, handed once (``attachPresenceKeys(_:)``).
        var source: PresenceKeySource?
        /// The key handed in last (Kotlin's `ownKey`), read by a rotation and an announcement.
        var ownKey: OwnPresenceKey?
        /// The key the last key change step took (Kotlin's `workerKey`).
        var stepKey: OwnPresenceKey?
        /// A key change waits for the next advance: the engine may hand it in inside a store unit, where a mark write fails.
        var keyChangeDue = false
        /// The generation the tag on the air was minted under, `nil` for a random or clear form.
        var airedGeneration: Int64?
        /// Whether this session has had a key yet: its first completes a bring-up that aired a random tag.
        var sessionHadKey = false
        /// The announced tag that stands until its rotation, for a link that comes up meanwhile.
        var announcedTag: NodeId?
        /// The runtime switch (``setBlinding(_:)``).
        var switchOn: Bool
        /// What each live link's peer advertises as far as we know: the form we dialed, an accepted dialer's honoured `t`, or
        /// the form its accepted `TAG_NEXT` named, from that form's edge (Kotlin's `linkForms`). The debug bridge reads it.
        var linkForms: [ChannelID: AdvertOrder.Form] = [:]
        /// The counts.
        var counts = WriterCounters()
        /// What the last install was, for the debug bridge's `advert` (``AdvertStatus``).
        var lastInstall: AdvertStatus.Install?
        /// When the last install was, on the monotonic clock: a forced rotation waits out
        /// ``LinkManager/forcedRotationGraceMilliseconds`` after it.
        var lastInstallAt: Int64?
        /// The bring-up rotations in the slot of the last one, which spend the slot's restart indexes beside forced rotations.
        var bringUps = SlotCount()

        init(localId: NodeId, switchOn: Bool) {
            writer = AdvertWriter(localId: localId)
            schedule = TagSchedule(owner: localId.bytes)
            self.switchOn = switchOn
        }
    }

    /// The marks, through the engine's readers.
    struct SourceMarks: TagMarks {
        let source: PresenceKeySource

        func read(_ generation: Int64) throws(PresenceMarkReadFailure) -> PresenceMark? {
            try source.readMark(generation)
        }

        func write(_ mark: PresenceMark, _ generation: Int64) -> PresenceMarkWrite {
            source.writeMark(mark, generation)
        }
    }

    // MARK: The gate

    /// The engine's readers while this node blinds, or `nil` while it airs its id.
    var blindingSource: PresenceKeySource? {
        configuration.blindsAdvert && blindWriter.switchOn ? blindWriter.source : nil
    }

    /// Whether this node airs a tag now, or will at its next bring-up.
    public var blinds: Bool { blindingSource != nil }

    /// The writer's counters.
    public var writerCounters: WriterCounters {
        var counted = blindWriter.counts
        counted.droppedPayloads = blindWriter.writer.clearRefused
        return counted
    }

    /// Turns the runtime switch: a build whose configuration may blind airs a tag while it is on. A flip while the radio is up
    /// closes every open channel, its cause logged, then rotates to the wanted form at once (``AdvertRotation/Cause/flip``): a
    /// flip moves the doorbell between the combined service and the doorbell's own, so its handle changes, and a ring client
    /// that looked it up once would write to a dead handle for the rest of the link (ADR 2026-11.prsp, "Two gates"). The
    /// closed links go down at the next entry (``deferredDowns``), and each peer relinks and looks the doorbell up afresh. A
    /// flip while the radio is down takes effect at the next bring-up. A build that may not blind ignores it.
    public func setBlinding(_ on: Bool) {
        guard configuration.blindsAdvert, on != blindWriter.switchOn else {
            return
        }
        blindWriter.switchOn = on
        let writer = blindWriter.writer
        guard writer.isUp, let aired = writer.aired, aired.form.blinded != blinds else {
            return
        }
        // First, so the rotation sends its form to no link it is about to close.
        closeChannelsAtFlip()
        rotate(.flip, announced: false, psm: aired.psm)
    }

    /// Closes every channel past its dial, live or in its handshake; a dial still opening writes its HELLO under the new form.
    func closeChannelsAtFlip() {
        let now = clock.monotonicMilliseconds()
        let wanted = blinds ? "a tag" : "the id"
        for id in channels.filter({ $0.value.stage != .connecting }).map(\.key).sorted(by: Self.inOrder) {
            log.log(.info, "link \(id) closed: the advert flipped to \(wanted)")
            deferredDowns += retire(id, backingOff: false, now: now)
        }
    }

    /// The wall clock was set (`NSSystemClockDidChange`): the slot turn, the reader's window and every wall-clock wait are
    /// read again now, so a clock set back below the slot on the air rotates at once. Answers what the links did meanwhile.
    public func wallClockChanged() -> [Event] {
        advance()
    }

    // MARK: MeshTransport

    /// Our current presence key, or `nil`: held at once for the next tag, while the step that may rotate for it waits for
    /// the next advance, since the engine may hand it in inside a store unit, where a mark write answers `insideUnit`.
    public func ownPresenceKeyChanged(_ key: OwnPresenceKey?) {
        blindWriter.ownKey = key
        blindWriter.keyChangeDue = true
    }

    /// The engine's readers of our presence keys, handed once.
    public func attachPresenceKeys(_ source: PresenceKeySource) {
        blindWriter.source = source
    }

    // MARK: The snapshot

    /// The listener is open on `psm`: a bring-up when nothing is on the air, which rotates to a tag while blinding (each
    /// bring-up is a rotation) and puts the clear form up otherwise; the same forms on the new PSM when they are up.
    func listening(on psm: UInt16) {
        guard running else {
            return
        }
        guard !blindWriter.writer.isUp else {
            blindWriter.writer.repoint(psm: psm)
            advertiseNow()
            return
        }
        let blinding = blinds
        blindWriter.writer.up(pendingTag: blinding)
        guard !blinding else {
            rotate(.bringUp, announced: false, psm: psm)
            return
        }
        blindWriter.writer.install(form: .clear(localId), previous: nil, psm: psm)
        noteInstall(.bringUp, choice: nil)
        aliases.setOwnTags(current: nil, previous: nil)
        blindWriter.rotation.onStopped()
        blindWriter.airedGeneration = nil
        advertiseNow()
    }

    /// The radio went down (a stop, Bluetooth off): nothing is on the air, no reservation outlives it, and no form is owed.
    func writerDown() {
        blindWriter.writer.down()
        blindWriter.schedule.dropReservations()
        blindWriter.rotation.onStopped()
        blindWriter.announcedTag = nil
        blindWriter.sends.clear()
        blindWriter.notes.clear()
    }

    /// Our advertised forms, from the snapshot: clear before the first.
    var mine: AdvertOrder.Mine {
        blindWriter.writer.aired.map { AdvertOrder.Mine(current: $0.form, previous: $0.previous) } ?? .clear(localId)
    }

    /// Whether a tag is on the air with nothing pending, so a key change or a forced rotation may rotate it now.
    var airsTag: Bool {
        let writer = blindWriter.writer
        return writer.isUp && !writer.pending && writer.aired?.form.blinded == true
    }

    /// The payload a push hands the radio for `aired`: its form and PSM, its flags (`FLAG_LINK_SEAL` in either form, the
    /// `link-seal` contract, §1), and while blinded a zero cue.
    func payload(of aired: AdvertWriter.Aired) -> AdvertPayload {
        let blinded = aired.form.blinded
        return AdvertPayload(
            capabilities: .local,
            advertised: aired.form.advertised,
            digestCue: blinded ? 0 : digestCue,
            psm: aired.psm,
            flags: AdvertPayload.writtenFlags(dialsGattPeers: radio.dialsGattPeers, blinded: blinded, seals: advertisesSeal)
        )
    }

    // MARK: Rotation

    /// One rotation to the wanted form, never held: the tag (``TagChoice``, a slotted or announced one, or a random one,
    /// never the id) or the clear form when not blinding, installed as one snapshot with the form it replaces, then pushed.
    /// A tag nobody was told of goes once to each link. The radio is up on `psm` whenever this runs: a bring-up, a turn, a key
    /// change or a flip on a snapshot that is up.
    func rotate(_ cause: AdvertRotation.Cause, announced: Bool, psm: UInt16) {
        blindWriter.writer.begin()
        let wall = clock.wallMilliseconds()
        let old = blindWriter.writer.aired?.form
        let choice = blindingSource.map { chooseTag($0, announced: announced, wall: wall) }
        let form = choice?.form ?? .clear(localId)
        let previous = old == form ? nil : old
        blindWriter.writer.install(form: form, previous: previous, psm: psm)
        noteInstall(cause, choice: choice)
        if cause == .bringUp, form.blinded {
            blindWriter.bringUps.count(slot: BlindTag.slotOf(wallMilliseconds: wall))
        }
        aliases.setOwnTags(current: form.blinded ? form.advertised : nil, previous: previous.flatMap { $0.blinded ? $0.advertised : nil })
        blindWriter.airedGeneration = choice?.generation
        if form.blinded {
            blindWriter.rotation.onRotated(wall: wall)
        } else {
            blindWriter.rotation.onStopped()
        }
        blindWriter.announcedTag = nil
        blindWriter.counts.rotated(cause)
        advertiseNow()
        if choice?.source != .announced, form.blinded {
            blindWriter.counts.unannounced += 1
            for link in liveLinks {
                sendForm(to: link, .current, tag: form.advertised, wall: wall)
            }
        }
    }

    /// The tag a rotation airs while blinding, counted, and one pass asked per generation on a stale mark.
    func chooseTag(_ source: PresenceKeySource, announced: Bool, wall: Int64) -> TagChoice.Choice {
        let held = blindWriter.ownKey
        let live = source.ownKey()
        var schedule = blindWriter.schedule
        let choice = TagChoice.choose(
            &schedule,
            held: held,
            live: live,
            announced: announced,
            wall: wall,
            marks: SourceMarks(source: source),
            using: &random
        )
        blindWriter.schedule = schedule
        blindWriter.counts.chose(choice)
        if let generation = choice.generation, blindWriter.staleLatch.offer(generation, stale: choice.stale) {
            blindWriter.counts.staleMarkPasses += 1
            source.askMarkPass(generation)
        }
        return choice
    }

    /// A key change, taken at the advance after it came in: every reservation goes, and a change of the generation on the
    /// air rotates at once, never held (`onOwnKeyChanged`, `BluetoothMeshTransport.kt:1719-1729`).
    func takeKeyChange() {
        guard blindWriter.keyChangeDue else {
            return
        }
        blindWriter.keyChangeDue = false
        let key = blindWriter.ownKey
        let held = blindWriter.stepKey
        blindWriter.stepKey = key
        guard key != held else {
            return
        }
        blindWriter.schedule.dropReservations()
        blindWriter.rotation.dropAnnouncement()
        blindWriter.announcedTag = nil
        let cause = AdvertRotation.causeOfKeyChange(
            held: held, incoming: key, airedGeneration: blindWriter.airedGeneration, sessionHadKey: blindWriter.sessionHadKey)
        if key != nil {
            blindWriter.sessionHadKey = true
        }
        if let cause, airsTag, let aired = blindWriter.writer.aired {
            rotate(cause, announced: false, psm: aired.psm)
        }
    }

    // MARK: The turn

    /// When the turn next has work, on the monotonic clock, or `nil` while nothing blinded is on the air.
    func turnDue(now: Int64, wall: Int64) -> Int64? {
        guard blinds else {
            return nil
        }
        switch blindWriter.rotation.next(wall: wall) {
        case .wait(let at):
            return at.map { now + max(1, $0 - wall) }
        case .announce, .rotate:
            return now
        }
    }

    /// Runs the turn's step due now: the announcement at the lead, or the rotation at or past the edge. A rotation late in a
    /// slot may find the next announcement due at once; the deadline it leaves (``turnDue(now:wall:)``) is now, so the timer
    /// runs it next.
    func advanceTurn() {
        guard let source = blindingSource else {
            return
        }
        let wall = clock.wallMilliseconds()
        switch blindWriter.rotation.next(wall: wall) {
        case .wait:
            break
        case .announce:
            announce(source, wall: wall)
        case .rotate(let announced):
            if let aired = blindWriter.writer.aired {
                rotate(.slot, announced: announced, psm: aired.psm)
            }
        }
    }

    /// The slot turn's announcement: the coming slot's tag reserved under the key held, and sent to each link while it
    /// stands. With no key, or a mark that would not write, nothing is announced, and the rotation airs a tag unannounced;
    /// the turn counts the announcement made either way, so it is never asked again at once.
    func announce(_ source: PresenceKeySource, wall: Int64) {
        defer {
            blindWriter.rotation.onAnnounced(wall: wall)
        }
        guard let key = blindWriter.ownKey else {
            return
        }
        var schedule = blindWriter.schedule
        let reserved = try? schedule.reserve(key: key, wall: wall, marks: SourceMarks(source: source), using: &random)
        blindWriter.schedule = schedule
        guard let next = reserved, next.resolvable else {
            return
        }
        blindWriter.announcedTag = next.tag
        for link in liveLinks {
            sendForm(to: link, .announce, tag: next.tag, wall: wall)
        }
    }
}
