public import Foundation

/// One relay in the person's list as the preferences keep it (ADR 2026-11.adrq, P6): its handle and flags, never its
/// address. Every address but the seeded house relay's lives in the relay's own Keychain item, under its handle
/// (``RelaySecretStore``); the seeded one is rebuilt from ``SpoolURL/house``.
public struct RelayEntry: Codable, Sendable, Equatable {
    /// The relay's number, which the mesh knows it by (`SpoolRelayHandle`). Never reused: ``RelayBook/nextHandle`` only
    /// rises, so a delete still owed for a removed relay never reaches a newer one.
    public let handle: Int
    /// Whether this is the house relay seeded on a fresh install, whose address is the constant.
    public let seeded: Bool
    /// Whether its address carried a `k` key when it was added (``AcceptedSpoolURL/carriesToken``): the row's mark. A relay
    /// without the mark may still need a secret of its own; the mark says only what the address carries.
    public let isPrivate: Bool
    /// Whether the person stopped using it: listed, and carried by no mesh.
    public var parked: Bool

    private enum CodingKeys: String, CodingKey {
        case handle = "handle"
        case seeded = "seeded"
        case isPrivate = "is_private"
        case parked = "parked"
    }

    /// An entry, unparked unless `parked`.
    public init(handle: Int, seeded: Bool, isPrivate: Bool, parked: Bool = false) {
        self.handle = handle
        self.seeded = seeded
        self.isPrivate = isPrivate
        self.parked = parked
    }

    /// A kept entry: its handle is required, since it names the relay's item, and each flag missing from it reads as
    /// off, so an entry a later build writes with a field more, or one fewer, still reads.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        handle = try fields.decode(Int.self, forKey: .handle)
        seeded = try fields.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        isPrivate = try fields.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        parked = try fields.decodeIfPresent(Bool.self, forKey: .parked) ?? false
    }
}

/// The consent the master switch was turned on under: the sheet's version, and a copy of the nonce kept in the relay
/// service's Keychain item for it (ADR 2026-11.adrq, P6). The nonce is random, never derived from the node id, and is no
/// secret: it binds the consent to this device's install, since the Keychain item stays on this phone and a fresh install
/// sweeps it, so a consent restored from a backup, or left from an earlier install, matches nothing.
public struct RelayConsent: Codable, Sendable, Equatable {
    /// The version of the consent sheet's words agreed to (``RelayBook/consentVersion``).
    public let version: Int
    /// The copy of the install's consent nonce.
    public let nonce: String

    /// A consent to `version`, bound by `nonce`.
    public init(version: Int, nonce: String) {
        self.version = version
        self.nonce = nonce
    }
}

/// What the preferences hold of the relay list: nothing yet, a list, or bytes that do not read as one.
public enum StoredRelayBook: Sendable, Equatable {
    /// No list was ever kept: a fresh install, the one case that sweeps the Keychain before it seeds.
    case absent
    /// The list.
    case stored(RelayBook)
    /// Bytes that do not read as a list: left as they are, and nothing is read, swept, seeded or dialled.
    case unreadable
}

/// The person's relays and the master switch, as the preferences keep them (ADR 2026-11.adrq, P6): handles and flags,
/// the "seeded once" marker that keeps a removed house relay removed, the deletes the Keychain still owes, and the consent
/// nonce's copy. No address of any relay is in it, and nothing derived from the node id, so a backup carries numbers, flags
/// and a random nonce alone.
public struct RelayBook: Codable, Sendable, Equatable {
    /// The most relays the list holds: the mesh's own cap (`SpoolPlane.maxRelays`), so the mesh can carry every one.
    public static let maxRelays = 8
    /// The version of the consent sheet's words. Raising it voids every consent given under an older one, and the switch
    /// asks again.
    public static let consentVersion = 1

    /// The relays, in the order they were added.
    public var entries: [RelayEntry] = []
    /// The next handle to hand out.
    public var nextHandle = 1
    /// Whether the house relay was seeded on this install: once set, removing it never brings it back.
    public var seeded = false
    /// Whether the person turned the master switch on.
    public var switchOn = false
    /// What the switch was turned on under, while it is on.
    public var consent: RelayConsent?
    /// Handles whose Keychain item a delete failed to remove, retried until it goes.
    public var pendingDeletes: [Int] = []

    private static let nonceWords = 2
    private static let hexadecimal = 16
    private static let wordDigits = 16

    private enum CodingKeys: String, CodingKey {
        case entries = "entries"
        case nextHandle = "next_handle"
        case seeded = "seeded"
        case switchOn = "switch_on"
        case consent = "consent"
        case pendingDeletes = "pending_deletes"
    }

    /// An empty book: nothing seeded yet.
    public init() {
        // Every field has its value above.
    }

    /// A kept book, each field missing from it derived from the rest, so a book a later build writes with a field more,
    /// or one fewer, still reads: a book that did not read would leave every relay unread. The next handle is past every
    /// handle listed or owed a delete, so none is handed out twice, and a book that lists or owes anything was seeded. A
    /// consent that does not read is no consent.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        entries = try fields.decodeIfPresent([RelayEntry].self, forKey: .entries) ?? []
        pendingDeletes = try fields.decodeIfPresent([Int].self, forKey: .pendingDeletes) ?? []
        let spent = (entries.map(\.handle) + pendingDeletes).max().map { $0 + 1 } ?? 1
        nextHandle = max(try fields.decodeIfPresent(Int.self, forKey: .nextHandle) ?? 1, spent)
        seeded = try fields.decodeIfPresent(Bool.self, forKey: .seeded) ?? (!entries.isEmpty || nextHandle > 1 || !pendingDeletes.isEmpty)
        switchOn = try fields.decodeIfPresent(Bool.self, forKey: .switchOn) ?? false
        consent = try? fields.decodeIfPresent(RelayConsent.self, forKey: .consent)
    }

    /// What `data`, the preferences' bytes, holds.
    public static func read(_ data: Data?) -> StoredRelayBook {
        guard let data else {
            return .absent
        }
        guard let book = try? JSONDecoder().decode(Self.self, from: data) else {
            return .unreadable
        }
        return .stored(book)
    }

    /// The bytes the preferences keep: keys sorted, so the same book always gives the same bytes and a re-save that
    /// changes nothing rewrites nothing new.
    public var encoded: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// A fresh consent nonce: 128 random bits as 32 hexadecimal digits.
    public static func freshNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<nonceWords).map { _ in
            let digits = String(generator.next(), radix: hexadecimal)
            return String(repeating: "0", count: wordDigits - digits.count) + digits
        }
        .joined()
    }

    /// Whether the switch is on under the current sheet, bound by `nonce`, the one the install's Keychain item holds.
    public func consented(given nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty else {
            return false
        }
        return switchOn && consent == RelayConsent(version: Self.consentVersion, nonce: nonce)
    }
}
