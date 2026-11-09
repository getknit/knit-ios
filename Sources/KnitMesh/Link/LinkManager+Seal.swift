import KnitCrypto
import KnitWire

/// The sealed link (the `link-seal` contract; knit-next #286, option 1; knit-ios #51 and #39).
///
/// A dial whose advert carries `FLAG_LINK_SEAL` (``DialTarget/seals``) opens with our `KEY_SHARE`, an ephemeral X25519 key,
/// and writes nothing else until the responder's comes back. A responder that reads a `KEY_SHARE` first writes its own at
/// once, before any admission decision. From the two each side derives a key per direction (``LinkSeal``), and every
/// byte after the `KEY_SHARE`s rides `SEALED` frames: the radio's outbox seals what we write
/// (``Radio/seal(_:with:)``), and the channel opens what we read (``SealedReads``). Inside, the HELLO and PROOF exchange
/// runs as on a plain link, but both HELLOs must carry ``Capabilities/linkProof``, ``Capabilities/linkSeal`` and a nonce,
/// and the PROOF signs both `KEY_SHARE`s (``LinkProof/Form/sealed(_:)``), so a sealed link is always a proven one and a
/// relay can neither read it nor sit in its middle.
///
/// A failed seal is bytes that arrived and were wrong (§4, revision 1): a framing error on a sealed channel or where the
/// responder's `KEY_SHARE` belongs, another record there, a share the exchange refuses, any record but a frame after the
/// exchange, a frame that fails to open, an inner `KEY_SHARE` or frame, a first inner record that is not a HELLO, or a
/// sealed HELLO without both bits and a nonce. It is counted (``linkSealFailed``), logged once as `link chN seal failed for
/// <shown>: <why>`, and closes the link, backing off a dialer and a live link's peer. An end of stream or a timeout is never
/// one, at any stage: it is the no-reply refusal it was before the seal.
///
/// A plain link whose two HELLOs both carry ``Capabilities/linkSeal`` is refused (§7): the advert's flag is unauthenticated,
/// and the PROOF covers the HELLO's bit, so a relay that strips the flag and leaves the HELLOs alone gets no link rather
/// than a plain one. The guarantee is scoped (revision 3): no downgrade between phones that hold each other's profile, or
/// proved each other this session, where R1 refuses an unproven claim. At a first meeting a relay that also rewrites both
/// HELLOs as v2.10.x's (no proof's bit, no seal's, no nonce) poses as an old build to both, and the link comes up plain
/// and unproven until R4 closes it once a profile crosses.
extension LinkManager {
    /// The seal's three counts, one name each on both platforms (the `link-seal` contract, §9). No count carries a key,
    /// a nonce or plaintext.
    struct SealCounts {
        var linksSealed = 0
        var linkSealFailed = 0
        var linkSealRefused = 0
    }

    /// Links registered after a sealed exchange (`linksSealed`). Each counts in ``linksProven`` too, since a sealed link
    /// always proves.
    public var linksSealed: Int { sealCounts.linksSealed }
    /// Failed seals (`linkSealFailed`): bytes that arrived on a sealed channel, or where a `KEY_SHARE` belongs, and were
    /// wrong, during the handshake or on a live link. Never an end of stream or a timeout. The side that found it counts it.
    public var linkSealFailed: Int { sealCounts.linkSealFailed }
    /// Plain links refused because both HELLOs carry ``Capabilities/linkSeal`` (`linkSealRefused`, §7). The side that
    /// refused counts it.
    public var linkSealRefused: Int { sealCounts.linkSealRefused }

    /// knit-peer's seal switches, a trial's, which the app never sets (the `link-seal` contract's T5 and T6): what a
    /// build that does not seal, or a node that lies about sealing, puts on the wire, so a phone's refusals and failed
    /// seals can be watched on air.
    public enum SealSwitch: String, Sendable, Equatable, CaseIterable {
        /// Honest: the flag in the advert, the bit in the HELLO, a sealed dial when the advert dialed carries the flag.
        case on = "on"
        /// Shaped like Android v2.11.0: no flag and no bit, every dial plain, and a `KEY_SHARE` closes the link as an
        /// unknown tag does there.
        case off = "off"
        /// The flag stripped from our advert and the bit kept in our HELLO: every dial plain, a plain dial answered with
        /// a reply that claims the bit, and our own refusal of a plain link between sealing builds off, so the far end's
        /// is the one that runs (T6).
        case downgrade = "downgrade"
        /// A `KEY_SHARE` answered with a plain HELLO claiming the bit, so the dialer reads a HELLO where the responder's
        /// `KEY_SHARE` belongs (T6). Otherwise honest.
        case plainReply = "plain-reply"

        /// Whether our HELLO carries ``Capabilities/linkSeal``.
        var claimsBit: Bool { self != .off }
        /// Whether our advert carries `FLAG_LINK_SEAL`, as long as the HELLO carries the bit.
        var advertisesFlag: Bool { self == .on || self == .plainReply }
        /// Whether a dial to an advert carrying the flag opens sealed.
        var dialsSealed: Bool { self == .on || self == .plainReply }
        /// Whether a `KEY_SHARE` from a dialer is answered with ours.
        var answersSealed: Bool { self == .on || self == .downgrade }
        /// Whether the responder refuses a plain link between sealing builds before replying (§7).
        var refusesPlainAsResponder: Bool { self != .downgrade }
    }

    /// Whether this manager opens a dial to a sealing advert sealed: always, but for knit-peer's legacy impostor and the
    /// seal switches that dial plain.
    var dialsSealed: Bool { provesLinks && sealSwitch.dialsSealed }

    /// Whether the HELLO this manager writes carries ``Capabilities/linkSeal``, so a plain link with a peer whose HELLO
    /// carries it too is refused (§7).
    var claimsSeal: Bool { helloCapabilities().contains(.linkSeal) }

    /// Whether our advert carries `FLAG_LINK_SEAL`: exactly when our HELLO carries the bit, unless a seal switch strips
    /// the flag alone (the `link-seal` contract, §1).
    var advertisesSeal: Bool { claimsSeal && sealSwitch.advertisesFlag }

    // MARK: The dialer

    /// Our sealed dial opened: writes our `KEY_SHARE`, which holds everything behind it on the radio until the sealer
    /// comes (``Radio/writeKeyShare(_:sealer:to:)``), and waits for the responder's (§4, step 1).
    func openSealed(_ id: ChannelID, now: Int64) {
        let ephemeral = makeEphemeral()
        guard let record = LinkRecord(.keyShare, payload: ephemeral.keyShare).encoded else {
            return
        }
        channels[id]?.ephemeral = ephemeral
        radio.writeKeyShare(record, sealer: nil, to: id)
        enterStage(.awaitingKeyShare, on: id, now: now)
    }

    /// The record where the responder's `KEY_SHARE` belongs (§4, step 3). Anything else there, or a share the exchange
    /// refuses, fails the seal. Once derived, the sealer goes to the radio before our HELLO, which is the first record
    /// sealed, and the channel waits for the reply as a plain dial does.
    func keyShareArrived(_ record: LinkRecord, on id: ChannelID, now: Int64) -> [Event] {
        guard record.tag == .keyShare else {
            return sealFailed(on: id, why: "\(record.tag) where the key share belongs", now: now)
        }
        guard let ephemeral = channels[id]?.ephemeral else {
            return sealFailed(on: id, why: "no key of ours", now: now)
        }
        channels[id]?.ephemeral = nil
        let session: LinkSeal.Session
        do {
            session = try LinkSeal.derive(ephemeral, peerShare: record.payload, role: .dialer)
        } catch {
            return sealFailed(on: id, why: error.rawValue, now: now)
        }
        channels[id]?.seal = SealedReads(shares: session.shares, opener: session.opener)
        radio.seal(id, with: session.sealer)
        writeHello(on: id)
        enterStage(.awaitingHello, on: id, now: now)
        return []
    }

    // MARK: The responder

    /// A dialer's first record is a `KEY_SHARE` (§4, step 2): ours goes back at once, with the sealer in the same radio
    /// call, before any admission decision, and the channel waits for a sealed HELLO with a fresh deadline and put-off.
    /// A refusal from here closes without a reply HELLO, as on a plain link. A build that does not seal closes the link as
    /// an unknown tag would, counting nothing; knit-peer's `plain-reply` answers with a plain HELLO instead.
    func answerKeyShare(_ record: LinkRecord, on id: ChannelID, now: Int64) -> [Event] {
        if provesLinks, sealSwitch == .plainReply {
            log.log(.info, "link \(id) answers a key share with a plain HELLO, for a trial (plain-reply)")
            writeHello(on: id)
            return []
        }
        guard provesLinks, sealSwitch.answersSealed else {
            return strayRecord(record, on: id, now: now)
        }
        let ephemeral = makeEphemeral()
        let session: LinkSeal.Session
        do {
            session = try LinkSeal.derive(ephemeral, peerShare: record.payload, role: .responder)
        } catch {
            return sealFailed(on: id, why: error.rawValue, now: now)
        }
        guard let ours = LinkRecord(.keyShare, payload: ephemeral.keyShare).encoded else {
            return sealFailed(on: id, why: "no key share of ours", now: now)
        }
        channels[id]?.seal = SealedReads(shares: session.shares, opener: session.opener)
        radio.writeKeyShare(ours, sealer: session.sealer, to: id)
        enterStage(.awaitingHello, on: id, now: now)
        return []
    }

    /// Whether `error` is a dialer's first record framed as a `KEY_SHARE` of the wrong length, on a responder that answers
    /// the sealed form: a failed seal, counted, as Android counts one (§4: "a `KEY_SHARE` of the wrong length"), not only a
    /// bad record. A build that does not seal reads it as the bad record it is there.
    func opensWithBadKeyShare(_ error: LinkRecordError, role: Role, stage: Stage) -> Bool {
        guard case .badLength(let tag, _) = error, tag == LinkRecord.Tag.keyShare.rawValue else {
            return false
        }
        return role == .responder && stage == .awaitingHello && provesLinks && sealSwitch.answersSealed
    }

    // MARK: Reading a sealed channel

    /// One record off a sealed channel: it must be a frame that opens at the next counter, and its plaintext goes to the
    /// inner reader, whose records drive the stages as a plain link's do.
    func openFrame(_ record: LinkRecord, on id: ChannelID, now: Int64) -> [Event] {
        guard record.tag == .sealed else {
            return sealFailed(on: id, why: "\(record.tag) where a frame belongs", now: now)
        }
        guard let plaintext = channels[id]?.seal?.opener.open(sealedPayload: record.payload) else {
            return sealFailed(on: id, why: "a frame of \(record.payload.count) bytes did not open", now: now)
        }
        channels[id]?.seal?.inner.append(plaintext)
        return readInner(on: id, now: now)
    }

    /// Drains the inner reader's whole records, each handled at the stage the one before left. A framing error inside,
    /// a `KEY_SHARE` or a frame inside, or a first record that is not a sealed HELLO with both bits and a nonce fails the
    /// seal; the log names the tag, the sizes and the position, never a byte of plaintext.
    func readInner(on id: ChannelID, now: Int64) -> [Event] {
        var events: [Event] = []
        while let (role, stage) = channels[id].map({ ($0.role, $0.stage) }), channels[id]?.seal != nil {
            let record: LinkRecord?
            do {
                record = try channels[id]?.seal?.inner.next()
            } catch {
                let at = channels[id]?.seal?.inner.consumed ?? 0
                return events + sealFailed(on: id, why: "inner record \(error) at byte \(at)", now: now)
            }
            guard let record else {
                break
            }
            if record.tag == .keyShare || record.tag == .sealed {
                return events + sealFailed(on: id, why: "inner \(record.tag)", now: now)
            }
            switch stage {
            case .connecting, .awaitingKeyShare:
                // No channel holds a seal before its exchange.
                return events + sealFailed(on: id, why: "inner \(record.tag) before the exchange", now: now)
            case .awaitingHello:
                if let why = Self.sealedHelloFailure(record) {
                    return events + sealFailed(on: id, why: why, now: now)
                }
                events += handleHello(record, on: id, role: role, now: now)
            case .awaitingProof(let pending):
                events += handleProof(record, pending, on: id, role: role, now: now)
            case .live(let peer):
                events += dispatch(record, from: peer, on: id, now: now)
            }
        }
        return events
    }

    /// Why `record`, the first record inside the seal, is not a sealed HELLO: it must be a HELLO carrying
    /// ``Capabilities/linkProof``, ``Capabilities/linkSeal`` and a valid nonce (§4, step 4), or `nil` when it is. Checked
    /// before any claim or admission rule, so a missing nonce counts a failed seal, never a failed proof.
    static func sealedHelloFailure(_ record: LinkRecord) -> String? {
        guard record.tag == .hello else {
            return "the first inner record is \(record.tag)"
        }
        let hello = Hello(payload: record.payload)
        let lacking = [
            hello.capabilities.contains(.linkProof) ? nil : "the proof's bit",
            hello.capabilities.contains(.linkSeal) ? nil : "the seal's bit",
            hello.nonce == nil ? "a nonce" : nil,
        ].compactMap(\.self)
        return lacking.isEmpty ? nil : "a sealed HELLO without \(lacking.joined(separator: ", "))"
    }

    // MARK: Failures and refusals

    /// Counts and logs a failed seal on `id`, and closes it: a dialer backs off as for a failed HELLO, a responder does
    /// not, and a live link goes down as a bad record takes it, its cut attachment dropped since its bytes are suspect.
    /// Never a key, a nonce or a byte of plaintext in the line.
    func sealFailed(on id: ChannelID, why: String, now: Int64) -> [Event] {
        guard let channel = channels[id] else {
            return []
        }
        sealCounts.linkSealFailed += 1
        let shown: String
        switch (channel.role, channel.stage) {
        case (_, .live(let peer)):
            shown = peer.string
        case (.dialer(let target), _):
            shown = target.shown
        case (.responder, .awaitingProof(let pending)):
            shown = pending.peer.string
        case (.responder, _):
            // No id yet: one word, so a harness reading `seal failed for \S+` still matches.
            shown = "(dialer)"
        }
        log.log(.info, "link \(id) seal failed for \(shown): \(why)")
        if case .live = channel.stage {
            return retire(id, backingOff: true, keepingCut: false, now: now) + promote(now: now)
        }
        let dialed = channel.role != .responder
        return retire(id, backingOff: dialed, keepingCut: false, now: now) + (dialed ? promote(now: now) : [])
    }

    /// A `KEY_SHARE` or a frame on a plain link, or anywhere a plain stage reads one: the link drops as for a bad record,
    /// as every build before the seal drops it on the unknown tag. Knowing the tags loosens nothing (§3).
    func strayRecord(_ record: LinkRecord, on id: ChannelID, now: Int64) -> [Event] {
        guard let channel = channels[id] else {
            return []
        }
        log.log(.warning, "link \(id) sent a bad record: \(record.tag) of \(record.payload.count) bytes on a plain link")
        if case .awaitingProof(let pending) = channel.stage {
            proofFailed(on: id, for: pending.peer, why: "record")
        }
        return retire(id, backingOff: true, keepingCut: false, now: now) + promote(now: now)
    }

    /// Whether a plain link is refused because both HELLOs carry ``Capabilities/linkSeal`` (§7): `ours` as written, or as
    /// we would write it, and `theirs`. Never on a sealed channel.
    func refusesPlainLink(_ id: ChannelID, ours: Bool, theirs: Hello) -> Bool {
        channels[id]?.seal == nil && ours && theirs.capabilities.contains(.linkSeal)
    }

    /// Counts and logs a plain link refused under §7, claiming `claimed`, and closes it: a responder before its reply,
    /// a dialer before its PROOF, backing off.
    func sealRefused(_ id: ChannelID, claiming claimed: String, backingOff: Bool, now: Int64) -> [Event] {
        sealCounts.linkSealRefused += 1
        log.log(.info, "link refused \(claimed): a plain link between two sealing builds")
        return retire(id, backingOff: backingOff, now: now) + (backingOff ? promote(now: now) : [])
    }

    /// Our plain dial on `id`, its HELLO carrying ``Capabilities/linkSeal``, is ending with no reply, the far end closed or
    /// its deadline passed: the radio may forget the GATT payload it dialed from, once (``Radio/dialGotNoReply(at:)``;
    /// §7, revision 1). A sealed dial never asks (revision 2), nor a dial that got a reply.
    func noteNoReply(on id: ChannelID) {
        guard let channel = channels[id], case .dialer(let target) = channel.role, !target.seals, channel.seal == nil,
            channel.stage == .awaitingHello, let ours = channel.wroteHello,
            Hello(payload: ours).capabilities.contains(.linkSeal)
        else {
            return
        }
        radio.dialGotNoReply(at: target.address)
    }

    /// Moves `id` to `stage` with that stage's own deadline and put-off.
    func enterStage(_ stage: Stage, on id: ChannelID, now: Int64) {
        channels[id]?.stage = stage
        channels[id]?.deadline = now + configuration.helloTimeoutMilliseconds
        channels[id]?.putOff = false
    }
}
