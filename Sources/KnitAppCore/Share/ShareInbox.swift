public import Foundation
import KnitWire

/// The App Group's share inbox (ADR 2026-10.z7a8): the share sheet writes each share here, and the app drains it,
/// holds back what a check refused, and sweeps what is left over. Files only, so neither process opens the other's
/// database or Keychain.
///
/// Under ``root``:
/// - `incoming/<id>/`: a share the sheet is still writing, its manifest first. It is renamed into `inbox/` once
///   whole, so the app never reads half of one.
/// - `inbox/<id>/`: shares waiting for the app, each a `share.json` and, beside it, the picture's bytes as picked.
/// - `claimed/<id>/`: a share the app took and is sending. It leaves `inbox/` before the send, so a crash between
///   the two can lose that one share but never send it twice; the next sweep drops it.
/// - `held/<id>/`: a share a check refused, until its thread takes it into the composer.
///
/// Files take the container's default protection, which for an app with no data protection entitlement is "until the
/// first unlock", as the database's is (ADR 2026-09.nyya).
public struct ShareInbox: Sendable {
    /// One share in a folder of the inbox.
    public struct Item: Sendable, Equatable {
        /// The share's id, which names its folder.
        public let id: String
        /// What the share holds.
        public let manifest: ShareManifest
        /// The picture's file, when the share has one.
        public let picture: URL?
    }

    /// Why the sheet could not leave a share.
    public enum SubmitError: Error, Equatable {
        /// ``maxPending`` shares already wait.
        case full
        /// The picture is past ``maxPictureBytes``.
        case pictureTooLarge
        /// The container could not be written.
        case unwritable
    }

    /// The folder in the App Group's container that holds everything here.
    public static let folderName = "Share"
    /// How many shares may wait for the app at once. A ninth is refused, so a share sheet used while Knit cannot run
    /// fills no disk.
    public static let maxPending = 8
    /// How many shares may wait in their threads' composers. A share held past it pushes out the oldest.
    public static let maxHeld = 8
    /// The largest picture the sheet hands over, as picked, before the app makes it ready to send: 50 MiB.
    public static let maxPictureBytes = 52_428_800
    /// How long a held share waits for its thread, in milliseconds: 7 days.
    public static let heldLifetime: Int64 = 604_800_000
    /// How long a share may sit half written before a sweep takes it as abandoned, in milliseconds: an hour.
    static let incomingLifetime: Int64 = 3_600_000

    static let manifestName = "share.json"
    /// The longest id a folder takes: a UUID's string is 36.
    static let maxIdLength = 64
    static let pictureName = "picture"

    /// The inbox's folder: ``folderName`` in the App Group's container.
    public let root: URL

    /// The inbox kept in `root`.
    public init(root: URL) {
        self.root = root
    }

    /// The inbox in the App Group container at `container`.
    public init(container: URL) {
        self.init(root: container.appendingPathComponent(Self.folderName, isDirectory: true))
    }

    /// The Darwin notification the sheet posts once it leaves a share, and a running app listens for, for App Group
    /// `group`.
    public static func wakeName(group: String) -> String {
        group + ".share-left"
    }

    // MARK: The sheet's side

    /// How many shares wait for the app.
    public func pendingCount() -> Int {
        folders(in: .inbox).count
    }

    /// Leaves `manifest` for the app under `id`, with the picture at `picture` copied beside it.
    public func submit(_ manifest: ShareManifest, picture: URL?, id: String) throws(SubmitError) {
        guard Self.isSafe(id) else {
            throw .unwritable
        }
        guard pendingCount() < Self.maxPending else {
            throw .full
        }
        if let picture {
            let size = try? FileManager.default.attributesOfItem(atPath: picture.path)[.size] as? Int
            guard let size, size <= Self.maxPictureBytes else {
                throw size == nil ? .unwritable : .pictureTooLarge
            }
        }
        let writing = folder(.incoming, id)
        let manager = FileManager.default
        // One sheet writes at a time, so whatever lies in `incoming/` was abandoned: a sheet ended mid-write.
        for abandoned in folders(in: .incoming) {
            try? manager.removeItem(at: folder(.incoming, abandoned))
        }
        do {
            try manager.createDirectory(at: writing, withIntermediateDirectories: true)
            // The manifest first, so a sweep can date a share that never finished by its own clock.
            var written = manifest
            written.hasPicture = picture != nil
            try Self.encode(written).write(to: writing.appendingPathComponent(Self.manifestName), options: .atomic)
            if let picture {
                try manager.copyItem(at: picture, to: writing.appendingPathComponent(Self.pictureName))
            }
            try manager.createDirectory(at: directory(.inbox), withIntermediateDirectories: true)
            try manager.moveItem(at: writing, to: folder(.inbox, id))
        } catch {
            try? manager.removeItem(at: writing)
            throw .unwritable
        }
    }

    // MARK: The app's side

    /// The shares waiting for the app, oldest first. A folder whose manifest is missing, unreadable or of another
    /// version goes: the sheet writes whole folders only, and ships with the app.
    public func pending() -> [Item] {
        items(in: .inbox, dropping: true)
    }

    /// Takes `item` out of the inbox to send it, or answers `nil` when another drain took it first.
    public func claim(_ item: Item) -> Item? {
        let manager = FileManager.default
        let claimed = folder(.claimed, item.id)
        do {
            try manager.createDirectory(at: directory(.claimed), withIntermediateDirectories: true)
            try manager.moveItem(at: folder(.inbox, item.id), to: claimed)
        } catch {
            return nil
        }
        return Item(
            id: item.id, manifest: item.manifest, picture: item.manifest.hasPicture ? claimed.appendingPathComponent(Self.pictureName) : nil
        )
    }

    /// Drops a claimed share once it is sent, or once there is nothing to do with it.
    public func finish(_ claimed: Item) {
        try? FileManager.default.removeItem(at: folder(.claimed, claimed.id))
    }

    /// Keeps a claimed share for its thread's composer, refused for `refusal`. Past ``maxHeld`` the oldest held goes.
    public func hold(_ claimed: Item, because refusal: ShareManifest.Refusal) {
        let manager = FileManager.default
        let from = folder(.claimed, claimed.id)
        var manifest = claimed.manifest
        manifest.refusal = refusal
        do {
            try Self.encode(manifest).write(to: from.appendingPathComponent(Self.manifestName), options: .atomic)
            try manager.createDirectory(at: directory(.held), withIntermediateDirectories: true)
            try manager.moveItem(at: from, to: folder(.held, claimed.id))
        } catch {
            try? manager.removeItem(at: from)
            return
        }
        for extra in items(in: .held, dropping: true).dropLast(Self.maxHeld) {
            release(extra)
        }
    }

    /// The shares held for thread `conversationId`, oldest first.
    public func held(in conversationId: String) -> [Item] {
        let thread = ExactKey(conversationId)
        return items(in: .held, dropping: true).filter { ExactKey($0.manifest.conversationId) == thread }
    }

    /// Drops a held share, once its thread has taken it.
    public func release(_ held: Item) {
        try? FileManager.default.removeItem(at: folder(.held, held.id))
    }

    /// The picture's bytes, or `nil` when the share has none or they cannot be read.
    public func picture(of item: Item) -> Data? {
        item.picture.flatMap { try? Data(contentsOf: $0) }
    }

    /// Drops what no one will finish, as of `now` in wall milliseconds: every claimed share a crash left (never sent
    /// again, ADR 2026-10.z7a8), every share half written for over an hour, and every held share past
    /// ``heldLifetime``.
    public func sweep(now: Int64) {
        let manager = FileManager.default
        for id in folders(in: .claimed) {
            try? manager.removeItem(at: folder(.claimed, id))
        }
        // A share half written dates itself by its manifest, which the sheet writes first. One with none yet goes at the
        // sheet's next write.
        for writing in items(in: .incoming, dropping: false) where now - writing.manifest.createdAt > Self.incomingLifetime {
            try? manager.removeItem(at: folder(.incoming, writing.id))
        }
        for held in items(in: .held, dropping: true) where now - held.manifest.createdAt > Self.heldLifetime {
            release(held)
        }
    }

    // MARK: Folders

    enum Area {
        case incoming
        case inbox
        case claimed
        case held

        var folderName: String {
            switch self {
            case .incoming:
                "incoming"
            case .inbox:
                "inbox"
            case .claimed:
                "claimed"
            case .held:
                "held"
            }
        }
    }

    func directory(_ area: Area) -> URL {
        root.appendingPathComponent(area.folderName, isDirectory: true)
    }

    func folder(_ area: Area, _ id: String) -> URL {
        directory(area).appendingPathComponent(id, isDirectory: true)
    }

    /// The share ids in `area`, in no order.
    private func folders(in area: Area) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(area).path)) ?? []
        return names.filter(Self.isSafe)
    }

    /// The readable shares in `area`, oldest first, dropping a folder that holds none when `dropping`.
    private func items(in area: Area, dropping: Bool) -> [Item] {
        var read: [Item] = []
        for id in folders(in: area) {
            let at = folder(area, id)
            guard let data = try? Data(contentsOf: at.appendingPathComponent(Self.manifestName)),
                let manifest = try? JSONDecoder().decode(ShareManifest.self, from: data),
                manifest.version == ShareManifest.currentVersion
            else {
                if dropping {
                    try? FileManager.default.removeItem(at: at)
                }
                continue
            }
            read.append(Item(id: id, manifest: manifest, picture: manifest.hasPicture ? at.appendingPathComponent(Self.pictureName) : nil))
        }
        return read.sorted { ($0.manifest.createdAt, $0.id) < ($1.manifest.createdAt, $1.id) }
    }

    /// Whether `id` names one folder and nothing above it: letters, digits and dashes, as a UUID's string is.
    static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxIdLength
            && id.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
    }

    static func encode(_ manifest: ShareManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(manifest)
    }
}
