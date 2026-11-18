import KnitCrypto
import KnitStore
import KnitWire

// Our own profile frame, signed once for each publish stamp (ADR 2026-11.xfcq, after knit-next ADR 2026-11.khhj): custody's
// quotas evict our own frames as they evict anyone's, so the frame we published is kept beside our profile, byte for byte,
// and an evicted row goes back as those bytes. A second signing of a stamp would be a second set of bytes under an id peers
// already hold, since CryptoKit randomizes Ed25519 signatures and the profile read later can carry another prekey or device
// tag, and so a second blob in every DM scope (knit-next ADR 2026-09.y5f3).
extension MeshEngine {
    /// What one store unit read for our current stamp: custody's row and the kept frame, or a unit that failed.
    private enum OwnFrameRead {
        case read(held: CarriedFrame?, kept: KeptProfileFrame)
        case failed
    }

    /// What the kept frame is to the current stamp: ours, ours under another stamp, or no frame of ours at all.
    private enum KeptVerdict {
        case ours(SignedFrame)
        case otherStamp
        case refused
    }

    /// Our profile frame for the current publish stamp (`MeshManager.ownProfile` and `signOwnProfileLocked`,
    /// `MeshManager.kt:6303-6345` at knit-next `c1dcef23d`), from the first of:
    /// 1. custody's row, kept as the published frame too when the kept frame differs, as a build's first start finds it;
    /// 2. ``signedProfile``, this process's copy, so a store that keeps failing never makes a link-up sign again;
    /// 3. the kept frame, once it reads as ours under this stamp and its signature verifies;
    /// 4. a fresh signing, kept, only when custody read with no row and the kept frame read as none (or one refused).
    ///
    /// Whatever answers after custody's row is missing goes back into custody as it is, under the quotas and the gate every
    /// frame of ours meets (``carryOwn(_:)``): nothing is minted or sealed, and nothing checks the capabilities, which
    /// only an edit's publish moves here (``republishIfCapabilitiesChanged()``). Custody's row and the kept frame are read in
    /// one store unit, so custody's failed read never passes for "no row". When either read fails and this process holds
    /// no copy of the stamp, the answer is `nil`: an earlier process may have signed it, so signing now could make a second
    /// set of bytes. So is a profile the store cannot read, which ``OwnProfileStore/load()`` would answer as a fresh one at
    /// stamp 0. The start's seed, ``pushProfile(to:)`` and an edit whose save did not land reach that, and the next
    /// link-up asks again.
    func ownProfile() -> SignedFrame? {
        guard let own = stores.ownProfile.loadIfReadable() else {
            log.log(.warning, "mesh has no profile frame to send: our profile could not be read")
            return nil
        }
        let envelope = currentProfileEnvelope(of: own)
        let read = readOwnFrame(envelope.id, now: clock.wallMilliseconds())
        if case .read(let held?, let kept) = read {
            let frame = SignedFrame(wire: held.reserved, envelope: held.envelope)
            signedProfile = frame
            if kept != .kept(frame.wire) {
                keepOwnFrame(frame.wire)
            }
            return frame
        }
        if let cached = signedProfile, ExactKey(cached.envelope.id) == ExactKey(envelope.id) {
            // A keep that failed when this copy was signed is mended once the store reads again.
            if case .read(_, let kept) = read, kept != .kept(cached.wire) {
                keepOwnFrame(cached.wire)
            }
            carryOwn(cached)
            return cached
        }
        guard case .read(_, let kept) = read, kept != .unreadable else {
            log.log(.warning, "mesh has no profile frame to send: our custody or the kept frame could not be read")
            return nil
        }
        if case .kept(let wire) = kept {
            switch verdict(onKept: wire, id: envelope.id) {
            case .ours(let frame):
                signedProfile = frame
                carryOwn(frame)
                return frame
            case .otherStamp:
                // Ours under an older stamp: the fresh signing below takes its place, so a signing that fails leaves it.
                break
            case .refused:
                // Another identity's, or bytes that no longer verify: forgotten, then signed afresh below.
                keepOwnFrame(nil)
            }
        }
        return signFresh(envelope)
    }

    /// Our profile signed afresh under `publishedAt`, the stamp ``publishEdit(of:_:)`` or ``republish(_:now:)`` has just
    /// saved: `max(now, publishedAt + 1)`, which no frame can be kept under yet, so neither custody nor the kept frame is
    /// read. The frame is kept, cached and carried. When the store still reads another stamp, the save did not land, and
    /// that stamp may have been signed already, so the frame is ``ownProfile()``'s for it instead.
    func signFreshProfile(publishedAt: Int64) -> SignedFrame? {
        guard let own = stores.ownProfile.loadIfReadable(), own.publishedAt == publishedAt else {
            log.log(.warning, "mesh signed no new profile: our profile does not read the stamp \(publishedAt) saved")
            return ownProfile()
        }
        return signFresh(currentProfileEnvelope(of: own))
    }

    /// `envelope` signed, the one place our profile is signed: kept before it is carried, so a process ended between the two
    /// finds the same bytes at its next start, and cached.
    private func signFresh(_ envelope: RelayEnvelope) -> SignedFrame? {
        let frame = sign(envelope, relay: true).map { SignedFrame(wire: $0, envelope: envelope) }
        if let frame {
            signedProfile = frame
            keepOwnFrame(frame.wire)
            carryOwn(frame)
        }
        return frame
    }

    /// Custody's live row under `id` and the kept frame, in one store unit of their own, never nested in another (as
    /// ``custodyCopy(_:now:)`` reads), or ``OwnFrameRead/failed`` when the unit failed, which a SQL store would otherwise
    /// answer as "nothing held". A unit that joined another counts as failed too: no caller opens one around it.
    private func readOwnFrame(_ id: String, now: Int64) -> OwnFrameRead {
        let read = stores.transactor.atomically { () -> OwnFrameRead? in
            .read(held: stores.custody.frame(id, now: now), kept: stores.ownProfile.keptFrame())
        }
        guard case .committed(let value) = read else {
            return .failed
        }
        return value
    }

    /// What the kept frame `wire` is to `id` (`keptOwnProfile`, `MeshManager.kt:6348-6353`). It is ours only if it decodes
    /// from its signed bytes as a profile whose sender is us, by their bytes, and its signature verifies against our key;
    /// anything else is refused. Ours, it is the stamp's frame only under `id`, by its bytes, and is answered as stored,
    /// never encoded again.
    private func verdict(onKept wire: WireEnvelope, id: String) -> KeptVerdict {
        guard let envelope = try? RelayEnvelope(decoding: wire.signed), envelope.type == .profile,
            ExactKey(envelope.senderId) == ExactKey(nodeId.string), identity.bundle.isValidSignature(wire.sig, for: wire.signed)
        else {
            return .refused
        }
        guard ExactKey(envelope.id) == ExactKey(id) else {
            return .otherStamp
        }
        return .ours(SignedFrame(wire: WireEnvelope(sig: wire.sig, signed: wire.signed), envelope: envelope))
    }

    /// Keeps `wire` as the frame we published, or forgets it (`keepOwnProfile`, `:6355-6359`). A write that fails is logged
    /// and changes nothing else: the worst it costs is a signing at the next start that finds custody's row gone.
    private func keepOwnFrame(_ wire: WireEnvelope?) {
        if !stores.ownProfile.keep(wire) {
            log.log(.warning, "mesh could not keep our profile frame")
        }
    }
}
