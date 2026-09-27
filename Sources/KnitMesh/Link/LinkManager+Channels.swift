import KnitWire

/// Closing channels, backing off, advertising and writing.
extension LinkManager {
    // MARK: Teardown and writes

    /// Closes a channel and forgets it, and answers the link that went down with it, if it was registered.
    func retire(_ id: ChannelID, backingOff: Bool, now: Int64) -> [Event] {
        guard let channel = channels.removeValue(forKey: id) else {
            return []
        }
        radio.close(id)
        crossings.forget(link: id)
        doorbells[id] = nil
        var events: [Event] = []
        var peer: NodeId?
        switch channel.stage {
        case .live(let linked):
            peer = linked
            liveLinks.removeAll { $0.channel == id }
            events.append(.down(linked))
            log.log(.info, "link down \(linked) on \(id)")
        case .connecting, .awaitingHello:
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

    func forgetEverything() -> [Event] {
        let now = clock.monotonicMilliseconds()
        let ids = channels.keys.sorted(by: Self.inOrder)
        let events = ids.flatMap { retire($0, backingOff: false, now: now) }
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
            flags: radio.dialsGattPeers ? AdvertPayload.dialsGattPeersFlag : 0
        )
        guard payload != advertised else {
            return
        }
        advertised = payload
        radio.advertise(payload)
    }

    func writeHello(on id: ChannelID) {
        if let record = LinkRecord(.hello, payload: Hello(nodeId: localId.string).payload).encoded {
            write(record, on: id)
        }
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
