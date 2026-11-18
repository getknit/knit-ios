public import KnitWire

/// A relay as a person is shown it (ADR 2026-11.adrq, P6): the `host[:port]` of the address the socket dials, never any
/// other reading of it, whether Knit runs it, and whether its address carries a token.
public struct RelayHost: Sendable, Equatable {
    /// ``AcceptedSpoolURL/description``: the host and port alone.
    public let host: String
    /// Whether the address is the house relay's, ``SpoolURL/house``, exactly: the only relay called Knit's.
    public let isKnits: Bool
    /// Whether the address carries a `k` key (``AcceptedSpoolURL/carriesToken``). A relay without one may still need a secret
    /// of its own: the mark says only what the address carries.
    public let isPrivate: Bool

    /// What `url` shows.
    public init(_ url: AcceptedSpoolURL) {
        host = url.description
        isKnits = url.socketURLText == SpoolURL.house
        isPrivate = url.carriesToken
    }

    /// Who runs it, in words.
    public var owner: String {
        isKnits ? Copy.Relays.knitsRelay : Copy.Relays.notKnits
    }

    /// Who runs it, and the access-key mark when the address carries a `k` key.
    public var marks: String {
        isPrivate ? owner + ", " + Copy.Relays.privateMark : owner
    }
}

/// Where one listed relay stands.
public enum RelayStatus: Sendable, Equatable, CaseIterable {
    /// Its socket is open.
    case connected
    /// Dialling, or about to.
    case connecting
    /// Its last tries failed, and it waits to try again.
    case waiting
    /// The spool plane is paused: the mesh is stopped, or Knit left the front.
    case paused
    /// The person stopped using it.
    case parked
    /// The master switch is off.
    case off
    /// Its address could not be read now; read again at the next return to the front.
    case unreadable
    /// Its address is gone: only its invite brings it back.
    case missing
    /// Its address is one this build will not dial.
    case unusable
    /// Its address is another listed relay's, which is dialled in its place.
    case duplicate

    /// Its words.
    public var words: String {
        switch self {
        case .connected:
            Copy.Relays.connected
        case .connecting:
            Copy.Relays.connecting
        case .waiting:
            Copy.Relays.waiting
        case .paused:
            Copy.Relays.paused
        case .parked:
            Copy.Relays.parked
        case .off:
            Copy.Relays.off
        case .unreadable:
            Copy.Relays.unreadable
        case .missing:
            Copy.Relays.missing
        case .unusable:
            Copy.Relays.unusable
        case .duplicate:
            Copy.Relays.duplicateRow
        }
    }
}

/// One row of the list.
public struct RelayRow: Identifiable, Sendable, Equatable {
    /// The relay's handle: what the row's controls are named by, never its host.
    public let handle: Int
    /// What the row shows of its address, or `nil` when none could be read.
    public let host: RelayHost?
    /// Whether its address carried a `k` key when it was added.
    public let isPrivate: Bool
    /// Whether the person stopped using it.
    public let parked: Bool
    /// Where it stands.
    public let status: RelayStatus

    public var id: Int { handle }

    /// The row's title: its host, or its number when its address could not be read.
    public var title: String {
        host?.host ?? Copy.Relays.numbered(handle)
    }

    /// The line under the title: who runs it, the private mark, and where it stands.
    public var details: String {
        (marks + [status.words]).joined(separator: " · ")
    }

    /// What VoiceOver reads for the row, in the order it is drawn.
    public var accessibilityLabel: String {
        ([title] + marks + [status.words]).joined(separator: ", ")
    }

    /// Who runs it, when its address was read, and whether it is private.
    private var marks: [String] {
        (host.map { [$0.owner] } ?? []) + (isPrivate ? [Copy.Relays.privateMark] : [])
    }
}

/// A relay the switch's sheet names: by its host, or by its number while its address cannot be read, when it joins once it
/// reads.
public struct RelayJoin: Sendable, Equatable {
    /// The relay's handle.
    public let handle: Int
    /// What the dialler reads of its address, or `nil` while the address cannot be read.
    public let host: RelayHost?

    /// The relay `handle`, at `host` or unread.
    public init(handle: Int, host: RelayHost?) {
        self.handle = handle
        self.host = host
    }

    /// Its host, or its number while unread.
    public var title: String {
        host?.host ?? Copy.Relays.numbered(handle)
    }

    /// Who runs it and its access-key mark, or that it joins once its address reads.
    public var marks: String {
        host?.marks ?? Copy.RelayConsent.joinsOnceRead
    }
}

/// A consent sheet: what it names, and the value its button applies.
public struct RelaySheet: Identifiable, Sendable, Equatable {
    /// What the sheet asks.
    public enum Kind: Sendable, Equatable {
        /// Turn the switch on: every relay that can join under it.
        case turnOn([RelayJoin])
        /// Add the relay at this address, the one the invite came to.
        case add(AcceptedSpoolURL)
    }

    /// A number of its own, so a sheet that replaces another is a new presentation.
    public let id: Int
    public let kind: Kind

    /// Whether it asks to turn the switch on, rather than to add a relay.
    public var isTurnOn: Bool {
        if case .turnOn = kind {
            return true
        }
        return false
    }
}

/// A line shown once.
public enum RelayNotice: Sendable, Equatable, Identifiable {
    /// The invite was not taken.
    case refused(RelayIntake.Refusal)
    /// That relay is already listed.
    case duplicate
    /// The list holds as many relays as it can.
    case full
    /// The list could not be read yet.
    case unavailable
    /// The relay's address could not be kept.
    case notSaved
    /// The consent could not be kept, so the switch stays off.
    case consentNotSaved

    public var id: String { message }

    /// Its words, which name the reason and no part of the link.
    public var message: String {
        switch self {
        case .refused(.notAnInvite):
            Copy.RelayConsent.notAnInvite
        case .refused(.unusableRelay):
            Copy.RelayConsent.unusableInvite
        case .duplicate:
            Copy.RelayConsent.duplicate
        case .full:
            Copy.Relays.full(RelayBook.maxRelays)
        case .unavailable:
            Copy.RelayConsent.listUnavailable
        case .notSaved:
            Copy.RelayConsent.notSaved
        case .consentNotSaved:
            Copy.RelayConsent.consentNotSaved
        }
    }
}
