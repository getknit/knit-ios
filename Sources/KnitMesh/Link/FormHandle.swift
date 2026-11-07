public import KnitWire

/// The key a blinded advertised form is held under while it resolves to no id (knit-next ADR 2026-11.xp6d's reader,
/// obligation 8; `FormKeys.kt` at `cad69c77b`; ADR 2026-11.sv5t): a number local to this run, printed `~zzzz…<n>`.
///
/// Kotlin's handle is a string in a namespace no node id can take (`~` is no base32 character). Here it is a type of its
/// own, so no id lookup can ever hit a handle: a per-peer key is a ``SightingKey``, which says which it is.
///
/// The handle is also the redaction (obligation 22): it shows a tag's first four characters, always `zzzz` (only a tag
/// carrying the prefix gets one, ``AdvertForm/hasTagPrefix(_:)``), and a local number, never the tag. So every log line
/// that prints a per-peer key is safe without a helper at each site. The number means nothing off this phone.
public struct FormHandle: Hashable, Sendable, CustomStringConvertible {
    /// What every printed handle starts with: no node id can (`FormKeys.MARK`).
    static let mark = "~"
    /// A tag's first four characters, the prefix every tag carries.
    static let shown = "zzzz"

    /// The handle's number on this phone, counting up from 0 for the run.
    let number: UInt64

    /// `~zzzz…<n>`.
    public var description: String { "\(Self.mark)\(Self.shown)…\(number)" }
}

/// A per-peer key: what presence, addresses, the dwell and the backoff are kept under once an advert can name a tag
/// (ADR 2026-11.sv5t). A clear advert, or a tag a key, claim or hint resolved, is its ``node(_:)``; an unresolved tag is its
/// handle.
public enum SightingKey: Hashable, Sendable, CustomStringConvertible {
    /// A node id: a clear advert, or a resolved tag.
    case node(NodeId)
    /// An unresolved tag's handle.
    case form(FormHandle)

    /// The node id, or `nil` for a handle.
    public var nodeId: NodeId? {
        if case .node(let nodeId) = self {
            return nodeId
        }
        return nil
    }

    /// The id, or the handle: never a tag.
    public var description: String {
        switch self {
        case .node(let nodeId):
            nodeId.string
        case .form(let handle):
            handle.description
        }
    }
}

/// The handles of the tags heard, one per tag while it is remembered (`FormKeys`, `FormKeys.kt:20-65`). Bounded at
/// ``defaultCap``, least recently used out first, and a handle goes only together with the entries under it: the caller
/// forgets those for the handle ``handle(for:)`` evicts, so a form is never held under two handles, and its next sighting
/// starts afresh under a new one. Numbering carries on across ``clear()``.
internal struct FormKeys {
    /// The handles held at once (`FormKeys.DEFAULT_CAP`).
    static let defaultCap = 512

    private struct Held {
        let handle: FormHandle
        var used: UInt64
    }

    private let cap: Int
    private var byTag: [NodeId: Held] = [:]
    private var next: UInt64 = 0
    /// A use counter, for the least recently used order.
    private var uses: UInt64 = 0

    /// Handles the cap let go, since the start.
    private(set) var evicted = 0

    /// Handles held now, at most the cap.
    var count: Int { byTag.count }

    /// Keys at most ``defaultCap`` tags.
    init() {
        self.init(cap: Self.defaultCap)
    }

    /// Keys at most `cap` tags.
    init(cap: Int) {
        self.cap = cap
    }

    /// The handle `tag` is held under, the same one while it is remembered, and the handle the cap let go to make room for
    /// it. The one minting call site, the sighting path, forgets the entries under the handle it answers. A handle
    /// `pinned` says a live dial key names (a dial in flight, a backoff, a held link's held-dial key) is never the one let
    /// go: a held-dial key evicted would let the next sighting of the same tag dial the held phone again, which on an
    /// iPhone the safety net answers by replacing the link. With every handle pinned the cap is passed rather than one
    /// let go.
    mutating func handle(for tag: NodeId, pinned: (FormHandle) -> Bool) -> (handle: FormHandle, evicted: FormHandle?) {
        uses += 1
        if let held = byTag[tag] {
            byTag[tag]?.used = uses
            return (held.handle, nil)
        }
        let handle = FormHandle(number: next)
        next += 1
        byTag[tag] = Held(handle: handle, used: uses)
        guard byTag.count > cap,
            let eldest = byTag.filter({ $0.value.handle != handle && !pinned($0.value.handle) }).min(by: { $0.value.used < $1.value.used })
        else {
            return (handle, nil)
        }
        byTag[eldest.key] = nil
        evicted += 1
        return (handle, eldest.value.handle)
    }

    /// The handle `tag` holds now, or `nil` when it has none (never heard, or forgotten). Never mints, and moves nothing.
    func existing(_ tag: NodeId) -> FormHandle? {
        byTag[tag]?.handle
    }

    /// Forgets every handle: the radio went down, and every entry under one with it. Numbering carries on.
    mutating func clear() {
        byTag.removeAll()
    }
}
