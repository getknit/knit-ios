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
    private let stateDirectory: String?
    private let lies: PeerLies?
    /// The allow list `status` reports as `onlyLink` (`--only-link`), sorted, or `null` without one.
    private let onlyLink: JSONValue
    private let log: any KnitLog
    private var forwarding: Task<Void, Never>?

    /// A node for `identity` on `radio`, with the ratchet prekeys `prekeys` (``PeerState/loadPrekeys(for:)``), or none,
    /// and the ratchet's switch at `ratchet` (on unless `--no-ratchet`), our own presence keys at `presenceKeys` (on unless
    /// `--no-presence-keys`), which records its generations in the item `prekeys` keeps, and the ratchet's switch
    /// publishing the newest prekey only when
    /// `prekeys` keeps one. `stateDirectory`, when given, is where a profile lie left set by the last run is found at the
    /// start (``ProfileLies/recoverAtStart(stateDirectory:mesh:stores:log:)``), `--lying` or not. `lying` is what `--lying`
    /// wraps, which `stores` and `radio` must already be built over (``PeerLyingParts/wrapping(_:profileStore:localId:stateDirectory:random:log:)``);
    /// without it the five lying commands are refused. Nothing runs until ``start(name:)``.
    @preconcurrency
    public init(
        identity: IdentityKeys,
        prekeys: PrekeyRing? = nil,
        ratchet: Bool = false,
        presenceKeys: Bool = false,
        stores: MeshStores,
        radio: any Radio,
        radioProfile: String,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog,
        avatarPath: String? = nil,
        stateDirectory: String? = nil,
        lying: PeerLyingParts? = nil,
        output: @escaping @Sendable (String) -> Void
    ) {
        nodeId = identity.nodeId
        self.stores = stores
        self.output = output
        self.avatarPath = avatarPath
        self.stateDirectory = stateDirectory
        self.log = log
        onlyLink = linkConfiguration.onlyLinks.map { ids in .array(ids.map(\.string).sorted().map(JSONValue.string)) } ?? .null
        mesh = Mesh(
            identity: identity,
            prekeys: prekeys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: random,
            // The peer is a test bench, so it queries a blob's holders as a debug build does (knit-next ADR 2026-10.6e5t).
            // Our presence keys as the app sends them, with their trail logged: a bench's log is the trial's (ADR 2026-11.prsp).
            configuration: MeshConfiguration(
                queriesBlobHolders: true, ratchet: ratchet, sendsOwnPresenceKeys: presenceKeys, logsPresenceKeyTrail: true),
            linkConfiguration: linkConfiguration,
            log: log
        )
        control = MeshControl(
            bundle: identity.bundle,
            mesh: mesh,
            stores: stores,
            clock: clock,
            details: ["radioProfile": .string(radioProfile)],
            keepAvatar: avatarPath.map { path in { @Sendable jpeg in Self.keep(jpeg, at: path) } },
            advertHost: PeerAdvertSwitch(build: linkConfiguration.blindsAdvert, defaultSwitch: linkConfiguration.blindSwitchOn)
        )
        lies = lying.map { [mesh] parts in
            let profile = ProfileLies(
                mesh: mesh,
                stores: stores,
                profile: parts.profile,
                blobs: parts.blobs,
                identity: identity,
                clock: clock,
                stateDirectory: parts.stateDirectory,
                log: log
            )
            return PeerLies(parts: parts, profile: profile, mesh: mesh)
        }
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

    /// Sets the link manager's seal switch (`--seal`), a trial's, before ``start(name:)``: so the first advert carries it.
    public func setSealSwitch(_ sealSwitch: LinkManager.SealSwitch) async {
        await mesh.setSealSwitch(sealSwitch)
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
        await recoverFromLies()
        let own = stores.ownProfile.load()
        if let name, name != own.name {
            await mesh.updateProfile(name: name, status: own.status, openToChat: own.openToChat)
        }
        output(control.ready)
    }

    /// Publishes an honest profile over a lie the last run left set, if it did: before `ready`, `--lying` or not.
    private func recoverFromLies() async {
        guard let stateDirectory else {
            return
        }
        do {
            try await ProfileLies.recoverAtStart(stateDirectory: stateDirectory, mesh: mesh, stores: stores, log: log)
        } catch {
            log.log(.warning, "lying: no honest profile published over the last run's lie: \(error)")
        }
    }

    /// Stops the mesh and the event reports.
    public func stop() async {
        await mesh.stop()
        forwarding?.cancel()
        forwarding = nil
    }

    /// Answers one control line, and whether to keep reading: `false` after `quit`, which stops the node first. The lying
    /// commands are answered here, before ``MeshControl``, and `status` gains `lying`, `null` without `--lying`, and `onlyLink`,
    /// the ids `--only-link` named, sorted, or `null` without it, so a harness can check it before a flood.
    @discardableResult
    public func handle(_ line: String) async -> Bool {
        let head = PeerLies.Head.parse(line)
        if let head, PeerLies.names.contains(head.cmd) {
            output(await lyingReply(to: line, head: head))
            return true
        }
        let reply = await control.handle(line)
        if reply.quits {
            await stop()
        }
        var text = reply.line
        if head?.cmd == "status", text.hasSuffix("}") {
            let lying = await lies?.status() ?? .null
            text = String(text.dropLast()) + #","lying":"# + lying.line + #","onlyLink":"# + onlyLink.line + "}"
        }
        output(text)
        return !reply.quits
    }

    private func lyingReply(to line: String, head: PeerLies.Head) async -> String {
        var reply: [String: JSONValue]
        if let lies, let request = PeerLies.Request.parse(line) {
            switch await lies.answer(request) {
            case .success(let fields):
                reply = fields
                reply["ok"] = true
            case .failure(let refusal):
                reply = ["ok": false, "error": .string(refusal.message)]
            }
        } else if lies == nil {
            reply = ["ok": false, "error": .string(PeerLies.refusal)]
        } else {
            reply = ["ok": false, "error": .string("not a valid \(head.cmd) command")]
        }
        reply["reply"] = .string(head.cmd)
        if let tag = head.tag {
            reply["tag"] = .string(tag)
        }
        return JSONValue.object(reply).line
    }
}
