public import KnitMesh
public import KnitWire
public import Observation

/// Internet relays as the settings show and change them (ADR 2026-11.adrq, P6): the master switch, the list, the consent
/// sheets and invites, over the one serial stream into the mesh (``MeshPhases``). A debug build's alone: the composition root
/// makes one only there, and the gate reads the build it is told, the compile-time flag.
///
/// - **The gate** (``spoolEnabled``) is a debug build, the list read, and the switch on under the current consent, bound by
///   the install's consent nonce, which the Keychain holds and the list keeps a copy of. Closed, the mesh carries no relay
///   and the spool stays paused; opened, it carries every unparked relay whose address reads, and the scene's phase decides
///   when it runs (``SpoolLifecycle``). A nonce that cannot be read keeps it closed until a read succeeds.
/// - **What is kept where.** The preferences keep the list's handles and flags (``RelayBook``); every address but the
///   seeded house relay's is in the relay's own item in the ``RelaySecretStore``, written once as the accepted address's
///   ``AcceptedSpoolURL/socketURLText``, and read back only through ``AcceptedSpoolURL``. Only a list never kept sweeps the
///   store before it seeds: bytes that do not read as a list are left as they are, and nothing is read or dialled until
///   they do. A failed delete is retried at each return to the front, and handles are never reused.
/// - **Consent names what is dialled.** Turning the switch on lists every relay that can join under it, by host, or by
///   number while its address cannot be read; a sheet that no longer says what the tap would do is shown again instead of
///   applied. Adding a relay names the one address the invite came to, and the sheet's Add applies the value it was built
///   from. A new invite replaces a sheet that is up.
@preconcurrency
@MainActor
@Observable
public final class InternetRelays {
    /// What an address read came to.
    enum Address: Equatable {
        case ready(AcceptedSpoolURL)
        /// The store could not answer: listed, undialled, read again at the next return to the front.
        case unreadable
        /// No item: the address is gone, and only its invite brings it back.
        case missing
        /// A stored text this build's factory refuses: kept, never dialled.
        case unusable
        /// The same address another listed relay is ready under: kept, never dialled, until that one goes.
        case duplicate(AcceptedSpoolURL)

        /// The address it read, when it read one.
        var url: AcceptedSpoolURL? {
            switch self {
            case .ready(let url), .duplicate(let url):
                url
            case .unreadable, .missing, .unusable:
                nil
            }
        }
    }

    @ObservationIgnored let debugBuild: Bool
    @ObservationIgnored let preferences: any AppPreferences
    @ObservationIgnored let secrets: any RelaySecretStore
    @ObservationIgnored let phases: MeshPhases
    @ObservationIgnored let log: any KnitLog
    @ObservationIgnored let makeNonce: @Sendable () -> String
    /// What the mesh was last told to carry, by handle.
    @ObservationIgnored var carried: [Int: AcceptedSpoolURL] = [:]
    /// Whether the mesh was last told the gate is open.
    @ObservationIgnored var gateSent = false
    @ObservationIgnored var nextSheet = 1
    /// Whether the list's unreadable bytes were logged, once a process.
    @ObservationIgnored var reportedUnreadable = false

    /// The list's switch, consent, handles and owed deletes; its entries are ``listed``'s, written back on each save.
    var book = RelayBook()
    /// Each listed relay with what its address read came to, in the order they were added.
    var listed: [(entry: RelayEntry, address: Address)] = []
    var meshStatus: RelayMeshStatus?
    /// The consent nonce the Keychain holds, `nil` when it holds none.
    var givenNonce: String?
    /// Whether the last read of the consent nonce failed: the gate stays shut until a read succeeds.
    var nonceUnread = false
    /// Whether the list has been read: until then nothing is shown, added or dialled.
    public internal(set) var isLoaded = false
    /// The consent sheet up now, if any.
    public var sheet: RelaySheet?
    /// A line to show once: why an invite was not taken, or a relay not kept.
    public var notice: RelayNotice?

    /// The relays kept in `preferences` and `secrets`, told to the mesh through `phases`, with failures logged to `log` by
    /// kind alone and consent nonces from `makeNonce`. `debugBuild` is the build's compile-time flag: `false` keeps the gate
    /// shut whatever is stored.
    @preconcurrency
    public init(
        debugBuild: Bool, preferences: any AppPreferences, secrets: any RelaySecretStore, phases: MeshPhases, log: any KnitLog,
        makeNonce: @escaping @Sendable () -> String = RelayBook.freshNonce
    ) {
        self.debugBuild = debugBuild
        self.preferences = preferences
        self.secrets = secrets
        self.phases = phases
        self.log = log
        self.makeNonce = makeNonce
    }

    /// Whether the spool plane may run: a debug build, the list read, and the switch on under the current consent, bound by
    /// the nonce the Keychain holds.
    public var spoolEnabled: Bool {
        debugBuild && isLoaded && !nonceUnread && book.consented(given: givenNonce)
    }

    /// The list, in the order the relays were added.
    public var rows: [RelayRow] {
        listed.map { entry, address in
            RelayRow(
                handle: entry.handle,
                host: address.url.map(RelayHost.init),
                isPrivate: entry.isPrivate,
                parked: entry.parked,
                status: status(of: entry, address)
            )
        }
    }

    // MARK: Reading

    /// Reads the list, seeding the house relay when none was ever kept, and tells the mesh what to carry. Called once the
    /// identity has been read, so the preferences answer (ADR 2026-11.adrq, P6), and again at each return to the front
    /// until it succeeds. Bytes that do not read as a list are left as they are, logged once, and nothing else happens.
    public func load() {
        guard !isLoaded else {
            return
        }
        var read: RelayBook
        switch preferences.relayBook {
        case .unreadable:
            if !reportedUnreadable {
                reportedUnreadable = true
                log.log(.warning, "relays: the kept list does not read; it is left as it is and nothing is dialled")
            }
            return
        case .absent:
            // A fresh install: no item an earlier one left is read under a handle this one hands out, and no consent holds.
            do {
                try secrets.deleteAll()
            } catch {
                return
            }
            read = RelayBook()
        case .stored(let stored):
            read = stored
        }
        if !read.seeded {
            read.entries.append(RelayEntry(handle: read.nextHandle, seeded: true, isPrivate: false))
            read.nextHandle += 1
            read.seeded = true
        }
        book = read
        isLoaded = true
        retryDeletes()
        listed = []
        for entry in read.entries {
            listed.append((entry, address(of: entry)))
        }
        readNonce()
        save()
        sync()
    }

    /// Knit came to the front: the list is read if it never was; failed deletes, unreadable addresses and an unread consent
    /// nonce are tried again.
    public func becameActive() {
        guard isLoaded else {
            load()
            return
        }
        retryDeletes()
        for index in listed.indices where listed[index].address == .unreadable {
            listed[index].address = address(of: listed[index].entry)
        }
        if nonceUnread {
            readNonce()
        }
        save()
        sync()
    }

    /// Reads where each relay stands from the mesh, for the rows' words.
    public func refreshStatus() async {
        meshStatus = await phases.target.relayStatus()
    }

    // MARK: Changing

    /// The switch: on asks first, with a sheet that lists every relay that can join under it; off removes every relay from
    /// the mesh and keeps the list.
    public func setSwitch(_ on: Bool) {
        guard isLoaded, on != spoolEnabled else {
            return
        }
        if on {
            present(.turnOn(joining()))
        } else {
            book.switchOn = false
            book.consent = nil
            save()
            sync()
        }
    }

    /// Applies the sheet `shown`, the one the person tapped on: its own value, never one that came after it. A switch sheet
    /// whose list no longer matches the relays that would join is shown again, as it now stands, instead.
    public func confirm(_ shown: RelaySheet) {
        dismiss(shown)
        switch shown.kind {
        case .turnOn(let relays):
            guard relays == joining() else {
                present(.turnOn(joining()))
                return
            }
            turnOn()
        case .add(let url):
            add(url)
        }
    }

    /// Closes the sheet `shown` without applying it.
    public func dismiss(_ shown: RelaySheet) {
        if sheet?.id == shown.id {
            sheet = nil
        }
    }

    /// A relay invite opened from outside Knit or tapped in a message: ignored unless it starts with an invite's prefix.
    public func offer(opened text: String) {
        if let outcome = RelayIntake.opened(text) {
            take(outcome)
        }
    }

    /// Pasted text, with a relay invite anywhere in it.
    public func offer(pasted text: String) {
        take(RelayIntake.pasted(text))
    }

    /// Stops using the relay `handle`, keeping it listed, or uses it again.
    public func setParked(_ handle: Int, _ parked: Bool) {
        guard let index = listed.firstIndex(where: { $0.entry.handle == handle }) else {
            return
        }
        listed[index].entry.parked = parked
        save()
        sync()
    }

    /// Voids the consent before the identity is replaced, so it never outlives the identity it was given beside: the switch
    /// goes off and the list's copy of the nonce goes, saved first, which needs no Keychain, so no later launch matches the
    /// nonce whatever its item's delete does; every relay leaves this process's mesh; then the nonce's item is deleted, a
    /// failure costing nothing but the store's own status line. A list that never read is left as it is, and only the
    /// delete runs.
    public func forgetConsent() {
        if isLoaded {
            book.switchOn = false
            book.consent = nil
            givenNonce = nil
            save()
            sync()
        }
        try? secrets.deleteConsent()
    }

    /// Drops the relay `handle` from the list and the mesh, and its address from the store: a delete that fails is tried
    /// again at each return to the front, and the handle is never handed out again. A relay listed twice is ready again
    /// under its other handle once the dialled one goes.
    public func remove(_ handle: Int) {
        guard let index = listed.firstIndex(where: { $0.entry.handle == handle }) else {
            return
        }
        let entry = listed.remove(at: index).entry
        if !entry.seeded {
            do {
                try secrets.delete(handle)
            } catch {
                book.pendingDeletes.append(handle)
            }
        }
        for other in listed.indices {
            if case .duplicate(let url) = listed[other].address, !listed.contains(where: { $0.address == .ready(url) }) {
                listed[other].address = .ready(url)
            }
        }
        save()
        sync()
    }
}
