public import KnitWire

extension RatchetEngine {
    /// One frame's way down the ladder (`Ladder`, `:378-492`): three passes over the root candidates, each candidate
    /// leaving at the first pass that holds something of its own, namely its stored skipped key for `(se, n)`, else its
    /// live chain for `se`, else a fresh derivation. Only one root can open a frame, so the order changes the cost and
    /// never the result; this one lets an old era's frame drain on its own stored chain before any DH is paid for it.
    struct Ladder {
        let context: OpenContext
        let resolved: ResolvedSession
        let header: RatchetHeader
        /// The carried v2 IV, or `nil` for v3.
        let nonce: [UInt8]?
        let ct: [UInt8]
        let aad: [UInt8]
        let now: Int64
        // What the passes found, for the verdict; only the ladder sets them, and they start false.
        /// A candidate's live chain had spent the index.
        var consumed = false
        /// A candidate's key resolved and the AEAD refused.
        var aeadFailed = false
        /// X25519 refused the header's `ek`.
        var badHeader = false
        /// The base the header names is not one we hold.
        var epochGone = false

        /// The outcome (`climb`, `:392-411`). A resolution that purges reads nothing stored: every row describes the
        /// era it just left, and the resolving frame must reach the fresh derivation that records the new one. A stored
        /// rung would skip that: a late race remnant's read banks a skipped key under the very root a flagged reset
        /// then asks us to adopt, and opening the reset on it would leave the replacement without its DH base.
        ///
        /// Kotlin trusts the caller to pass only the header's chains and keys; this also checks their `se` and `n`, so
        /// a wider list never opens a frame on another epoch's chain.
        mutating func climb() -> OpenOutcome {
            let rows = resolved.purge ? [] : context.recvEpochs.filter { $0.epoch == header.se }
            let keys = resolved.purge ? [] : context.skippedKeys.filter { $0.epoch == header.se && $0.index == header.n }
            var left = Self.distinctByTag(resolved.candidates)
            for candidate in left {
                guard let key = keys.first(where: { $0.rootTag == candidate.tag }) else {
                    continue
                }
                left.removeAll { $0.tag == candidate.tag }
                if let opened = openSkipped(candidate, key: key, row: rows.first { $0.rootTag == candidate.tag }) {
                    return .opened(opened)
                }
            }
            for candidate in left {
                guard let row = rows.first(where: { $0.rootTag == candidate.tag }) else {
                    continue
                }
                left.removeAll { $0.tag == candidate.tag }
                if let opened = openLive(candidate, row: row) {
                    return .opened(opened)
                }
            }
            if let opened = openFresh(left) {
                return .opened(opened)
            }
            return .failed(verdict())
        }

        /// Each tag once, the first candidate holding it kept (`distinctBy { it.tag }`, `:399`).
        private static func distinctByTag(_ candidates: [RootCandidate]) -> [RootCandidate] {
            var seen = Set<Int64>()
            return candidates.filter { seen.insert($0.tag).inserted }
        }

        /// The candidate's stored key for `(se, n)`; a failure means the frame is not this root's (`openSkipped`,
        /// `:414-432`). It moves no era, and touches only the chain row's clock.
        private mutating func openSkipped(_ candidate: RootCandidate, key: SkippedKey, row: RecvEpoch?) -> OpenOutcome.Opened? {
            guard let plaintext = decrypt(with: key.messageKey) else {
                aeadFailed = true
                return nil
            }
            var touched = row
            touched?.lastUsedAt = now
            let delta = OpenDelta(
                session: touch(resolved.session, eraEffects: false),
                recvEpoch: touched,
                skippedInserts: [],
                consumedSkippedTag: candidate.tag,
                purgePeerRecvState: false
            )
            return OpenOutcome.Opened(plaintext: plaintext, delta: delta)
        }

        /// The candidate's live chain for `se` (`openLive`, `:435-446`): an index below its cursor is spent under this
        /// root, and one at or above it advances the chain, banking the keys it skips.
        private mutating func openLive(_ candidate: RootCandidate, row: RecvEpoch) -> OpenOutcome.Opened? {
            guard header.n >= row.next else {
                consumed = true
                return nil
            }
            guard let opened = finishOpen(rootTag: candidate.tag, chainKey: row.chainKey, next: row.next, eraEffects: false) else {
                aeadFailed = true
                return nil
            }
            return opened
        }

        /// A new epoch derivation under each candidate that holds nothing stored for the frame, one DH shared between
        /// them (`openFresh`, `:449-475`). The base is our prekey the init names for `pe = 0`, else our epoch `pe`.
        /// X25519 refusing the `ek` is `BAD_HEADER`, where Tink's throw is caught (`:456-460`), and never `AEAD_FAIL`;
        /// swift-crypto and CryptoKit give zeros where Tink throws, which ``RatchetCrypto/dh(_:_:)`` refuses.
        private mutating func openFresh(_ candidates: [RootCandidate]) -> OpenOutcome.Opened? {
            guard !candidates.isEmpty else {
                return nil
            }
            guard let basePrivateKey = header.pe == 0 ? context.prekeyForInit?.privateKey : context.ownBasePrivateKey else {
                epochGone = true
                return nil
            }
            guard let shared = try? RatchetCrypto.dh(basePrivateKey, header.ek) else {
                badHeader = true
                return nil
            }
            for candidate in candidates {
                let keys = RatchetCrypto.deriveEpoch(
                    sessionRoot: candidate.root,
                    dhShared: shared,
                    senderIsInitiator: candidate.senderIsInitiator,
                    senderEpoch: header.se,
                    baseEpoch: header.pe
                )
                if let opened = finishOpen(rootTag: candidate.tag, chainKey: keys.chainKey, next: 0, eraEffects: candidate.active) {
                    return opened
                }
                aeadFailed = true
            }
            return nil
        }

        /// Nothing opened (`verdict`, `:484-491`). `DUPLICATE` outranks the rest: it is the benign verdict, and a
        /// genuine re-serve of a spent frame also fails under every other candidate, which must not walk the reset
        /// heuristic. It never stops the ladder, though, since a spent index under one root is exactly what an old era's
        /// drained chain shows the new era's frame of the same number (#135).
        private func verdict() -> OpenOutcome.Failed {
            if consumed {
                return .duplicate
            }
            if aeadFailed {
                return .aeadFail
            }
            if badHeader {
                return .badHeader
            }
            return epochGone ? .epochGone : .aeadFail
        }

        /// Advances a chain at `next` to the header's index and opens the frame there (`finishOpen`, `:720-754`): the
        /// keys it passes are banked as skipped keys, and everything it stores carries `rootTag`.
        private func finishOpen(rootTag: Int64, chainKey chainKeyAtNext: [UInt8], next: Int, eraEffects: Bool) -> OpenOutcome.Opened? {
            var chainKey = chainKeyAtNext
            var skipped: [SkippedKey] = []
            for index in stride(from: next, to: header.n, by: 1) {
                let messageKey = RatchetCrypto.messageKey(chainKey)
                skipped.append(SkippedKey(epoch: header.se, rootTag: rootTag, index: index, messageKey: messageKey, createdAt: now))
                chainKey = RatchetCrypto.nextChainKey(chainKey)
            }
            guard let plaintext = decrypt(with: RatchetCrypto.messageKey(chainKey)) else {
                return nil
            }
            let delta = OpenDelta(
                session: touch(resolved.session, eraEffects: eraEffects),
                recvEpoch: RecvEpoch(
                    epoch: header.se,
                    rootTag: rootTag,
                    chainKey: RatchetCrypto.nextChainKey(chainKey),
                    next: header.n + 1,
                    lastUsedAt: now
                ),
                skippedInserts: skipped,
                consumedSkippedTag: nil,
                purgePeerRecvState: resolved.purge
            )
            return OpenOutcome.Opened(plaintext: plaintext, delta: delta)
        }

        /// One AEAD attempt with `key` (`decryptWith`, `:811-823`). Without a carried nonce it is the v3 form: the
        /// header is bound into the AAD and the nonce derives from the very key being tried, so every rung and every
        /// candidate derives its own, and a stored skipped key, all a skipped row keeps, still opens.
        private func decrypt(with key: [UInt8]) -> [UInt8]? {
            guard let nonce else {
                let boundAad = aad + RatchetCrypto.headerBindingBytes(header)
                let derived = RatchetCrypto.messageNonce(messageKey: key, aad: boundAad)
                return RatchetCrypto.open(ct, key: key, nonce: derived, aad: boundAad)
            }
            return RatchetCrypto.open(ct, key: key, nonce: nonce, aad: aad)
        }

        /// After an open (`touch`, `:765-794`). The era effects, only when the frame derived a fresh epoch under the
        /// active root: adopt the peer's newest epoch as our next DH base, raise `highestPeAcked`, and confirm an
        /// initiator once the peer seals against an epoch of ours, which drops the init from our frames. The gate is what
        /// #87 needed: a frame drained under the `prevRoot` our reset kept names an old-era epoch of ours, whose key
        /// survives, and used to confirm the replacement, so our next frame dropped the init and a peer that had not yet
        /// seen the reset could not read it. Retiring an expired `prevRoot` is calendar, not era, and always runs.
        private func touch(_ session: SessionState, eraEffects: Bool) -> SessionState {
            guard eraEffects else {
                return RatchetEngine.retirePrevRoot(session, now: now)
            }
            var touched = session
            // Damped: a peer that jumps its own numbering, buggy or hostile, would otherwise pin our base where no later
            // epoch passes the `>` test, and healing would never fire again. An unanchored session takes anything under
            // the ceiling, since after a replacement our anchor is 0 while the peer's numbering climbs on. Refusing to
            // adopt never drops the frame: we keep the older base, and the peer's eventual EPOCH_GONE resets the pair.
            let anchored = touched.peerBaseEpoch >= 1
            if header.se > touched.peerBaseEpoch, !anchored || header.se <= touched.peerBaseEpoch + RatchetEngine.maxEpochJump {
                touched.peerBasePub = header.ek
                touched.peerBaseEpoch = header.se
            }
            if header.pe > touched.highestPeAcked {
                touched.highestPeAcked = header.pe
            }
            let peerHoldsOurEpoch = header.pe >= 1 && context.ownBasePrivateKey != nil
            if !touched.confirmed, touched.weAreInitiator, peerHoldsOurEpoch {
                touched.confirmed = true
                touched.initEphPub = nil
            }
            return RatchetEngine.retirePrevRoot(touched, now: now)
        }
    }

    /// Drops a `prevRoot` whose drain has run out (`retirePrevRoot`, `:796-804`).
    static func retirePrevRoot(_ session: SessionState, now: Int64) -> SessionState {
        guard session.prevRoot != nil, session.prevRootExpiresAt <= now else {
            return session
        }
        var retired = session
        retired.prevRoot = nil
        retired.prevRootExpiresAt = 0
        return retired
    }
}
