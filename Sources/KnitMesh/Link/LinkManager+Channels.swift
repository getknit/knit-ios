import KnitCrypto
import KnitWire

/// Closing channels, backing off, advertising and writing.
extension LinkManager {
    // MARK: Teardown and writes

    /// Closes a channel and forgets it, and answers the link that went down with it, if it was registered. An attachment
    /// cut off mid-stream leaves its bytes in ``partials`` for the next ask to resume from, as Android's every
    /// `FramedLink.close()` does (`FramedLink.kt:528-536`, `FileIntake.kt:232-243`; knit-next ADR 2026-10.wtyc), unless
    /// `keepingCut` is false: a stop, whose prefixes ``Mesh`` purges right after, or bytes the link itself made suspect. A
    /// channel retired before a HELLO holds no intake, and one already retired is not here, so either keeps nothing.
    func retire(_ id: ChannelID, backingOff: Bool, now: Int64) -> [Event] {
        retire(id, backingOff: backingOff, keepingCut: true, now: now)
    }

    /// ``retire(_:backingOff:now:)``, keeping a cut attachment's bytes only when `keepingCut` says to.
    func retire(_ id: ChannelID, backingOff: Bool, keepingCut: Bool, now: Int64) -> [Event] {
        guard let channel = channels.removeValue(forKey: id) else {
            return []
        }
        radio.close(id)
        crossings.forget(link: id)
        stallWatch.forget(id)
        doorbells[id] = nil
        if keepingCut {
            // Before the intake goes, and so before any link that replaces this one is live to carry an ask.
            keepCutFile(on: id, now: now)
        }
        intakes[id] = nil
        arrivalClocks[id] = nil
        if feeds.removeValue(forKey: id)?.streaming != nil {
            // A copy cut off holds nobody parked behind it.
            noteFeedsChanged()
        }
        var events: [Event] = []
        var peer: NodeId?
        switch channel.stage {
        case .live(let linked):
            peer = linked
            if let link = liveLinks.first(where: { $0.channel == id }), now - link.since >= configuration.seekSpellResetMilliseconds {
                // A link that held gives the next spell of seeking every wake; one that flapped leaves the count as it was.
                spell = SeekSpell()
            }
            liveLinks.removeAll { $0.channel == id }
            events.append(.down(linked))
            log.log(.info, "link down \(linked) on \(id)")
        case .connecting, .awaitingHello, .awaitingProof:
            // Nothing was registered, so nothing goes down: a dial that fails its proof is a failed dial.
            if case .dialer(let dialed) = channel.role {
                peer = dialed
                if dialing[dialed] == id {
                    dialing[dialed] = nil
                }
            }
        }
        if backingOff, let peer {
            bumpBackoff(peer, now: now)
        }
        return events
    }

    /// A failed dial, or a link that died, lengthens the peer's wait (`bumpBackoffLocked`).
    func bumpBackoff(_ peer: NodeId, now: Int64) {
        let streak = (backoffs[peer]?.streak ?? 0) + 1
        let delay = ConnectBackoff.delay(afterStreak: streak, random: unitDraw(), configuration: configuration.backoff)
        backoffs[peer] = Backoff(streak: streak, nextAt: now + delay)
    }

    /// A uniform draw from `0..<1`, from the injected generator.
    func unitDraw() -> Double {
        let mantissaBits = 53
        return Double(random.next() >> UInt64(UInt64.bitWidth - mantissaBits)) / Double(UInt64(1) << UInt64(mantissaBits))
    }

    /// Closes every channel and forgets what the session learnt of the air. A radio that went off, reset or lost its
    /// authorization keeps its cut attachments like any other teardown (`keepingCuts`); ``stop()`` does not, since
    /// ``Mesh/stop()`` purges them next and writing up to a buffer's worth only to delete it is waste.
    func forgetEverything(keepingCuts: Bool) -> [Event] {
        let now = clock.monotonicMilliseconds()
        let ids = channels.keys.sorted(by: Self.inOrder)
        let events = ids.flatMap { retire($0, backingOff: false, keepingCut: keepingCuts, now: now) }
        // A file that landed in a session is taken in it; nothing landed before a start is one the engine will take.
        landingFiles.removeAll()
        presence = PresenceTracker(configuration: configuration.presence)
        addresses.removeAll()
        backoffs.removeAll()
        psm = nil
        advertised = nil
        advertDue = nil
        return events
    }

    func advertiseNow() {
        guard running, let psm else {
            return
        }
        let payload = AdvertPayload(
            capabilities: .local,
            nodeId: localId,
            digestCue: digestCue,
            psm: psm,
            flags: AdvertPayload.writtenFlags(dialsGattPeers: radio.dialsGattPeers)
        )
        guard payload != advertised else {
            return
        }
        advertised = payload
        radio.advertise(payload)
    }

    /// Writes our HELLO (``ourHello()``), and keeps its payload on the channel for the link's proof.
    func writeHello(on id: ChannelID) {
        let payload = ourHello().payload
        channels[id]?.wroteHello = payload
        if let record = LinkRecord(.hello, payload: payload).encoded {
            write(record, on: id)
        }
    }

    /// Our HELLO for one connection: this build's capabilities, plus the bits that are the link's to claim.
    /// `CAP_BLOB_HAVE` always, since every build answers a holder query and Android reads the bit from the link alone
    /// (knit-next ADR 2026-10.6e5t), and `CAP_DOORBELL` when the radio serves one, so Android rings it (knit-next ADR
    /// 2026-09.dqvb). Neither goes anywhere else: not in the advert, and not in the signed profile. With
    /// ``Capabilities/linkProof``, which ``Capabilities/local`` carries, comes a nonce fresh for this connection from the
    /// system's secure source, never the injected generator a test seeds (the `link-hello-proof` contract, §2).
    func ourHello() -> Hello {
        var capabilities = Capabilities.local.union(.blobHave)
        if radio.servesDoorbell {
            capabilities.insert(.doorbell)
        }
        if !provesLinks {
            capabilities.remove(.linkProof)
        }
        let nonce = capabilities.contains(.linkProof) ? LinkProof.freshNonce() : nil
        return Hello(nodeId: (impostor.claimedId ?? localId).string, capabilities: capabilities, nonce: nonce)
    }

    /// Writes a record in slices of at most ``Configuration/maxWriteBytes``.
    func write(_ record: [UInt8], on id: ChannelID) {
        var start = 0
        while start < record.count {
            let end = min(start + configuration.maxWriteBytes, record.count)
            radio.write(Array(record[start..<end]), to: id)
            start = end
        }
    }
}
