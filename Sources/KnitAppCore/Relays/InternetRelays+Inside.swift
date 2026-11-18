import KnitMesh
import KnitWire

// What the relay settings do inside (ADR 2026-11.adrq, P6), apart from the class only to keep its file inside the lint's
// length.
extension InternetRelays {
    func take(_ outcome: RelayIntake.Outcome) {
        // A new invite replaces a sheet that is up, so the one on screen is always the latest.
        sheet = nil
        switch outcome {
        case .refused(let refusal):
            notice = .refused(refusal)
        case .accepted(let url):
            if let refusal = refusal(toAdd: url) {
                notice = refusal
            } else {
                present(.add(url))
            }
        }
    }

    /// Why `url` cannot join the list now, or `nil` when it can: an address any listed relay read, ready or a duplicate, is
    /// already there.
    func refusal(toAdd url: AcceptedSpoolURL) -> RelayNotice? {
        if !isLoaded {
            return .unavailable
        }
        if listed.contains(where: { $0.address.url == url }) {
            return .duplicate
        }
        return listed.count >= RelayBook.maxRelays ? .full : nil
    }

    func add(_ url: AcceptedSpoolURL) {
        if let refusal = refusal(toAdd: url) {
            notice = refusal
            return
        }
        let handle = book.nextHandle
        book.nextHandle += 1
        // Spent before its item exists, so a crash between the two never hands it out again.
        save()
        do {
            try secrets.write(handle, url.socketURLText)
        } catch {
            // A write that failed partway may have left an item behind.
            book.pendingDeletes.append(handle)
            save()
            notice = .notSaved
            return
        }
        listed.append((RelayEntry(handle: handle, seeded: false, isPrivate: url.carriesToken), .ready(url)))
        save()
        sync()
    }

    /// Turns the switch on under a fresh consent nonce, kept in the store first: a nonce the store would not keep turns
    /// nothing on.
    func turnOn() {
        let nonce = makeNonce()
        do {
            try secrets.writeConsent(nonce)
        } catch {
            notice = .consentNotSaved
            return
        }
        givenNonce = nonce
        nonceUnread = false
        book.switchOn = true
        book.consent = RelayConsent(version: RelayBook.consentVersion, nonce: nonce)
        save()
        sync()
    }

    func present(_ kind: RelaySheet.Kind) {
        sheet = RelaySheet(id: nextSheet, kind: kind)
        nextSheet += 1
    }

    /// Every relay that can join under the switch: each unparked one whose address reads, by its host, and each one whose
    /// address cannot be read now, by its number, which joins once it reads.
    func joining() -> [RelayJoin] {
        listed.compactMap { entry, address -> RelayJoin? in
            guard !entry.parked else {
                return nil
            }
            switch address {
            case .ready(let url):
                return RelayJoin(handle: entry.handle, host: RelayHost(url))
            case .unreadable:
                return RelayJoin(handle: entry.handle, host: nil)
            case .missing, .unusable, .duplicate:
                return nil
            }
        }
    }

    /// What the mesh should carry with the gate as `gateOpen` says.
    func wanted(gateOpen: Bool) -> [Int: AcceptedSpoolURL] {
        guard gateOpen else {
            return [:]
        }
        var urls: [Int: AcceptedSpoolURL] = [:]
        for (entry, address) in listed where !entry.parked {
            if case .ready(let url) = address {
                urls[entry.handle] = url
            }
        }
        return urls
    }

    /// Tells the mesh what changed since it was last told: the gate shut before the removals, opened after the additions.
    func sync() {
        let open = spoolEnabled
        let wanted = wanted(gateOpen: open)
        if !open, gateSent {
            phases.send(.gate(false))
            gateSent = false
        }
        for handle in carried.keys.sorted() where wanted[handle] == nil {
            phases.send(.remove(SpoolRelayHandle(number: handle)))
            carried[handle] = nil
        }
        for (handle, url) in wanted.sorted(by: { $0.key < $1.key }) where carried[handle] == nil {
            phases.send(.add(SpoolRelayHandle(number: handle), url))
            carried[handle] = url
        }
        if open, !gateSent {
            phases.send(.gate(true))
            gateSent = true
        }
    }

    /// What `entry`'s address read comes to: an address another listed relay is already ready under is a duplicate.
    func address(of entry: RelayEntry) -> Address {
        let text: String?
        do {
            text = entry.seeded ? SpoolURL.house : try secrets.read(entry.handle)
        } catch {
            return .unreadable
        }
        guard let text else {
            return .missing
        }
        guard let url = AcceptedSpoolURL(text, allowCleartext: false) else {
            return .unusable
        }
        let taken = listed.contains { $0.entry.handle != entry.handle && $0.address == .ready(url) }
        return taken ? .duplicate(url) : .ready(url)
    }

    /// Reads the consent nonce the store holds. A read that fails keeps the gate shut and is tried again at the next return
    /// to the front; a nonce that is gone or differs voids the consent.
    func readNonce() {
        do {
            givenNonce = try secrets.readConsent()
            nonceUnread = false
        } catch {
            nonceUnread = true
            log.log(.warning, "relays: the consent nonce does not read; nothing is dialled until it does")
            return
        }
        if book.switchOn, !book.consented(given: givenNonce) {
            // Given under older words, by an earlier install, on another phone, or before an identity was replaced.
            book.switchOn = false
            book.consent = nil
        }
    }

    func retryDeletes() {
        book.pendingDeletes = book.pendingDeletes.filter { handle in (try? secrets.delete(handle)) == nil }
    }

    func save() {
        book.entries = listed.map(\.entry)
        preferences.relayBookData = book.encoded
    }

    func status(of entry: RelayEntry, _ address: Address) -> RelayStatus {
        switch address {
        case .unreadable:
            return .unreadable
        case .missing:
            return .missing
        case .unusable:
            return .unusable
        case .duplicate:
            return .duplicate
        case .ready:
            break
        }
        if entry.parked {
            return .parked
        }
        guard spoolEnabled else {
            return .off
        }
        guard let meshStatus else {
            return .connecting
        }
        if meshStatus.paused {
            return .paused
        }
        switch meshStatus.relays[entry.handle] {
        case .some(let relay) where relay.state == "open":
            return .connected
        case .some(let relay) where relay.state == "idle" && relay.failures > 0:
            return .waiting
        default:
            return .connecting
        }
    }
}
