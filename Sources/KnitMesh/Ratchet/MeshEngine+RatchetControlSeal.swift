import KnitCrypto
import KnitStore
import KnitWire

/// One ctl DM of ours sealed with the ratchet, with the switch on: what our receipts and ticks (phase P5d), our DM
/// reactions, our sealed profile and the answer an init is owed (phase P5e) all go through, as Kotlin's `sealDmReceipt`,
/// `sealDeliveryTickEnvelope`, `sealDmReaction` and `sendCtlDm` all go through `ratchet.sealDm` (`InboundPipeline.kt:2904-2948`,
/// `MeshManager.kt:1868-1905`, `:2249-2276`, `:2916-2951`, at knit-next `cbf2a487`).
///
/// **The unit.** Each seal stands in a store unit of its own, the outermost: the peer's row is read inside it, the frame id
/// and the clock are drawn once that read is done, as Kotlin draws them after its read, the facade's `sealDm` joins it, and
/// the frame is signed once inside it and, when originated, taken into our custody inside it, as the send unit does
/// (``sendRatchet(_:to:_:purpose:riders:)``). Nothing leaves before that unit commits: the seal's settlement, the router's
/// mark and the flood all wait for ``originateSealed(_:)``. A seal asked for inside a unit its caller opened joins that
/// unit instead, and what it leaves behind stands or falls with it (``ControlSealing/joined``).
///
/// **Never v1.** A plan of `nil`, the peer cannot read one, and a facade that cannot seal (no session and no usable prekey,
/// a new epoch due with no base, a key X25519 refuses) abandon the unit, and each caller then sends its ctl's cleartext
/// form or nothing: a v1 ctl frame is an empty bubble on a build without the ratchet (`InboundPipeline.kt:2898-2900`,
/// `MeshManager.kt:2207-2209`).
extension MeshEngine {
    /// `content`, a ctl, sealed to `peer` in a store unit of its own, as the plan `readPlan` answers inside it says, in
    /// `frame` (``ControlFrame``): under a fresh frame id drawn once the plan is read, dated by the frame's stamp or by our
    /// clock's now, the facade's seal joined to the unit at our clock's now, signed once with the frame's `relay`, and an
    /// originated one taken into our custody, all inside it (`sealDeliveryTickEnvelope`, `MeshManager.kt:1868-1905`;
    /// `sendCtlDm`, `:2922-2949`). A signature that fails abandons the unit.
    func sealControl(
        _ content: MessageContent, to peer: NodeId, in frame: ControlFrame, plan readPlan: () -> RatchetOutbound.ReceiptPlan?
    ) -> ControlSealing {
        var readable = false
        let unit = stores.transactor.atomically { () -> SealedControl? in
            guard let plan = readPlan() else {
                return nil
            }
            readable = true
            // The id and the clock after the read and before the seal, as Kotlin draws them (`:1876-1878`, `:2925-2926`):
            // the AAD names both. A reaction's stamp is its row's, the one last writer wins compares (`:2186-2188`).
            let id = newFrameId()
            let now = clock.wallMilliseconds()
            let stamp = frame.sentAt ?? now
            let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: stamp, thread: peer.string)
            let bytes = content.sealBytes(v3: plan.readsCryptoV3)
            let sealing = ratchet.sealDm(
                to: plan.bundle,
                prekey: plan.prekey,
                plaintext: bytes.plaintext,
                aad: aad,
                now: now,
                v3: bytes.scheme == EncEnvelope.Version.compactRatchet
            )
            // Joined is the one answer a seal inside our unit gives that may go, once our unit commits. The facade's
            // `unavailable` and `refusedKey` abandon it, and a store that failed has failed it already.
            guard case .joined(.sealed(let enc), let settlement) = sealing else {
                return nil
            }
            let chat = ChatContent(attachmentHash: frame.attachmentHash, enc: enc)
            let envelope = chatEnvelope(id: id, sentAt: stamp, recipient: peer, group: nil, content: chat)
            return sign(envelope, relay: frame.relay).map { wire in
                // Custody keeps the first bytes stored under an id, and this id is fresh.
                let carried =
                    frame.relay
                    && custody.carryOwn(CarriedFrame(envelope: envelope, sig: wire.sig, signed: wire.signed), in: stores.custody, now: now)
                return SealedControl(frame: SignedFrame(wire: wire, envelope: envelope), settlement: settlement, carried: carried)
            }
        }
        switch unit {
        case .committed(let sealed):
            return .sealed(sealed)
        case .joined:
            return .joined
        case .failed:
            return .failed
        case .abandoned:
            return readable ? .unsealable : .unreadable
        }
    }

    /// After an originated ctl's unit committed: the floors its seal settles move, and it goes on the air at once to every
    /// neighbour, marked seen so its echo is ignored (`originateSigned`, `MeshManager.kt:3032-3062`, custody first).
    func originateSealed(_ sealed: SealedControl) {
        ratchet.settle(sealed.settlement)
        router.markOwn(sealed.frame.envelope.id, now: clock.monotonicMilliseconds())
        transport.send(sealed.frame.wire, to: nil)
        if sealed.carried {
            noteCustodyChanged()
        }
    }
}

/// The frame a ctl's seal goes out in (``MeshEngine/sealControl(_:to:in:plan:)``): originated (`relay`), so flooded and carried
/// in our custody, or for a live link alone; dated by `sentAt`, or by our clock's now when it names none; and with
/// `attachmentHash` beside the seal in the clear, the hash alone (knit-next ADR 035), or nothing.
internal struct ControlFrame {
    /// Whether it is originated: signed `relay = true`, carried in our custody inside the seal's unit, and flooded.
    let relay: Bool
    /// The stamp it is dated by, which the AAD names, or `nil` for our clock's now, drawn inside the unit.
    let sentAt: Int64?
    /// The hash that rides beside the seal in the clear, or `nil`.
    let attachmentHash: String?

    /// A receipt's or a tick's (phase P5d): dated now, with nothing beside the seal.
    static func receipt(relay: Bool) -> Self {
        Self(relay: relay, sentAt: nil, attachmentHash: nil)
    }

    /// A reaction's (phase P5e): originated, and dated by its row's `stamp`, which last writer wins compares on both phones.
    static func reaction(at stamp: Int64) -> Self {
        Self(relay: true, sentAt: stamp, attachmentHash: nil)
    }

    /// Our sealed profile's (phase P5e): originated, dated now, with our `photo`'s hash beside the seal, so a carrier that
    /// cannot read the frame can still pull the photo (`MeshManager.kt:2901-2911`).
    static func profile(photo: BlobHash?) -> Self {
        Self(relay: true, sentAt: nil, attachmentHash: photo?.string)
    }
}

/// What one ctl's seal came to (``MeshEngine/sealControl(_:to:in:plan:)``).
internal enum ControlSealing {
    /// The unit committed: the frame is signed and, when originated, carried.
    case sealed(SealedControl)
    /// The plan said the peer cannot read one: nothing was sealed.
    case unreadable
    /// The facade could not seal toward a peer who could read one, or the signature failed: nothing was written.
    case unsealable
    /// The seal joined a unit its caller opened, and what it wrote stays in that unit: the chain's advance and, for an
    /// originated frame, its custody row. If that unit commits, an originated frame stands in our custody unflooded and
    /// unmarked, and the next custody exchange serves it, so it reaches the peer after all. A live-link tick, never
    /// carried, leaves only the advance. No key is used twice, since the advance commits with the frame. Nothing opens a
    /// unit around these calls today, and the standing rule for P6 keeps `acknowledge` out of one.
    case joined
    /// A store failed, a read's or a write's: everything the unit wrote is undone.
    case failed
}

/// A ctl sealed inside its unit, and what the seal leaves for after the commit.
internal struct SealedControl {
    /// The frame as signed.
    let frame: SignedFrame
    /// The floors the joined seal moves once the unit commits.
    let settlement: RatchetSessions.Settlement
    /// Whether our custody stored it just now: an originated one, which is fresh.
    let carried: Bool
}
