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
        // Every channel's end, whatever closed it: the resolver's entries for the link lapse from here (`onLinkEnded`).
        aliases.onLinkEnded(id)
        heldDials[id] = nil
        tagNextHeld[id] = nil
        blindWriter.sends.forget(id)
        blindWriter.notes.forget(id)
        blindWriter.linkForms[id] = nil
        var events: [Event] = []
        var booked: [DialKey] = []
        switch channel.stage {
        case .live(let linked):
            booked = [.peer(.node(linked))]
            endLink(id, now: now)
            events.append(.down(linked))
            log.log(.info, "link down \(linked) on \(id)")
        case .connecting, .awaitingHello, .awaitingProof:
            // Nothing was registered, so nothing goes down: a dial that fails its proof is a failed dial.
            if case .dialer(let target) = channel.role {
                if dialing[target.key] == id {
                    dialing[target.key] = nil
                }
                // A dial its own peer's crossing link made fail is no failure to back off from; one that began with the
                // peer already held is an ordinary refusal and backs off (`DialKeys.linkedNow`, hj4a's amendment).
                let linked = Set(liveLinks.map { SightingKey.node($0.neighbor.nodeId) })
                booked = DialKeys.linkedNow(target.record, dialKey: target.key, linked: linked) ? [] : target.failureKeys
                if backingOff {
                    heldStreaks.dialFailed(target.record, dialKey: target.key) { key in key.nodeId.flatMap(liveChannel(to:)) }
                }
            }
        }
        if backingOff {
            for key in booked {
                bumpBackoff(key, now: now)
            }
        }
        return events
    }

    /// A live link on `id` ended: the next spell of seeking, and the backoffs its refused dials earned (hj4a's amendment).
    func endLink(_ id: ChannelID, now: Int64) {
        if let link = liveLinks.first(where: { $0.channel == id }) {
            if now - link.since >= configuration.seekSpellResetMilliseconds {
                // A link that held gives the next spell of seeking every wake; one that flapped leaves the count as it was.
                spell = SeekSpell()
            }
            // The dials refused while it was held earned no wait for the relink after it.
            for key in heldStreaks.ended(id, heldMilliseconds: now - link.since) {
                backoffs[key] = nil
            }
        }
        liveLinks.removeAll { $0.channel == id }
    }

    /// A failed dial, or a link that died, lengthens the wait under `peer` (`bumpBackoffLocked`). A tag dial's failure is
    /// booked on its dial key, and while unresolved on its address and handle (``DialTarget/failureKeys``), never on the id
    /// its reply named.
    func bumpBackoff(_ peer: DialKey, now: Int64) {
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
        formKeys.clear()
        heldDials.removeAll()
        refusedDials.removeAll()
        heldStreaks.clear()
        replayMarks.clear()
        relinkWindow.clear()
        advertised = nil
        advertDue = nil
        writerDown()
        return events
    }

    /// Hands the radio the payload the aired snapshot makes now, when it differs from the last (``AdvertWriter/push(_:)``):
    /// built from the snapshot's form and PSM, never from the node id while it blinds, and nothing while a rotation's tag is
    /// pending or the radio is down.
    func advertiseNow() {
        guard running, let payload = blindWriter.writer.push(payload(of:)), payload != advertised else {
            return
        }
        advertised = payload
        radio.advertise(payload)
    }

    /// Writes our HELLO (``ourHello(addressing:)``), and keeps its payload on the channel for the link's proof. A dialer's
    /// names the form it dialed (`a`), as every Android build writes it (`BluetoothMeshTransport.kt:3819-3837`).
    func writeHello(on id: ChannelID) {
        var dialed: AdvertOrder.Form?
        if case .dialer(let target) = channels[id]?.role {
            dialed = target.form
        }
        let payload = ourHello(addressing: dialed).payload
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
    ///
    /// After the nonce, `t` names the tag we air while we blind, so a peer judges the order on the form it could have heard
    /// (`toldForm`, `BluetoothMeshTransport.kt:3837` at `cad69c77b`; ADR 2026-11.prsp), and a dial's HELLO carries `a`, the
    /// form `addressing` names. ``Capabilities/blindAdvert`` comes with ``Capabilities/local``;
    /// ``Configuration/withholdsBlindAdvert``, a test's seam, takes it out of this HELLO alone, as a build from before the
    /// reader would send.
    func ourHello(addressing: AdvertOrder.Form?) -> Hello {
        var capabilities = Capabilities.local.union(.blobHave)
        if configuration.withholdsBlindAdvert {
            capabilities.remove(.blindAdvert)
        }
        if radio.servesDoorbell {
            capabilities.insert(.doorbell)
        }
        if !provesLinks {
            // knit-peer's legacy impostor stands in for Android v2.10.1, which had neither bit.
            capabilities.remove(.linkProof)
            capabilities.remove(.blindAdvert)
        }
        let nonce = capabilities.contains(.linkProof) ? LinkProof.freshNonce() : nil
        let current = mine.current
        let told = nonce != nil && current.blinded ? current.advertised.bytes : nil
        let addressed = nonce == nil ? nil : addressing?.advertised.bytes
        return Hello(
            nodeId: (impostor.claimedId ?? localId).string, capabilities: capabilities, nonce: nonce, told: told, addressed: addressed)
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
