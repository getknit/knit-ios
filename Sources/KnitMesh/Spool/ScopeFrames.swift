import KnitCrypto
import KnitStore
import KnitWire

/// The member-side frame rules of a DM scope (`ScopeFrames`, knit-next `ScopeFrames.kt` at `0832b8462`, the DM half;
/// `docs/SPOOL_PROTOCOL.md` §4.4 and §9.2; ADR 2026-11.adrq): what may ride a scope, what this phone may push into one,
/// and how a blob a spool served becomes a frame the engine may judge. Pure, so every rule is a table test.
///
/// Node ids are compared by their bytes, as Kotlin's `==` compares code units (ADR 2026-09.jc2x): a scope's members are
/// canonical node ids, so an envelope naming anything else, a canonically equal spelling included, is no member.
internal enum ScopeFrames {
    /// How long a DM scope keeps a blob, the `ttlMs` this side declares at `sub` (`ScopeRegistry.DEFAULT_TTL_MS`,
    /// `ScopeRegistry.kt:292`): twice custody's day, the drain window of a replaced root.
    static let ttlMilliseconds: Int64 = 172_800_000
    /// The most blobs a DM scope keeps (`DEFAULT_MAX_FRAMES`, `:295`).
    static let maxFrames = 400
    /// The largest blob a DM scope takes (`DEFAULT_MAX_BLOB`, `:298`).
    static let maxBlob = SpoolRecordLayer.defaultMaxBlob
    /// The bounds every DM `sub` declares (`DEFAULT_BOUNDS`, `:300-301`).
    static let bounds = ScopeBounds(maxFrames: maxFrames, ttlMs: ttlMilliseconds, maxBlob: maxBlob)

    /// The cheap half of ``eligible(_:me:peer:)``, read from the envelope alone: no group, and a `profile` from either
    /// member or a `chat` between exactly the two. A seal cache filters custody with it before it decodes a payload.
    static func addressedWithin(_ envelope: RelayEnvelope, me: NodeId, peer: NodeId) -> Bool {
        guard envelope.group == nil else {
            return false
        }
        let sender = envelope.senderId.utf8
        if envelope.type == .profile {
            return sender.elementsEqual(me.string.utf8) || sender.elementsEqual(peer.string.utf8)
        }
        guard envelope.type == .chat, let recipient = envelope.recipientId?.utf8 else {
            return false
        }
        return (sender.elementsEqual(me.string.utf8) && recipient.elementsEqual(peer.string.utf8))
            || (sender.elementsEqual(peer.string.utf8) && recipient.elementsEqual(me.string.utf8))
    }

    /// The DM half of the §4.4 frame-set rule (`eligibleForDm`, `ScopeFrames.kt:256-271`), on push and on pull alike: a
    /// `profile` from either member, matched on the sender alone since a profile addresses nobody, or a `chat` between
    /// exactly the two whose payload is sealed v2 or v3 with the ratchet header `r`. The spec's C-4.4-7 says v2 alone;
    /// the Kotlin's `isDmRatchetVersion` takes v3 as well, and the Kotlin wins (knit/knit-next#339).
    static func eligible(_ envelope: RelayEnvelope, me: NodeId, peer: NodeId) -> Bool {
        guard addressedWithin(envelope, me: me, peer: peer) else {
            return false
        }
        if envelope.type == .profile {
            return true
        }
        guard let enc = (try? ChatContent(decoding: envelope.payload))?.enc else {
            return false
        }
        return RatchetInbound.isDirectRatchet(enc) && enc.ratchet != nil
    }

    /// The init ephemeral of `envelope` when it is our own session reset to `peer` (`ownResetInit`, `:148-158`): a DM
    /// `chat` from us to the peer whose cleartext ratchet header sets the reset flag and carries an init. `nil` for anything
    /// else, a flagged header with no init included.
    static func ownResetInit(_ envelope: RelayEnvelope, me: NodeId, peer: NodeId) -> [UInt8]? {
        let ours =
            envelope.senderId.utf8.elementsEqual(me.string.utf8) && envelope.recipientId?.utf8.elementsEqual(peer.string.utf8) == true
        guard ours, envelope.group == nil, envelope.type == .chat,
            let header = (try? ChatContent(decoding: envelope.payload))?.enc?.ratchet,
            header.flags & RatchetHeader.resetFlag != 0
        else {
            return nil
        }
        return header.initial?.eph
    }

    /// Whether a frame the rule admits may be pushed into `scope` (`mayRefill`, `:134-141`; C-3.1-3, C-3.1-5). Kotlin
    /// pushes our own reset only into a scope whose `resetInit` names it, and every scope's is `null` here (ADR
    /// 2026-11.adrq: the exception is deferred with the ratchet rules it needs), so our own flagged reset is pushed
    /// nowhere, into a live scope or a retiring one, and nothing else goes into a retiring one.
    static func mayRefill(_ envelope: RelayEnvelope, me: NodeId, scope: SpoolScope) -> Bool {
        guard ownResetInit(envelope, me: me, peer: scope.peer) == nil else {
            return false
        }
        return !scope.retiring
    }

    /// §9.2's outward guard (`deadOnArrival`, `:517-521`): the frame's own expiry in this scope, `sentAt + ttl`, is not
    /// after `now`. A sum past `Int64` is no expiry at all, so it is not dead here, where Kotlin's `Long` would wrap; the
    /// pull side calls such a frame ahead of the clock instead (``isLate(_:now:)``).
    static func deadOnArrival(_ envelope: RelayEnvelope, ttl: Int64, now: Int64) -> Bool {
        let (expiry, overflow) = envelope.sentAt.addingReportingOverflow(ttl)
        return !overflow && expiry <= now
    }

    /// Whether a pulled frame is past what a spool should still serve, judged by its own clock and never by when it came
    /// (P2's review; ADR 2026-11.adrq, amended): dead on arrival in a 48 h scope, or dated more than
    /// `WireProtocol.maxFutureSkewMilliseconds` ahead of `now`. Such a frame is delivered and accounted, never bridged onto
    /// the radios: a spool can serve a frame long after the router's ten-minute memory has let it go.
    static func isLate(_ envelope: RelayEnvelope, now: Int64) -> Bool {
        if deadOnArrival(envelope, ttl: ttlMilliseconds, now: now) {
            return true
        }
        let (limit, overflow) = now.addingReportingOverflow(WireProtocol.maxFutureSkewMilliseconds)
        return !overflow && envelope.sentAt > limit
    }

    /// Runs §4.4's ordered checks over a blob `scope` served (`open`, `:357-374`): the content address, the AEAD (which
    /// binds the seal version and the scope), the envelope's decode, the id's minted shape (C-4.4-14, `FrameId.admits`),
    /// then the frame-set rule. `nil` for any failure, which the heal loop quarantines when it pulled the blob and only
    /// releases when it came as an `event` (§9.3).
    ///
    /// The signature is not checked here, as in Kotlin, where `InboundPipeline.canCarry` runs between this and the bridge.
    /// What comes back is a ``ScopeCandidate`` that becomes a frame only through
    /// ``ScopeCandidate/verified(by:)``, against the claimed sender's key.
    static func open(
        _ arrival: SpoolArrival, in scope: SpoolScope, me: NodeId, source: ScopeCandidate.Source, now: Int64
    ) -> ScopeCandidate? {
        ScopeCandidate(opening: arrival, in: scope, me: me, source: source, now: now)
    }

    /// The custody frame `carried` sealed into `scope` (`seal`, `:336-343`), or `nil` for one that cannot be sealed: an
    /// unsigned frame, which no scope carries.
    static func seal(_ carried: CarriedFrame, into scope: SpoolScope) -> SealedBlob? {
        guard let sealed = ScopeCrypto.seal(scope.keys, sig: carried.sig, signed: carried.signed), let id = SpoolID(sealed.blobId) else {
            return nil
        }
        return SealedBlob(id: id, blob: sealed.blob)
    }
}

/// A custody frame sealed into a scope: the blob and its content address.
internal struct SealedBlob: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    let id: SpoolID
    let blob: [UInt8]

    var description: String { "\(id), \(blob.count) bytes" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A blob that passed ``ScopeFrames/open(_:in:me:source:now:)``: a frame that claims a sender and has not proved
/// it. Its bytes are private, so nothing can hand it to the engine before ``verified(by:)`` checks the signature against
/// the claimed sender's key, ours included (P3b's design pass).
///
/// The heal loop keeps the claim it took for it until the caller settles it (``ScopeHeal/settle(_:_:session:now:)``).
internal struct ScopeCandidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// How the blob came.
    enum Source: Sendable, Equatable {
        /// A `pull` of ours named it: a failure quarantines it (§9.3).
        case pulled
        /// A live `event`: a failure only releases its claim (C-9.3-4).
        case live
    }

    /// The scope it came from.
    let scope: SpoolID
    /// Its content address, checked against the bytes.
    let blobId: SpoolID
    let source: Source
    /// Who the envelope says signed it: one of the scope's two members, by the frame-set rule.
    let claimedSender: NodeId
    /// Whether it is past the scope's 48 h or more than five minutes ahead (``ScopeFrames/isLate(_:now:)``): delivered
    /// and accounted, never bridged.
    let isLate: Bool
    private let wire: WireEnvelope
    private let envelope: RelayEnvelope

    /// `arrival` opened under `scope`'s keys and held to the rule, in §4.4's order (``ScopeFrames/open(_:in:me:source:now:)``),
    /// or `nil`. The one way to make a candidate, so every candidate is a blob that opened.
    init?(opening arrival: SpoolArrival, in scope: SpoolScope, me: NodeId, source: Source, now: Int64) {
        guard let opened = ScopeCrypto.open(scope.keys, blobId: arrival.blobId.bytes, blob: arrival.data),
            let decoded = try? RelayEnvelope(decoding: opened.signed),
            FrameId.admits(decoded),
            ScopeFrames.eligible(decoded, me: me, peer: scope.peer),
            let sender = NodeId(decoded.senderId)
        else {
            return nil
        }
        self.scope = scope.id
        blobId = arrival.blobId
        self.source = source
        claimedSender = sender
        isLate = ScopeFrames.isLate(decoded, now: now)
        wire = WireEnvelope(sig: opened.sig, signed: opened.signed)
        envelope = decoded
    }

    /// The type the envelope claims, and its id and `signed` length: what the engine's oversize-profile door reads before
    /// it verifies anything (``MeshEngine/receiveFromSpool(_:relay:)``).
    var claimedType: FrameType { envelope.type }
    var frameId: String { envelope.id }
    var signedByteCount: Int { wire.signed.count }

    /// The frame, once its signature verifies against the key `pick` names for the envelope as served: the engine's
    /// `verifierBundle(for:)`, which reads the sender, the type and a profile's own key, and nothing that acts. `nil` when
    /// `pick` names none, or ``verified(by:)`` refuses.
    func verified(picking pick: (RelayEnvelope) -> PublicKeyBundle?) -> ScopeFrame? {
        pick(envelope).flatMap(verified(by:))
    }

    /// The frame, once its signature verifies over its bytes as served against `bundle`, which must derive to the claimed
    /// sender (`InboundPipeline.canCarry`'s check). The key is the engine's `verifierBundle`: ours for our own frame, the
    /// payload's own key for a profile, the pinned key otherwise; a candidate with no key is refused. `nil` for an unsigned
    /// frame, a key of another node, or a bad signature.
    func verified(by bundle: PublicKeyBundle) -> ScopeFrame? {
        guard bundle.nodeId == claimedSender, !wire.sig.isEmpty, bundle.isValidSignature(wire.sig, for: wire.signed) else {
            return nil
        }
        return ScopeFrame(wire: wire, envelope: envelope, isLate: isLate)
    }

    var description: String { "\(scope)/\(blobId)\(isLate ? ", late" : "")" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A frame a spool served whose signature verified: the re-serve shape (`ttl` 8, `hops` 0, flooded, §9.4) around the
/// verbatim bytes, its envelope, and whether it is late. P4 hands it to the engine as a `.spool` arrival, and relays it
/// onto the radios only when ``bridges``.
internal struct ScopeFrame: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let wire: WireEnvelope
    let envelope: RelayEnvelope
    let isLate: Bool

    /// Whether it may go onto the radios: a late frame is delivered here and never bridged (ADR 2026-11.adrq, amended).
    var bridges: Bool { !isLate }

    /// The frame as custody would carry it.
    var carried: CarriedFrame { CarriedFrame(envelope: envelope, sig: wire.sig, signed: wire.signed) }

    var description: String { "\(envelope.type.rawValue) frame, \(wire.signed.count) bytes\(isLate ? ", late" : "")" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
