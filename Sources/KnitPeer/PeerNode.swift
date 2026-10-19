import Foundation
import KnitControl
public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// The headless node: a ``Mesh`` on a radio, answering control commands and reporting what the mesh did, each as
/// one JSON line through `output` (``MeshControl`` has the protocol).
public actor PeerNode {
    /// This node's id.
    nonisolated public let nodeId: NodeId
    private let mesh: Mesh
    private let stores: MeshStores
    private let control: MeshControl
    private let output: @Sendable (String) -> Void
    private let avatarPath: String?
    private var forwarding: Task<Void, Never>?

    /// A node for `identity` on `radio`, with the ratchet prekeys `prekeys` (``PeerState/loadPrekeys(for:)``), or none,
    /// and the ratchet's switch at `ratchet` (on unless `--no-ratchet`), which publishes the newest prekey only when
    /// `prekeys` keeps one. Nothing runs until ``start(name:)``.
    @preconcurrency
    public init(
        identity: IdentityKeys,
        prekeys: PrekeyRing? = nil,
        ratchet: Bool = false,
        stores: MeshStores,
        radio: any Radio,
        radioProfile: String,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog,
        avatarPath: String? = nil,
        output: @escaping @Sendable (String) -> Void
    ) {
        nodeId = identity.nodeId
        self.stores = stores
        self.output = output
        self.avatarPath = avatarPath
        mesh = Mesh(
            identity: identity,
            prekeys: prekeys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: random,
            // The peer is a test bench, so it queries a blob's holders as a debug build does (knit-next ADR 2026-10.6e5t).
            configuration: MeshConfiguration(queriesBlobHolders: true, ratchet: ratchet),
            linkConfiguration: linkConfiguration,
            log: log
        )
        control = MeshControl(
            bundle: identity.bundle,
            mesh: mesh,
            stores: stores,
            clock: clock,
            details: ["radioProfile": .string(radioProfile)],
            keepAvatar: avatarPath.map { path in { @Sendable jpeg in Self.keep(jpeg, at: path) } }
        )
    }

    /// Writes our photo to `path`, or removes it once cleared.
    private static func keep(_ jpeg: [UInt8]?, at path: String) {
        if let jpeg {
            _ = FileManager.default.createFile(atPath: path, contents: Data(jpeg))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Puts our photo back in the blob store, which lives in memory, when the profile still names the one kept at
    /// ``avatarPath``.
    private func restoreAvatar() {
        guard let avatarPath, let hash = stores.ownProfile.load().avatarHash, !stores.blobs.contains(hash),
            let data = FileManager.default.contents(atPath: avatarPath), BlobHash(of: [UInt8](data)) == hash
        else {
            return
        }
        stores.blobs.insert([UInt8](data), hash: hash, mime: "image/jpeg", storedAt: 0)
    }

    /// Starts the mesh, publishes `name` if it is new, and reports `ready`.
    public func start(name: String?) async {
        guard forwarding == nil else {
            return
        }
        let events = mesh.events
        let reporter = control
        let write = output
        forwarding = Task {
            for await event in events {
                for line in await reporter.report(event) {
                    write(line)
                }
            }
        }
        restoreAvatar()
        await mesh.start()
        let own = stores.ownProfile.load()
        if let name, name != own.name {
            await mesh.updateProfile(name: name, status: own.status, openToChat: own.openToChat)
        }
        output(control.ready)
    }

    /// Stops the mesh and the event reports.
    public func stop() async {
        await mesh.stop()
        forwarding?.cancel()
        forwarding = nil
    }

    /// Answers one control line, and whether to keep reading: `false` after `quit`, which stops the node first.
    @discardableResult
    public func handle(_ line: String) async -> Bool {
        let reply = await control.handle(line)
        if reply.quits {
            await stop()
        }
        output(reply.line)
        return !reply.quits
    }
}
