import KnitCrypto
import KnitWire

/// The blinded advert as a debug build's bridge reports it (`advert`; ADR 2026-11.prsp, "The bridge and the harness"), the
/// shape of Android's `AdvertStatus` (`AdvertDiag.kt` at knit-next `cad69c77b`): the gates, the form on the air, the turn, the
/// restarts left, every sighting's order and every link's form, and the writer's counts. Read in one call on the `Mesh` actor.
///
/// **What it carries.** A debug build is for development, so a reply may date a rotation and name a key generation (ADR
/// 2026-11.prsp accepts it). Never a key, and never a tag, its hex or a prefix of one past `zzzz`: a form is reported by its
/// kind, an unresolved sighting by its handle (``FormHandle``, a per-process counter), and nothing here copies a tag out.
/// Android's `holding` has no iPhone counterpart (the turn never holds, ``AdvertRotation``), so the reply has none.
public struct AdvertStatus: Sendable, Equatable {
    /// The kind of a form: the id, or a tag.
    public enum Kind: Sendable, Equatable {
        case clear
        case tag

        /// Its name in the reply.
        public var name: String {
            self == .tag ? "tag" : "clear"
        }
    }

    /// What the last install was.
    public struct Install: Sendable, Equatable {
        /// Why it ran: `slot`, `bringUp`, `keyChange`, `flip` or `forced`.
        public let cause: String
        /// When, on the wall clock.
        public let at: Int64
        /// Its tag's choice, `nil` for a clear install.
        public let tag: TagFacts?
    }

    /// Where an install's tag came from, never the tag.
    public struct TagFacts: Sendable, Equatable {
        /// `announced`, `slotted`, `noKey`, `keyMoved` or `markFailed`.
        public let source: String
        /// Whether a contact resolves it.
        public let resolvable: Bool
        /// Whether the mark was found stale.
        public let stale: Bool
    }

    /// One sighting.
    public struct Peer: Sendable, Equatable {
        /// Its node id, or its handle while unresolved: never a tag.
        public let peer: String
        /// Whether ``peer`` is a node id.
        public let resolved: Bool
        /// Whether it airs a tag.
        public let blinded: Bool
        /// Whether my current form dials its form by the order alone (``AdvertOrder/iDial(_:_:)``).
        public let iDial: Bool
        /// The node id of the live link this sighting is, or `nil` when unlinked.
        public let linkedAs: String?
    }

    /// One live link.
    public struct Link: Sendable, Equatable {
        /// The id its HELLO named.
        public let nodeId: String
        /// Whether it proved that id.
        public let proven: Bool
        /// Whether this node dialed it.
        public let dialedByMe: Bool
        /// Whether its HELLO carried ``Capabilities/blindAdvert``.
        public let tagAware: Bool
        /// The kind of the form its peer is known by (``LinkManager/BlindWriter/linkForms``), `nil` when none is known.
        public let knownBy: Kind?
    }

    /// The build gate (``LinkManager/Configuration/blindsAdvert``) and the runtime switch.
    public let gate: Bool
    public let switchOn: Bool
    /// Whether the writer blinds now: both gates, and the engine's readers attached.
    public let blinding: Bool
    /// The generation of the own key held, `nil` with none.
    public let keyGeneration: Int64?
    /// Whether the radio is up, and whether a rotation's tag is being chosen.
    public let radioUp: Bool
    public let pending: Bool
    /// The form on the air, `nil` before the first install.
    public let form: Kind?
    /// How many snapshots this process installed.
    public let epoch: Int
    /// The generation the aired tag was made under; `nil` for a random tag or the clear form.
    public let airedGeneration: Int64?
    /// The last install: every install records one, so it is the snapshot on the air's, or the radio went down under it.
    public let install: Install?
    /// The slot edge the tag on the air ends at, on the wall clock.
    public let nextEdgeAt: Int64?
    /// Whether the coming slot's tag is announced.
    public let announced: Bool
    /// The PSM the snapshot names.
    public let psm: UInt16?
    /// The restart indexes the held key has left in this slot, `nil` before its mark was read.
    public let restartsLeft: Int?
    /// Bring-up rotations to a tag in the current slot.
    public let bringUpsInSlot: Int
    /// The writer's counts.
    public let counters: LinkManager.WriterCounters
    /// Every sighting, and every live link.
    public let peers: [Peer]
    public let links: [Link]
}

/// The debug bridge's `advert-rotate` (Android's `ForcedRotation`, `AdvertDiag.kt` at `cad69c77b`): one unannounced rotation
/// now through the ordinary path (``AdvertRotation/Cause/forced``), refused with nothing rotated whenever an ordinary rotation
/// would not run now or would cost the plane something. Each one spends one of the slot's restart indexes durably, shared
/// with bring-ups: past them, every rotation in the slot airs a random tag no contact resolves until the edge. Android's
/// `pending`, `settling` and `holding` have no counterpart: the link manager chooses and installs a tag in one call, an iPhone
/// has no ACL settle to wait out, and the turn never holds.
public enum ForcedRotation {
    /// Why one was refused, as the reply names it.
    public enum Refusal: String, Sendable, Equatable {
        /// The radio is down.
        case radioDown = "radio down"
        /// Not blinding, or the clear form on the air.
        case clear = "clear"
        /// An announcement stands: an unannounced rotation would spend the reservation, and the peers told of it would apply
        /// a form never aired.
        case announced = "announced"
        /// A payload service's add is in flight on the radio, or the last install was under
        /// ``LinkManager/forcedRotationGraceMilliseconds`` ago: a loop of calls cannot pile adds onto the server.
        case grace = "grace"
        /// A live link was sent a form within the receiver's two-minute limit, so the rotation's send to it would be throttled.
        case throttled = "throttled"
    }

    /// What the bridge reports: whether it rotated, else why not, and the install counts before and after.
    public struct Result: Sendable, Equatable {
        public let refused: Refusal?
        public let epochBefore: Int
        public let epochAfter: Int

        /// Whether it rotated.
        public var rotated: Bool { refused == nil }
    }
}

/// How many times something happened in one slot: counted from 1 again in a new one.
internal struct SlotCount {
    private(set) var slot: Int64?
    private(set) var count = 0

    /// One more in `slot`.
    mutating func count(slot now: Int64) {
        count = slot == now ? count + 1 : 1
        slot = now
    }

    /// The count in `slot`, 0 for any other.
    func count(in now: Int64) -> Int {
        slot == now ? count : 0
    }
}

extension LinkManager {
    /// How long after an install a forced rotation is refused (``ForcedRotation/Refusal/grace``): a payload service's add is a
    /// `didAdd` round trip, milliseconds, so a few seconds keep a loop of calls from stacking adds on the server.
    public static let forcedRotationGraceMilliseconds: Int64 = 5000

    /// Records what an install was, with its cause and its tag's choice (`nil` for the clear form).
    func noteInstall(_ cause: AdvertRotation.Cause, choice: TagChoice.Choice?) {
        blindWriter.lastInstallAt = clock.monotonicMilliseconds()
        blindWriter.lastInstall = AdvertStatus.Install(
            cause: Self.name(of: cause),
            at: clock.wallMilliseconds(),
            tag: choice.map { AdvertStatus.TagFacts(source: Self.name(of: $0.source), resolvable: $0.resolvable, stale: $0.stale) }
        )
    }

    /// One unannounced rotation now, unless ``ForcedRotation/Refusal`` says why not: `radioSettling` is the radio's own word
    /// that a payload service's add is still in flight. Checked and run in one call, so nothing comes between.
    public func forceRotation(radioSettling: Bool = false) -> ForcedRotation.Result {
        let before = blindWriter.writer.installs
        let refusal = forcedRotationRefusal(radioSettling: radioSettling)
        if refusal == nil, let aired = blindWriter.writer.aired {
            rotate(.forced, announced: false, psm: aired.psm)
        }
        return ForcedRotation.Result(refused: refusal, epochBefore: before, epochAfter: blindWriter.writer.installs)
    }

    /// Why a forced rotation may not run now, in Android's order, or `nil`.
    private func forcedRotationRefusal(radioSettling: Bool) -> ForcedRotation.Refusal? {
        let writer = blindWriter.writer
        guard writer.isUp else {
            return .radioDown
        }
        guard blinds, writer.aired?.form.blinded == true else {
            return .clear
        }
        guard blindWriter.announcedTag == nil, !blindWriter.rotation.announced else {
            return .announced
        }
        let now = clock.monotonicMilliseconds()
        if radioSettling || blindWriter.lastInstallAt.map({ now - $0 < Self.forcedRotationGraceMilliseconds }) == true {
            return .grace
        }
        return blindWriter.sends.sentWithin(wall: clock.wallMilliseconds()) ? .throttled : nil
    }

    /// The advert now (``AdvertStatus``).
    public func advertStatus() -> AdvertStatus {
        let now = clock.monotonicMilliseconds()
        let wall = clock.wallMilliseconds()
        let writer = blindWriter.writer
        let aired = writer.aired
        let key = blindWriter.ownKey
        let links = liveLinks.map { link in
            let role = channels[link.channel]?.role
            return AdvertStatus.Link(
                nodeId: link.neighbor.nodeId.string,
                proven: link.proven,
                dialedByMe: role != nil && role != .responder,
                tagAware: link.neighbor.capabilities.contains(.blindAdvert),
                knownBy: blindWriter.linkForms[link.channel].map { $0.blinded ? .tag : .clear }
            )
        }
        let current = mine.current
        let peers = presence.snapshots(now: now).map { snapshot in
            let form = AdvertOrder.Form.of(snapshot.advert)
            return AdvertStatus.Peer(
                peer: snapshot.key.description,
                resolved: snapshot.key.nodeId != nil,
                blinded: form.blinded,
                iDial: AdvertOrder.iDial(current, form),
                linkedAs: linkedAs(snapshot.key, form: form)?.string
            )
        }
        return AdvertStatus(
            gate: configuration.blindsAdvert,
            switchOn: blindWriter.switchOn,
            blinding: blinds,
            keyGeneration: key?.generation,
            radioUp: writer.isUp,
            pending: writer.pending,
            form: aired.map { $0.form.blinded ? .tag : .clear },
            epoch: writer.installs,
            airedGeneration: blindWriter.airedGeneration,
            install: blindWriter.lastInstall,
            nextEdgeAt: blindWriter.rotation.nextEdge,
            announced: blindWriter.announcedTag != nil || blindWriter.rotation.announced,
            psm: aired?.psm,
            restartsLeft: key.flatMap { blindWriter.schedule.restartsLeft($0.generation, wall: wall) },
            bringUpsInSlot: blindWriter.bringUps.count(in: BlindTag.slotOf(wallMilliseconds: wall)),
            counters: writerCounters,
            peers: peers,
            links: links
        )
    }

    /// The live link a sighting is: under its own id, or for a handle the link whose peer is known by that tag (a stranger
    /// linked before it resolved).
    private func linkedAs(_ key: SightingKey, form: AdvertOrder.Form) -> NodeId? {
        if let node = key.nodeId {
            return liveLinks.first { $0.neighbor.nodeId == node }?.neighbor.nodeId
        }
        return liveLinks.first { blindWriter.linkForms[$0.channel] == form }?.neighbor.nodeId
    }

    /// A cause's name in the reply.
    static func name(of cause: AdvertRotation.Cause) -> String {
        switch cause {
        case .slot:
            "slot"
        case .bringUp:
            "bringUp"
        case .fresh:
            "keyChange"
        case .flip:
            "flip"
        case .forced:
            "forced"
        }
    }

    /// A tag source's name in the reply.
    static func name(of source: TagChoice.Source) -> String {
        switch source {
        case .announced:
            "announced"
        case .slotted:
            "slotted"
        case .noKey:
            "noKey"
        case .keyMoved:
            "keyMoved"
        case .markFailed:
            "markFailed"
        }
    }
}
